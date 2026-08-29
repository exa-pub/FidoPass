# FidoPass — agent guide

Hardware-backed deterministic password generator for macOS. All secrets stay on a FIDO2
authenticator; the app derives passwords via the `hmac-secret` extension and never writes
derived material to disk.

## What this tool is for

FidoPass generates **a few strong keys**, not a password per website. The typical use is a
master password for a password vault, a disk-encryption passphrase, or a backup key. That
shapes every trade-off here:

- an account count in the single digits, not hundreds;
- generation happens rarely — daily at most, often monthly;
- the result is frequently **typed by hand**, so the alphabet deliberately excludes
  ambiguous characters (`i l o I L O 0 1`);
- losing the authenticator is unrecoverable: a vault has no master-password reset. Backup
  and recovery matter more than everyday ergonomics.

Do not add per-site conveniences (label history, autofill, quick access) without checking
this framing first.

## Commands

```bash
swift build --product FidoPassApp     # build
swift run FidoPassApp                 # run (GUI)
swift test                            # full suite, no hardware needed
swift test --filter GoldenVectors     # password-derivation contract
bash scripts/build_app.sh             # .app bundle
bash scripts/create_dmg.sh            # distributable DMG
```

Requires `brew install libfido2 pkg-config`. Set `PKG_CONFIG_PATH` if pkg-config cannot
find libfido2.

## Architecture

Two modules, one direction of dependency:

```
FidoPassApp  (SwiftUI)  ──depends on──▶  FidoPassCore  ──▶  CLibfido2 (system)
```

- `FidoPassCore` — domain logic. No AppKit, no SwiftUI, no UI state.
- `FidoPassApp` — UI only. Talks to the core through the facade or injected protocols.
- `CLibfido2` — system-library shim.

### Hard rules

1. **`import CLibfido2` only inside `FidoPassCore`.** The app layer must never see a raw C
   type. No `OpaquePointer` in any `public` signature.
2. **Views never call `FidoPassCore` directly.** UI goes through the view model. A view
   reaching into the core is a bug, not a shortcut — the one place that did forgot to
   raise the touch prompt, so the app looked frozen while the key waited to be tapped.
3. **Never change password derivation for `policy.version == 1`.** Derivation is a
   compatibility contract: changing it silently invalidates every password a user already
   relies on, and for a vault master password there is no reset path. New behaviour goes
   under a new `version`, opt-in. `GoldenVectorsTests` enforces this at three levels —
   salts, character mapping, and the full generator. If it fails, you broke someone's
   logins; never update the expectations to match new behaviour.
4. **Never log, print, or write secrets** — PINs, hmac-secret output, derived passwords,
   portable master keys. Not even in debug builds.
5. **Every `fido_*_new()` needs a paired free via `defer`.** Use
   `DeviceRepository.withOpenedDevice` rather than opening devices by hand.
6. **Account-level password policy is not persisted.** `revision` and `policy` are rebuilt
   with defaults on every enumeration, because the authenticator stores no metadata for
   them. This is safe only while policy stays a per-generation choice. A persistent
   per-account policy editor needs key-side metadata storage (`largeBlobs`) first — note
   that `credBlob` cannot serve: it is write-once at credential creation.

### Secrets on the clipboard

Copy secrets with `ClipboardService.copySecret`, never `NSPasteboard` directly. It marks
the value concealed so clipboard managers skip it, keeps it off Universal Clipboard, and
clears it after a timeout — checking the change count first so it never wipes something the
user copied afterwards.

### Known, deliberate gaps

- `AccountsViewModel` has not been split into stores, and the app still mixes GCD with
  `Task` / `Task.detached`. Prefer `async`/`await` in new code.
- `PasswordEngine` does not actually guarantee that every enabled character class appears;
  the top-up step can overwrite its own fixes. Failure rate is ~3% at length 8 and
  effectively zero at the default 20. Recorded in `CharacterClassInvariantTests` as an
  expected failure. Fixing it requires a new policy version.

## Layout

```
Sources/FidoPassCore/
  Public/       facade
  Models/       Account, PasswordPolicy, FidoDevice
  Protocols/    DI seams used by tests
  Devices/      libfido2 device access, capability probing
  Enrollment/   credential creation, enumeration, deletion
  Secrets/      hmac-secret, HKDF, password mapping
  Support/      salts, crypto helpers, libfido2 context

Sources/FidoPassApp/
  App/          entry point, commands
  ViewModels/   AccountsViewModel plus one extension per concern
  Views/        one folder per screen; shared pieces in Views/Shared
  Components/   reusable presentation-only views
  Services/     system integrations, error presentation, recovery sheet
```

`AccountsViewModel` is still a single observable object holding all app state, split
across extensions by concern. It is bigger than it should be — every published change
invalidates every observing view. Splitting it into per-concern stores is planned but not
done; keep new state grouped with the extension that owns it rather than adding unrelated
fields to the top-level type.

One type per file, file named after the type. New screens follow the existing folder shape.

## Conventions

- **English only** in code, comments, docs, and commit messages.
- Prefer `async`/`await` over GCD. Do not mix `Task.detached`, `Task`, and `DispatchQueue`
  for the same job.
- System integrations go through a service wrapper — no direct AppKit calls in views.
- Tests use the protocols in `Protocols/`; shared mocks live in `Tests/TestSupport/`.

## Working with hardware

- CI has no authenticator. Anything touching `fido_dev_*` must be behind a protocol so
  tests can run without a key.
- **Device paths (`ioreg://…`) change on every reconnect.** Never persist one or use it as
  a stable identity — it is a session handle only.
- **A FIDO2 key locks permanently after 8 wrong PINs.** Never write a test, script, or
  retry loop that guesses PINs against real hardware.
- Resident-key slots are finite (100 on a YubiKey 5). Clean up credentials created during
  manual testing.
