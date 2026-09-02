# FidoPass — agent guide

Hardware-backed deterministic password generator for macOS. All secrets stay on a FIDO2
authenticator; the app derives passwords via the `hmac-secret` extension and never writes
derived material to disk.

## What this tool is for

FidoPass generates **a few strong keys**, not a password per website — a master password
for a password vault, a disk-encryption passphrase, a backup key. That shapes the
trade-offs: an account count in the single digits, generation that happens monthly rather
than hourly, an alphabet without ambiguous characters (`i l o I L O 0 1`) because the
result is often typed by hand, and no recovery path if the authenticator is lost.

Do not add per-site conveniences (autofill, quick access, large label lists) without
checking this framing first.

## Commands

```bash
swift build --product FidoPassApp     # build
swift test                            # full suite, no hardware needed
swift test --filter GoldenVectors     # password-derivation contract
bash scripts/build_app.sh             # .app bundle — this is how you run it
open .build/release/FidoPass.app      # run
bash scripts/create_dmg.sh            # distributable DMG
bash scripts/notarize.sh              # signed, notarised, stapled DMG — needs Developer ID
```

`swift run FidoPassApp` does not work as a way to start the app: it is a menu-bar
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

Release bundles are signed with a Developer ID and notarised. `build_app.sh` and
`create_dmg.sh` sign whatever they produce when `FIDOPASS_SIGN_IDENTITY` names an identity,
and fall back to an ad-hoc signature when it is unset — so a machine without a certificate
still builds. Signing runs last: `install_name_tool` invalidates anything signed before it.

The app is a menu-bar HUD, not a window:

```
AppDelegate ─▶ HUDController ─▶ HUDPanel (NSPanel + NSHostingController)
                    │                        └─▶ HUDRootView (SwiftUI)
                    └─▶ NSStatusItem, global hotkey, save panel, aux windows

HUDStore ──owns──▶ DeviceStore · AccountStore · GenerationStore · LabelStore ·
                   InventoryStore · Preferences
   │                    └────────────▶ KeyBackend ──▶ FidoPassCore
   └─ route, pending intent, touch prompt, the one entry point for key operations
```

`MenuBarExtra` is deliberately not used: it cannot be opened from a global hotkey, cannot be
kept open across a save panel or a key touch, and does not give the PIN field focus.

## Hard rules

1. **`import CLibfido2` only inside `FidoPassCore`.** No raw C type — no `OpaquePointer` —
   in any `public` signature.
2. **Views never call `FidoPassCore` or a store's key operation directly.** Everything that
   makes the authenticator wait for a finger goes through `HUDStore.withTouchPrompt`. The
   one place that bypassed it forgot to raise the touch prompt, so the app looked frozen
   while the key waited to be tapped.
3. **Never change password derivation for `policy.version == 1`.** Derivation is a
   compatibility contract: changing it silently invalidates every password a user already
   relies on, and a vault master password has no reset path. New behaviour goes under a new
   `version`, opt-in. `GoldenVectorsTests` pins salts, character mapping and the full
   generator — if it fails you broke someone's logins, so never update the expectations to
   match new behaviour.
4. **Never log, print, or write secrets** — PINs, hmac-secret output, derived passwords,
   portable master keys. Not even in debug builds. The same applies to the build: signing
   certificates, notarisation keys and keychain passwords never reach a log, so no `set -x`
   in the scripts or CI steps that handle them.
5. **Every `fido_*_new()` needs a paired free via `defer`.** Use
   `DeviceRepository.withOpenedDevice` rather than opening devices by hand.
6. **Account-level password policy is not persisted.** `revision` and `policy` are rebuilt
   with defaults on every enumeration, because the authenticator stores no metadata for
   them. A persistent per-account policy editor needs key-side storage (`largeBlobs`)
   first — `credBlob` cannot serve, it is write-once at credential creation.
7. **The click budget is a test, not a preference.** `HUDReducer.primaryAction` states what
   `⏎` must do in every state — with a key unlocked and an account preselected, "generate and
   copy", never "now choose an account" — and it is pinned twice, by `HUDReducerTests` on
   hand-built snapshots and by `HUDStoreTests` on real store state. Nothing dispatches
   through it: each screen owns its default button, because a second global Return handler
   fired alongside the focused field's submit and spent two PIN attempts on one keypress.
   Any new screen has to keep the two in agreement.
8. **Only account ids, labels and device signatures may be written to disk**
   (`Preferences.LastUsed` and `labelHistory.v2`, both clearable from Preferences).
   Passwords, PINs and backup keys never are — see rule 4. Label history is scoped to
   `LabelScope`, the account's `credentialIdB64`, rather than kept as one global list: a
   chip offered under the wrong account derives a password that is valid and wrong, which
   is the failure mode the chips exist to prevent. Device signatures and paths are stored
   for display only — neither identifies a key (see "Working with hardware").

### Secrets on the clipboard

Copy secrets with `ClipboardService.copySecret`, never `NSPasteboard` directly. It marks
the value concealed so clipboard managers skip it, keeps it off Universal Clipboard, and
clears it after a timeout — checking the change count first so it never wipes something the
user copied afterwards.

### Where key operations live

The panel keeps only what a key needs before it can be used at all: **unlock**, and
**bootstrap** (`.setPIN`, for a key with no PIN — without it a new key is a brick inside the
app). Everything else about the key itself — changing the PIN, resetting it, and the four
`authenticatorConfig` settings — lives in the manager window's Settings tab.

Two consequences worth knowing:

- A key demanding a PIN change routes to `.pinChangeRequired`, which is a **signpost, not a
  form**: it explains and opens the manager. The route has to exist because such a key
  refuses every other operation, so the panel cannot simply show the unlock field.
- **`panelDidClose` no longer disarms a reset.** The wizard is a sheet in another window, and
  that window taking focus is what closes the panel — disarming there would cancel the flow
  at the exact moment the user went to drive it. The arming still expires on its own
  (`DeviceStore.armReset`), which is what stops a forgotten one from firing on the next key
  plugged in. `PinManagementTests` pins both halves.

### Authenticator settings

`DeviceConfiguring` exposes CTAP 2.1 `authenticatorConfig`: `alwaysUv`, minimum PIN length,
force PIN change, enterprise attestation. All four need the PIN and **none needs a touch**
(measured: ~0.15 s each). Two of them are one-way doors — raising the minimum PIN length can
never be lowered again, and enterprise attestation cannot be turned off — so both sit behind
an explicit confirmation that says so, and every control is gated on the key actually
advertising the option. An option the key never mentions means "not implemented"; `false`
means "implemented and off", and a switch offered for the first can only ever fail.

Verified on hardware: a key accepts `setMinPINLength` with a value *equal* to the current
minimum and changes nothing, so the UI offers only a real increase — a button that silently
does nothing is worse than no button.

**The minimum PIN length cannot be lowered by any software**: CTAP has no command for it, so
the only way back is a full reset, which erases every credential. The control therefore shows
the current value as a fact and asks separately for a new, larger one. It used to be a stepper
whose lower bound *was* the current value, so pressing "down" did nothing and the whole thing
read as broken.

### Known, deliberate gaps

- A pending key operation cannot really be cancelled. `DeviceRepository.withOpenedDevice`
  never surfaces the handle needed for `fido_dev_cancel`, so `HUDStore.abandonTouch` only
  hides the prompt and discards the result — **and the key finishes the operation anyway**.
  Verified on hardware: a client that gave up after 1.2 s still left a new resident
  credential behind. Abandoning an enrolment can therefore occupy a slot with a credential
  the app never recorded. The FIDO manager window is currently the only way to see one.
- `PasswordEngine` does not guarantee that every enabled character class appears; the
  top-up step can overwrite its own fixes. ~3% at length 8, effectively zero at the default
  20. Recorded in `CharacterClassInvariantTests` as an expected failure; fixing it requires
  a new policy version.

## Layout

```
Sources/FidoPassCore/
  Public/       facade
  Models/       Account, PasswordPolicy, FidoDevice
  Protocols/    DI seams used by tests
  Devices/      libfido2 device access, capability probing, PIN set/change and reset,
                wide inspection, authenticator configuration
  Enrollment/   credential creation, enumeration, deletion
  Secrets/      hmac-secret, HKDF, password mapping
  Support/      salts, crypto helpers, libfido2 context

Sources/FidoPassApp/
  App/              AppDelegate — entry point, activation policy, main menu, hotkey
  Stores/           KeyBackend seam, DeviceStore, AccountStore, GenerationStore,
                    LabelStore, InventoryStore, Preferences, HUDStore (navigation),
                    HUDReducer (pure)
  HUD/Presentation/ NSStatusItem, NSPanel, icon states, Carbon hotkey, aux windows
  HUD/Views/        the panel's SwiftUI screens
  Settings/         Preferences and onboarding windows
  ViewModels/       CryptoEditorSession
  Views/CryptoEditor/  the separate editor window
  Views/Manager/    the FIDO manager window — every credential on a key, as the key
                    reports it, with no product framing, plus the authenticator's own
                    settings (`authenticatorConfig`)
  Services/         system integrations, error presentation, recovery sheet
```

The stores are separate observable objects on purpose: a clipboard countdown ticking once a
second must not redraw the whole panel. Keep new state in the store that owns it, and keep
`HUDReducer` pure.

## Conventions

- One type per file, file named after the type. New screens follow the existing folder shape.
- **English only** in code, comments, docs, and commit messages.
- Prefer `async`/`await` over GCD. Do not mix `Task.detached`, `Task`, and `DispatchQueue`
  for the same job.
- System integrations go through a service wrapper — no direct AppKit calls in views.
- Tests use the protocols in `Protocols/`; shared mocks live in `Tests/TestSupport/`.

## Working with hardware

- CI has no authenticator. Anything touching `fido_dev_*` must be behind a protocol so
  tests can run without a key.
- **Opening a key seizes it.** libfido2 on macOS opens with `kIOHIDOptionsTypeSeizeDevice`
  (`hid_osx.c`), so while FidoPass holds a key open no other process — `ykman`, a browser —
  can use it. A key is therefore opened **only because the user asked**: opening the panel,
  typing into the PIN field, pressing a button, running an operation. Never because a key
  appeared. The app used to read a key's status from `UnlockView.onAppear`, which fires the
  moment one is plugged in, and that made `ykman fido reset` impossible while FidoPass was
  running. `listDevices()` is safe — `fido_dev_info_manifest` reads HID properties without
  opening anything. `DeviceAccessTests` counts the opens.
- **Device paths (`ioreg://…`) change on every reconnect.** Never persist one or use it as
  a stable identity — it is a session handle only. A vendor/product signature is no better:
  two keys of a model share it, and changing enabled interfaces changes it. Neither is an
  AAGUID: WebAuthn requires one to be shared by at least 100 000 devices so it cannot
  identify a person. It is usable only as a negative check — a *different* AAGUID proves a
  different key came back, which is what the reset flow uses it for — never as a positive one.
- **A FIDO2 key locks permanently after 8 wrong PINs.** Never write a test, script, or
  retry loop that guesses PINs against real hardware. `PinPolicy` rejects a malformed PIN
  before it reaches the key precisely so a doomed attempt costs nothing; keep it that way.
- **A reset fails in two different ways and they mean opposite things.** `NOT_ALLOWED` means
  the command arrived too late — the key accepts one only in the first seconds after power-up,
  and `ykman fido reset` does not even orchestrate the reconnect, it just fails with that.
  `USER_ACTION_TIMEOUT` (`FidoStatus.userActionTimeout`) means the opposite: the command was in
  time, the key blinked, and nobody touched it. Measured on hardware: a timely touch resets in
  ~6 s; an untouched key gives up at ~28 s. The second is the usual failure, so the touch stage
  counts down rather than sitting on one sentence — half a minute of silence reads as a hang.
- **`fido_dev_reset` blocks forever by default** (`timeout_ms` is -1, `dev.c`), and the app
  cannot cancel a pending operation — `fido_dev_cancel` is not surfaced. Always set a
  deadline with `fido_dev_set_timeout` before a reset. Most keys also refuse a reset issued
  more than a few seconds after power-up, which is why the flow makes the user reconnect and
  fires from `DeviceStore.armedReset` rather than from the usual refresh.
- **A key is exclusive, and every call to it is serialised.** `KeyWorker` funnels all
  backend work through one serial queue (`KeyAccessQueue`). Two overlapping operations mean
  one fails for a reason unrelated to anything the user did — impossible while the panel was
  the only caller, but the manager window can read a key while the panel derives a password
  from it. `KeyAccessSerialisationTests` counts the overlap. Never start key work off a
  different queue to "make it parallel": the device cannot be shared.
- **The FIDO manager window reads the key when it is opened, and never otherwise.** Choosing
  it from a menu is the request — the same reasoning that lets opening the panel read a key's
  status. What must not happen is a read triggered by anything else: a key being plugged in,
  a refresh, a window merely existing. `InventoryStore` never reads on its own, and
  `InventoryStoreTests` pins that the way `DeviceAccessTests` pins it for the panel.
- **Credential management never needs a touch, only the PIN** — listing, renaming and
  deleting a credential all come back without one. Only `makeCredential`, `getAssertion` and
  `reset` make the key wait for a finger, so only they go through `withTouchPrompt`.
- **A key does not refuse a duplicate credential — it replaces one.** `makeCredential` with
  the same `rp.id` and the same `user.id` overwrites the existing resident credential and
  the slot count does not move. That is what the duplicate check in `EnrollmentService.enroll`
  is for, and why it is load-bearing rather than a nicety: without it a repeated enrolment
  would destroy the credential whose passwords the user still relies on.
- Resident-key slots are finite (100 on a YubiKey 5). Clean up credentials created during
  manual testing.
