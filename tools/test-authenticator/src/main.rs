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
use opensk::env::{Env, test::TestEnv};
use rand::{RngCore, SeedableRng, rngs::StdRng};
use std::io::{self, Read, Write};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::Duration;

const VERSION: u8 = 1;
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
    pub const WAITING_FOR_TOUCH: u8 = 0x80;
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
type Touch = Arc<(Mutex<bool>, Condvar)>;
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

fn configure_presence(env: &mut TestEnv, mode: u8, signal: Touch, events: Output) {
    let clock = env.clock().clone();
    *signal.0.lock().unwrap() = false;
    env.user_presence().set(move || match mode {
        presence::IMMEDIATE => Ok(()),
        presence::TIMEOUT => {
            clock.advance(1000);
            Err(UserPresenceError::Timeout)
        }
        presence::DECLINED => Err(UserPresenceError::Declined),
        presence::CONTROLLED => {
            send(&events, &header(operation::WAITING_FOR_TOUCH, 0), &[])
                .map_err(|_| UserPresenceError::Canceled)?;
            let (mut granted, timeout) = signal
                .1
                .wait_timeout_while(signal.0.lock().unwrap(), Duration::from_secs(5), |v| !*v)
                .unwrap();
            if timeout.timed_out() && !*granted {
                clock.advance(30_000);
                return Err(UserPresenceError::Timeout);
            }
            *granted = false;
            Ok(())
        }
        _ => unreachable!("presence mode is validated before configuration"),
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
    let touch = Arc::new((Mutex::new(false), Condvar::new()));
    let (sender, receiver) = mpsc::sync_channel(1);
    let control = touch.clone();
    // Touch grants bypass the engine queue so a waiting CTAP command cannot block them.
    std::thread::spawn(move || {
        let mut input = io::stdin().lock();
        while let Some(frame) = read_frame(&mut input) {
            if frame[OPERATION_OFFSET] == operation::GRANT_TOUCH && frame.len() == HEADER_SIZE {
                *control.0.lock().unwrap() = true;
                control.1.notify_all();
            } else if sender.send(frame).is_err() {
                break;
            }
        }
    });
    let mut engine: Option<Engine> = None;
    for frame in receiver {
        let opcode = frame[OPERATION_OFFSET];
        let payload = &frame[HEADER_SIZE..];
        let reply = if opcode == operation::INITIALIZE && engine.is_none() && payload.len() == 33 {
            engine = Some(create_engine(payload)?);
            vec![]
        } else if let Some((env, state, hid)) = &mut engine {
            match opcode {
                operation::CTAP if !payload.is_empty() => {
                    state.process_command(env, payload, Channel::MainHid([0, 0, 0, 1]))
                }
                operation::POWER_CYCLE if payload.is_empty() => {
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
                    configure_presence(env, payload[0], touch.clone(), output.clone());
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
