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
swift test                            # full suite, no hardware needed
swift test --filter GoldenVectors     # password-derivation contract
bash scripts/build_app.sh             # .app bundle — this is how you run it
open .build/release/FidoPass.app      # run
bash scripts/create_dmg.sh            # distributable DMG
```

`swift run FidoPassApp` is not a useful way to start the app any more: it is a menu-bar
application, and the status item, the activation policy (`LSUIElement`) and window
activation only behave correctly from a bundle.

Requires `brew install libfido2 pkg-config`. Set `PKG_CONFIG_PATH` if pkg-config cannot
find libfido2.

## Architecture

Two modules, one direction of dependency:

```
FidoPassApp  (AppKit shell + SwiftUI)  ──depends on──▶  FidoPassCore  ──▶  CLibfido2 (system)
```

- `FidoPassCore` — domain logic. No AppKit, no SwiftUI, no UI state.
- `FidoPassApp` — UI only. Talks to the core through `KeyBackend`, never directly.
- `CLibfido2` — system-library shim.

The app is a menu-bar HUD, not a window. Its shape:

```
AppDelegate ─▶ HUDController ─▶ HUDPanel (NSPanel + NSHostingController)
                    │                        └─▶ HUDRootView (SwiftUI)
                    └─▶ NSStatusItem, global hotkey, save panel, aux windows

HUDStore ──owns──▶ DeviceStore · AccountStore · GenerationStore · LabelStore · Preferences
   │                    └────────────▶ KeyBackend ──▶ FidoPassCore
   └─ route, pending intent, touch prompt, the one entry point for key operations
```

`MenuBarExtra` is deliberately not used: it cannot be opened from a global hotkey, cannot be
kept open across a save panel or a key touch, and does not give the PIN field focus.

### Hard rules

1. **`import CLibfido2` only inside `FidoPassCore`.** The app layer must never see a raw C
   type. No `OpaquePointer` in any `public` signature.
2. **Views never call `FidoPassCore` directly, and never call a store's key operation
   directly either.** Everything that makes the authenticator wait for a finger goes through
   `HUDStore.withTouchPrompt`. A view reaching past it is a bug, not a shortcut — the one
   place that did forgot to raise the touch prompt, so the app looked frozen while the key
   waited to be tapped.
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
7. **The click budget is a test, not a preference.** `HUDReducer.primaryAction` states what
   `⏎` must do in every state — with a key unlocked and an account preselected, "generate and
   copy", never "now choose an account" — and it is pinned twice: by `HUDReducerTests` on
   hand-built snapshots and by `HUDStoreTests` on real store state. Nothing dispatches
   through it: each screen owns its default button, because a second global Return handler
   fired alongside the focused field's submit and spent two PIN attempts on one keypress. Any
   new screen has to keep the two in agreement. Changing the budget means arguing with
   `ai.tmp/HUD-PLAN.md` first.
8. **Only account ids, labels and device signatures may be written to disk**
   (`Preferences.LastUsed`, and `labelHistory.v2` — the label history, kept per account and
   synced through iCloud). Both are clearable from Preferences. Passwords, PINs and backup
   keys never are — see rule 4. Label history is scoped to `LabelScope` — the account's
   `credentialIdB64` — rather than kept as one global list: a chip offered under the wrong
   account derives a password that is valid and wrong, which is the failure mode the chips
   exist to prevent. A vendor/product signature does not identify a key (two of a model
   share it, and changing enabled interfaces changes it), and a device path identifies
   nothing beyond the session — see "Working with hardware". Both are stored for display
   only.

### Secrets on the clipboard

Copy secrets with `ClipboardService.copySecret`, never `NSPasteboard` directly. It marks
the value concealed so clipboard managers skip it, keeps it off Universal Clipboard, and
clears it after a timeout — checking the change count first so it never wipes something the
user copied afterwards.

### Known, deliberate gaps

- A pending key operation cannot really be cancelled. libfido2 has `fido_dev_cancel`, but
  `DeviceRepository.withOpenedDevice` never surfaces the handle, so `HUDStore.abandonTouch`
  only hides the prompt and discards the result — the call finishes in the background.
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
  App/              AppDelegate — entry point, activation policy, main menu, hotkey
  Stores/           KeyBackend seam, DeviceStore, AccountStore, GenerationStore,
                    LabelStore, Preferences, HUDStore (navigation), HUDReducer (pure)
  HUD/Presentation/ NSStatusItem, NSPanel, icon states, Carbon hotkey, aux windows
  HUD/Views/        the panel's SwiftUI screens
  Settings/         Preferences and onboarding windows
  ViewModels/       CryptoEditorSession
  Views/CryptoEditor/  the separate editor window
  Services/         system integrations, error presentation, recovery sheet
```

The stores are separate observable objects on purpose: a clipboard countdown ticking once a
second must not redraw the whole panel. Keep new state in the store that owns it, and keep
`HUDReducer` pure — it is where the click budget is asserted.

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
