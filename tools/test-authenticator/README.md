# OpenSK test authenticator

OpenSK runs in a child process behind libfido2’s test transport. It needs no physical key,
virtual HID device or elevated privileges. It is included only in app bundles built with
`bash scripts/build_app.sh --virtual-keys`; ordinary bundles use physical keys.

## Run

Install Rust with rustup, then prepare the pinned toolchain:

```sh
rustup toolchain install 1.94.1 --profile minimal
bash scripts/test_keys.sh
swift test
```

The first command that builds the helper downloads OpenSK and Cargo dependencies. Subsequent
builds use the local cache. `Cargo.lock` and the clean OpenSK commit are checked. In CI the
key suite is mandatory; missing helper, empty selection, skipped case or failure fails the
job. For quick unit-only development `swift test` skips the OpenSK group if no helper has
been built. `FIDOPASS_REQUIRE_KEY_TESTS=1` makes absence an error. Set
`FIDOPASS_TEST_AUTHENTICATOR` only to an explicitly selected test executable.

The app and tests use the same FidoPassCore and libfido2. Package-scoped Swift protocols
inject enumeration and a connection without exposing C handles. Unknown paths cannot fall
back to system enumeration or HID. The shared `FidoPassVirtualKeys` module owns the transport
and device lifecycle; `TestSupport` adds deterministic fixtures and fault injection. Every
registry owns isolated child processes. Explicit power cycling changes the path, preserves RAM-backed flash and resets volatile CTAP state.

## Protocol and ownership

Each frame has a four-byte big-endian length, protocol version 2, an opcode and an eight-byte
request id, then a payload. The maximum frame is 65,536 bytes. One ordinary request is outstanding
per child; replies must echo the header. Initialization supplies a 32-byte seed, profile,
presence mode, clock mode and four-byte big-endian touch timeout (1–30,000 ms).
`0x80` and `0x81` mark the start and end of presence, with the CTAP request id and an
eight-byte touch id. A grant (opcode 9) must match both ids and never pre-approves a later touch.
Opcodes: 0 initializes seed/profile; 1 processes CTAP; 2 power cycles; 3 advances virtual
milliseconds; 4 selects presence mode; 5 prepares a released v1 fixture; 6 processes a
64-byte HID packet; 7 deliberately hangs for the watchdog test. Opcode 9 grants presence
through an independent reader and has no response, so it works while CTAP waits. Opcode 10
disconnects and cancels presence without destroying storage; power-cycle re-enables the key.
Parent EOF terminates the helper, including a hung engine.

Swift launches via `posix_spawn` with an empty environment and private pipes. A dedicated
reader publishes replies and presence events. Nonblocking I/O and monotonic deadlines bound
requests/writes; stopping never waits behind a CTAP read. Failed framing, EOF and timeout
close the session; timeout kills and reaps the child with `waitpid`. No run loop is required for
cleanup. Logs contain command identifiers and test outcomes only, never CTAP payloads,
PINs, PRF outputs or backup material. stdout is binary IPC; stderr is discarded and the
Rust panic hook emits no input. No authenticator state is serialized to files.

Presence modes: immediate approval, virtual timeout, decline, and a controlled wait with
a five-second wall-clock ceiling in tests (30 seconds in the app). The app synchronizes
OpenSK time with a monotonic clock; tests advance time explicitly. A test waits for the
explicit event before closing or locking a surface, then grants the touch. Hiding an app prompt never aborts OpenSK work.

Profiles: default OpenSK; enterprise configuration with synthetic attestation material;
two resident slots; 1 KiB large-blob capacity. These customize the actual engine. Enterprise
tests prove the configuration command, not a certificate chain or enterprise attestation
ceremony. Released v1 fixtures use real OpenSK key generation/storage and a synthetic mask;
no production v1-writing API was added. All assertions reread via the real app services.

Fault injection is separate from engine profiles: reject a command/subcommand, lose a reply
*after* the engine committed, or deliver malformed CBOR. Faults are one-shot and per key.
The optional HID connection uses libfido2's default framing and OpenSK's MainHid parser,
including report id, INIT/channel allocation, fragmentation and error responses.

## Limits

System IOHID seize behavior, physical reconnect notifications,
USB timing, real touch and firmware-specific behavior still need a small manual hardware
check. No CI test opens a physical key. Do not record/replay real key traffic.

## Provenance and licenses

- [OpenSK](https://github.com/google/OpenSK/tree/e161e95944871ccf719945738a272e718076c1df),
  commit `e161e95944871ccf719945738a272e718076c1df`, Apache-2.0. Source and its LICENSE remain
  in `.build/test-authenticator/opensk`; upstream is not patched.
- Rust toolchain 1.94.1. Transitive Rust versions/checksums are recorded in `Cargo.lock`;
  source licenses remain in the Cargo source cache.
- The transport APIs are documented in the
  [libfido2 manual](https://developers.yubico.com/libfido2/Manuals/fido_dev_set_io_functions.html).
- The helper source is part of this repository under its MIT license.
