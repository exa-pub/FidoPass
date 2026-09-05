//! Private bounded pipe protocol; all authenticator storage is process-local RAM.
use opensk::api::{
    customization::DEFAULT_CUSTOMIZATION,
    persist::{Attestation, AttestationId, Persist},
    private_key::PrivateKey,
    user_presence::UserPresenceError,
};
use opensk::ctap::data_formats::{
    CredentialProtectionPolicy, EnterpriseAttestationMode, PublicKeyCredentialSource,
    PublicKeyCredentialType,
};
use opensk::ctap::{Channel, CtapState, main_hid::MainHid};
use opensk::env::{
    Env,
    test::{TestClock, TestEnv},
};
use rand::{RngCore, SeedableRng, rngs::StdRng};
use std::io::{self, Read, Write};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::{Duration, Instant};

const VERSION: u8 = 2;
const VERSION_OFFSET: usize = 0;
const OPERATION_OFFSET: usize = 1;
const REQUEST_ID_OFFSET: usize = 2;
const HEADER_SIZE: usize = REQUEST_ID_OFFSET + size_of::<u64>();
const MAX_FRAME: usize = 65_536;

mod operation {
    pub const INITIALIZE: u8 = 0;
    pub const CTAP: u8 = 1;
    pub const POWER_CYCLE: u8 = 2;
    pub const ADVANCE_CLOCK: u8 = 3;
    pub const CONFIGURE_PRESENCE: u8 = 4;
    pub const PREPARE_LEGACY: u8 = 5;
    pub const HID: u8 = 6;
    pub const HANG: u8 = 7;
    pub const GRANT_TOUCH: u8 = 9;
    pub const DISCONNECT: u8 = 10;
    pub const WAITING_FOR_TOUCH: u8 = 0x80;
    pub const TOUCH_FINISHED: u8 = 0x81;
}

mod profile {
    pub const DEFAULT: u8 = 0;
    pub const ENTERPRISE: u8 = 1;
    pub const TWO_SLOTS: u8 = 2;
    pub const SMALL_BLOB: u8 = 3;
}

mod presence {
    pub const IMMEDIATE: u8 = 0;
    pub const TIMEOUT: u8 = 1;
    pub const DECLINED: u8 = 2;
    pub const CONTROLLED: u8 = 3;
}

mod legacy {
    pub const LOCAL: u8 = 0;
    pub const PORTABLE: u8 = 1;
    pub const DISPLAY_PAYLOAD: u8 = 2;
}

type Output = Arc<Mutex<io::Stdout>>;
#[derive(Default)]
struct PresenceState {
    request_id: u64,
    next_touch: u64,
    active: Option<(u64, u64)>,
    granted: bool,
    disconnected: bool,
}

impl PresenceState {
    fn grant(&mut self, request_id: u64, touch_id: u64) -> bool {
        if self.disconnected || self.granted || self.active != Some((request_id, touch_id)) {
            return false;
        }
        self.granted = true;
        true
    }
}

type Touch = Arc<(Mutex<PresenceState>, Condvar)>;

struct ClockDriver {
    clock: TestClock,
    realtime: bool,
    last: Mutex<Instant>,
}

impl ClockDriver {
    fn sync(&self) {
        if self.realtime {
            let mut last = self.last.lock().unwrap();
            let now = Instant::now();
            let elapsed = now.duration_since(*last).as_millis() as usize;
            self.clock.advance(elapsed);
            *last += Duration::from_millis(elapsed as u64);
        }
    }
}
type Engine = (TestEnv, CtapState<TestEnv>, MainHid<TestEnv>);

fn header(operation: u8, request_id: u64) -> [u8; HEADER_SIZE] {
    let mut result = [0; HEADER_SIZE];
    result[VERSION_OFFSET] = VERSION;
    result[OPERATION_OFFSET] = operation;
    result[REQUEST_ID_OFFSET..].copy_from_slice(&request_id.to_be_bytes());
    result
}

fn read_frame(input: &mut impl Read) -> Option<Vec<u8>> {
    let mut length = [0; 4];
    input.read_exact(&mut length).ok()?;
    let length = u32::from_be_bytes(length) as usize;
    if !(HEADER_SIZE..=MAX_FRAME).contains(&length) {
        return None;
    }
    let mut frame = vec![0; length];
    input.read_exact(&mut frame).ok()?;
    (frame[VERSION_OFFSET] == VERSION).then_some(frame)
}

fn send(output: &Output, header: &[u8], payload: &[u8]) -> io::Result<()> {
    if payload.len() + HEADER_SIZE > MAX_FRAME {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let mut out = output.lock().unwrap();
    out.write_all(&((HEADER_SIZE + payload.len()) as u32).to_be_bytes())?;
    out.write_all(header)?;
    out.write_all(payload)?;
    out.flush()
}

fn create_engine(payload: &[u8]) -> io::Result<Engine> {
    let mut env = TestEnv::default();
    *env.rng() = StdRng::from_seed(payload[..32].try_into().unwrap());
    let mut customization = DEFAULT_CUSTOMIZATION.clone();
    match payload[32] {
        profile::DEFAULT => (),
        profile::ENTERPRISE => {
            customization.enterprise_attestation_mode =
                Some(EnterpriseAttestationMode::PlatformManaged);
        }
        profile::TWO_SLOTS => customization.max_supported_resident_keys = 2,
        profile::SMALL_BLOB => customization.max_large_blob_array_size = 1024,
        _ => return Err(io::ErrorKind::InvalidData.into()),
    }
    *env.customization_mut() = customization.into();
    if payload[32] == profile::ENTERPRISE {
        // Synthetic material: this profile tests configuration, not certificate validity.
        env.persist()
            .set_attestation(
                AttestationId::Enterprise,
                Some(&Attestation {
                    wrapped_private_key: vec![0x41; 32],
                    certificate: vec![0xdd; 20],
                }),
            )
            .map_err(|_| io::ErrorKind::InvalidData)?;
    }
    let state = CtapState::new(&mut env);
    Ok((env, state, MainHid::default()))
}

fn configure_presence(
    env: &mut TestEnv,
    mode: u8,
    signal: Touch,
    events: Output,
    clock: Arc<ClockDriver>,
    timeout: Duration,
) {
    env.user_presence().set(move || {
        if signal.0.lock().unwrap().disconnected {
            return Err(UserPresenceError::Canceled);
        }
        match mode {
            presence::IMMEDIATE => Ok(()),
            presence::TIMEOUT => {
                clock.clock.advance(1000);
                Err(UserPresenceError::Timeout)
            }
            presence::DECLINED => Err(UserPresenceError::Declined),
            presence::CONTROLLED => {
                let token = {
                    let mut state = signal.0.lock().unwrap();
                    if state.disconnected {
                        return Err(UserPresenceError::Canceled);
                    }
                    state.next_touch += 1;
                    let token = (state.request_id, state.next_touch);
                    state.active = Some(token);
                    state.granted = false;
                    token
                };
                send(
                    &events,
                    &header(operation::WAITING_FOR_TOUCH, token.0),
                    &token.1.to_be_bytes(),
                )
                .map_err(|_| UserPresenceError::Canceled)?;
                let (mut state, _) = signal
                    .1
                    .wait_timeout_while(signal.0.lock().unwrap(), timeout, |s| {
                        !s.granted && !s.disconnected
                    })
                    .unwrap();
                let outcome = if state.disconnected {
                    Err(UserPresenceError::Canceled)
                } else if state.granted {
                    Ok(())
                } else {
                    if !clock.realtime {
                        clock.clock.advance(30_000);
                    }
                    Err(UserPresenceError::Timeout)
                };
                state.active = None;
                state.granted = false;
                drop(state);
                clock.sync();
                send(
                    &events,
                    &header(operation::TOUCH_FINISHED, token.0),
                    &token.1.to_be_bytes(),
                )
                .map_err(|_| UserPresenceError::Canceled)?;
                outcome
            }
            _ => unreachable!("presence mode is validated before configuration"),
        }
    });
}

// Released v1 layout with real OpenSK keys/storage. A zero mask makes the portable
// master key equal to this credential's PRF output.
fn prepare_legacy(env: &mut TestEnv, kind: u8) -> io::Result<()> {
    let mut id = vec![0; 32];
    env.rng().fill_bytes(&mut id);
    let portable = kind != legacy::LOCAL;
    let key = env
        .persist()
        .free_credential_key()
        .map_err(|_| io::ErrorKind::InvalidData)?;
    let credential = PublicKeyCredentialSource {
        key_type: PublicKeyCredentialType::PublicKey,
        credential_id: id,
        wrapped_private_key: PrivateKey::new_ecdsa(env).to_cbor(),
        rp_id: if portable {
            "fidopass.portable"
        } else {
            "fidopass.local"
        }
        .into(),
        user_handle: b"legacy".to_vec(),
        user_name: Some(
            if portable {
                "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
            } else {
                "legacy"
            }
            .into(),
        ),
        user_display_name: if kind == legacy::DISPLAY_PAYLOAD {
            Some("fp-ext:v1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".into())
        } else {
            None
        },
        cred_protect_policy: Some(CredentialProtectionPolicy::UserVerificationRequired),
        creation_order: key as u64,
        user_icon: None,
        cred_blob: None,
        large_blob_key: None,
    };
    let mut bytes = vec![];
    sk_cbor::write(credential.into(), &mut bytes).map_err(|_| io::ErrorKind::InvalidData)?;
    env.persist()
        .write_credential_bytes(key, &bytes)
        .map_err(|_| io::ErrorKind::InvalidData)?;
    Ok(())
}

fn run() -> io::Result<()> {
    let output = Arc::new(Mutex::new(io::stdout()));
    let touch = Arc::new((Mutex::new(PresenceState::default()), Condvar::new()));
    let (sender, receiver) = mpsc::sync_channel(1);
    let control = touch.clone();
    // Touch grants bypass the engine queue so a waiting CTAP command cannot block them.
    std::thread::spawn(move || {
        let mut input = io::stdin().lock();
        while let Some(frame) = read_frame(&mut input) {
            let opcode = frame[OPERATION_OFFSET];
            let request_id =
                u64::from_be_bytes(frame[REQUEST_ID_OFFSET..HEADER_SIZE].try_into().unwrap());
            match opcode {
                operation::GRANT_TOUCH if frame.len() == HEADER_SIZE + 8 => {
                    let touch_id = u64::from_be_bytes(frame[HEADER_SIZE..].try_into().unwrap());
                    let mut state = control.0.lock().unwrap();
                    if state.grant(request_id, touch_id) {
                        control.1.notify_all();
                    }
                }
                operation::DISCONNECT if frame.len() == HEADER_SIZE && request_id == 0 => {
                    control.0.lock().unwrap().disconnected = true;
                    control.1.notify_all();
                }
                operation::GRANT_TOUCH | operation::DISCONNECT => std::process::exit(1),
                _ => {
                    // A well-formed parent has at most one ordinary request outstanding.
                    if sender.try_send(frame).is_err() {
                        std::process::exit(1);
                    }
                }
            }
        }
        // Parent EOF also terminates an engine deliberately hung by a watchdog test.
        std::process::exit(0);
    });
    let mut engine: Option<Engine> = None;
    let mut clock: Option<Arc<ClockDriver>> = None;
    let mut touch_timeout = Duration::from_secs(5);
    for frame in receiver {
        let request_id =
            u64::from_be_bytes(frame[REQUEST_ID_OFFSET..HEADER_SIZE].try_into().unwrap());
        touch.0.lock().unwrap().request_id = request_id;
        if let Some(clock) = &clock {
            clock.sync();
        }
        let opcode = frame[OPERATION_OFFSET];
        let payload = &frame[HEADER_SIZE..];
        let reply = if opcode == operation::INITIALIZE && engine.is_none() && payload.len() == 39 {
            if payload[33] > presence::CONTROLLED || payload[34] > 1 {
                return Err(io::ErrorKind::InvalidData.into());
            }
            let timeout_ms = u32::from_be_bytes(payload[35..39].try_into().unwrap());
            if !(1..=30_000).contains(&timeout_ms) {
                return Err(io::ErrorKind::InvalidData.into());
            }
            touch_timeout = Duration::from_millis(timeout_ms as u64);
            let mut created = create_engine(payload)?;
            let driver = Arc::new(ClockDriver {
                clock: created.0.clock().clone(),
                realtime: payload[34] == 1,
                last: Mutex::new(Instant::now()),
            });
            configure_presence(
                &mut created.0,
                payload[33],
                touch.clone(),
                output.clone(),
                driver.clone(),
                touch_timeout,
            );
            clock = Some(driver);
            engine = Some(created);
            vec![]
        } else if let Some((env, state, hid)) = &mut engine {
            match opcode {
                operation::CTAP if !payload.is_empty() => {
                    state.process_command(env, payload, Channel::MainHid([0, 0, 0, 1]))
                }
                operation::POWER_CYCLE if payload.is_empty() => {
                    touch.0.lock().unwrap().disconnected = false;
                    *state = CtapState::new(env);
                    *hid = MainHid::default();
                    vec![]
                }
                operation::ADVANCE_CLOCK if payload.len() == 8 => {
                    let duration = u64::from_be_bytes(payload.try_into().unwrap());
                    if duration > 86_400_000 {
                        return Err(io::ErrorKind::InvalidData.into());
                    }
                    env.clock().advance(duration as usize);
                    vec![]
                }
                operation::CONFIGURE_PRESENCE
                    if payload.len() == 1
                        && matches!(
                            payload[0],
                            presence::IMMEDIATE
                                | presence::TIMEOUT
                                | presence::DECLINED
                                | presence::CONTROLLED
                        ) =>
                {
                    configure_presence(
                        env,
                        payload[0],
                        touch.clone(),
                        output.clone(),
                        clock.as_ref().unwrap().clone(),
                        touch_timeout,
                    );
                    vec![]
                }
                operation::PREPARE_LEGACY
                    if payload.len() == 1
                        && matches!(
                            payload[0],
                            legacy::LOCAL | legacy::PORTABLE | legacy::DISPLAY_PAYLOAD
                        ) =>
                {
                    prepare_legacy(env, payload[0])?;
                    vec![]
                }
                operation::HID if payload.len() == 64 => hid
                    .process_hid_packet(env, payload.try_into().unwrap(), false, state)
                    .flatten()
                    .collect(),
                operation::HANG if payload.is_empty() => loop {
                    std::thread::park();
                },
                _ => return Err(io::ErrorKind::InvalidData.into()),
            }
        } else {
            return Err(io::ErrorKind::InvalidData.into());
        };
        send(&output, &frame[..HEADER_SIZE], &reply)?;
    }
    Ok(())
}

fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    if !matches!(std::panic::catch_unwind(run), Ok(Ok(()))) {
        eprintln!("Test authenticator stopped: protocol or engine failure");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grants_cannot_be_saved_replayed_or_used_for_another_request() {
        let mut state = PresenceState::default();
        assert!(!state.grant(1, 1));
        state.active = Some((1, 1));
        assert!(!state.grant(2, 1));
        assert!(!state.grant(1, 2));
        assert!(state.grant(1, 1));
        assert!(!state.grant(1, 1));
        state.active = Some((2, 2));
        state.granted = false;
        assert!(!state.grant(1, 1));
        state.disconnected = true;
        assert!(!state.grant(2, 2));
    }

    #[test]
    fn realtime_clock_advances_but_manual_clock_waits_for_explicit_input() {
        for realtime in [false, true] {
            let driver = ClockDriver {
                clock: TestClock::default(),
                realtime,
                last: Mutex::new(Instant::now() - Duration::from_secs(11)),
            };
            driver.sync();
            if realtime {
                assert!(driver.clock.now() >= 11_000);
            } else {
                assert_eq!(driver.clock.now(), 0);
            }
        }
    }
}
