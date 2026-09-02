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
swift build -Xswiftc -warnings-as-errors   # what CI runs: every target is in Swift 6 mode
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

Three modules, one direction of dependency:

```
FidoPassApp (entry point only) ──▶ FidoPassAppKit (AppKit shell + SwiftUI + stores)
                                          └──▶ FidoPassCore ──▶ CLibfido2 (system)
```

- `FidoPassCore` — domain logic. No AppKit, no SwiftUI, no UI state.
- `FidoPassAppKit` — the whole application as a library, so tests import one module and one
  place assembles it. Talks to the core through `KeyBackend`, never directly.
- `FidoPassApp` — `@main` and nothing else.
- `CLibfido2` — system-library shim.

Release bundles are signed with a Developer ID and notarised. `build_app.sh` and
`create_dmg.sh` sign whatever they produce when `FIDOPASS_SIGN_IDENTITY` names an identity,
and fall back to an ad-hoc signature when it is unset — so a machine without a certificate
still builds. Signing runs last: `install_name_tool` invalidates anything signed before it.

The app is a menu-bar panel (the "HUD" in the docs and the README), not a window:

```
AppDelegate ─▶ AppContainer (composition root, one per process)
                 ├─ KeyWorker ─▶ KeyBackend ─▶ FidoPassCore      one serial queue for the key
                 ├─ DeviceStore · AccountStore · GenerationStore · InventoryStore ·
                 │  LabelStore · Preferences · ClipboardService
                 ├─ TouchGate            the one door to the key: prompt / busy, per surface
                 ├─ ResetCoordinator     the reset wizard, arming and hot-plug included
                 ├─ EditorCoordinator    which key the open editor is bound to
                 ├─ PanelStore           the menu-bar panel: route, selection, intent
                 │    ├─ PinFormModel    bootstrap form (the manager has its own)
                 │    └─ LabelEditor     the label row and its draft
                 ├─ ManagerStore         the manager window
                 └─ WindowRouter ◀─ AppWindows (PanelController + AuxiliaryWindows)
```

`MenuBarExtra` is deliberately not used: it cannot be opened from a global hotkey, cannot be
kept open across a save panel or a key touch, and does not give the PIN field focus.

Three shapes that the layout enforces:

- **Every window has its own store.** `PanelStore` for the panel, `ManagerStore` for the
  manager, `CryptoEditorSession` for the editor. What they share are the stores underneath
  and `TouchGate`. The change-PIN form used to live on the panel's store and be edited by the
  manager's sheet; closing the panel wiped what was being typed in the other window.
- **Stores do not know about windows.** Anything that opens or closes one is a method on
  `WindowRouter`; `AppWindows` is the AppKit implementation, `RecordingWindowRouter` the test
  one. The menu-bar icon *observes* the stores through Combine rather than being poked.
- **Stores keep a `PresentedError`, not a string.** The view renders it and adds what only it
  knows — the PIN attempts left. Tests assert on the kind.

## Hard rules

1. **`import CLibfido2` only inside `FidoPassCore`.** No raw C type — no `OpaquePointer` —
   in any `public` signature.
2. **Views never call `FidoPassCore` or a store's key operation directly.** Everything that
   makes the authenticator wait for a finger goes through `TouchGate.withTouchPrompt`, and
   every silent wait through `TouchGate.withBusy`, each saying which surface it belongs to.
   The one place that bypassed it forgot to raise the touch prompt, so the app looked frozen
   while the key waited to be tapped.
3. **Never change password derivation for `policy.version == 1`.** Derivation is a
   compatibility contract: changing it silently invalidates every password a user already
   relies on, and a vault master password has no reset path. New behaviour goes under a new
   `version`, opt-in. `GoldenVectorsTests` pins salts, character mapping and the full
   generator — if it fails you broke someone's logins, so never update the expectations to
   match new behaviour. `DerivationParameters.v1` is the one value every account derives with
   until the key can store parameters per account; passing anything else derives a different
   password, which is the point of the type.
4. **Never log, print, or write secrets** — PINs, hmac-secret output, derived passwords,
   portable master keys. Not even in debug builds. The same applies to the build: signing
   certificates, notarisation keys and keychain passwords never reach a log, so no `set -x`
   in the scripts or CI steps that handle them.
5. **Every `fido_*_new()` needs a paired free via `defer`.** Use
   `DeviceAccessing.withOpenedDevice` rather than opening devices by hand, and `CborInfo`
   rather than walking `fido_cbor_info_t` yourself — there used to be three copies of that.
6. **Account-level password policy is not persisted.** `DerivationParameters` is rebuilt as
   `.v1` on every enumeration, because the authenticator stores no metadata for it. A
   persistent per-account policy editor needs key-side storage (`largeBlobs`) first —
   `credBlob` cannot serve, it is write-once at credential creation. When that storage
   exists, `DerivationParameters` is what it loads into.
7. **The click budget is a test, not a preference.** `PanelReducer.primaryAction` states what
   `⏎` must do in every state — with a key unlocked and an account preselected, "generate and
   copy", never "now choose an account" — and it is pinned twice, by `PanelReducerTests` on
   hand-built snapshots and by `PanelStoreTests` on real store state. Nothing dispatches
   through it: each screen owns its default button, because a second global Return handler
   fired alongside the focused field's submit and spent two PIN attempts on one keypress.
   Any new screen has to keep the two in agreement.
8. **Only account ids, labels and device signatures may be written to disk**
   (`Preferences.LastUsed` and `labelHistory.v2`, both clearable from Preferences).
   Passwords, PINs and backup keys never are — see rule 4. Label history is scoped to
   `LabelScope`, the account's `credentialIdB64`, rather than kept as one global list: a
   chip offered under the wrong account derives a password that is valid and wrong, which
   is the failure mode the chips exist to prevent. Device signatures and paths are stored
   for display only — neither identifies a key (see "Working with hardware"). The
   `UserDefaults` keys keep their `hud.` prefix whatever the code calls the panel: they are a
   persisted format.

### Secrets on the clipboard

Copy secrets with `ClipboardService.copySecret`, never `NSPasteboard` directly. It marks
the value concealed so clipboard managers skip it, keeps it off Universal Clipboard, and
clears it after a timeout — checking the change count first so it never wipes something the
user copied afterwards. One instance, owned by `AppContainer`; the manager's views get it
through the SwiftUI environment.

### Where key operations live

The panel keeps only what a key needs before it can be used at all: **unlock**, and
**bootstrap** (`.setPIN`, for a key with no PIN — without it a new key is a brick inside the
app). Everything else about the key itself — changing the PIN, resetting it, and the four
`authenticatorConfig` settings — lives in the manager window's Settings tab, driven by
`ManagerStore`.

Three consequences worth knowing:

- A key demanding a PIN change routes to `.pinChangeRequired`, which is a **signpost, not a
  form**: it explains and opens the manager. The route has to exist because such a key
  refuses every other operation, so the panel cannot simply show the unlock field.
- **`panelDidClose` clears the panel's own form and nothing else.** The reset wizard and the
  change-PIN form live in the manager, and the manager taking focus is what closes the panel
  — touching them there would cancel the flow at the exact moment the user went to drive it.
  The arming still expires on its own (`DeviceStore.armReset`), which is what stops a
  forgotten one from firing on the next key plugged in. `ResetCoordinatorTests` and
  `WindowIsolationTests` pin both halves.
- **A reset's touch prompt is drawn in the manager**, where the wizard is; the panel neither
  shows it nor is held open by it. `TouchGate` carries the surface with the prompt.

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

- A pending key operation cannot really be cancelled. `DeviceAccessing.withOpenedDevice`
  never surfaces the handle needed for `fido_dev_cancel`, so `TouchGate.abandonTouch` only
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
  Models/       Account (what the key holds), AccountHandle (account + connected key),
                DerivationParameters, PasswordPolicy, PinPolicy, FidoDevice, AuthenticatorInfo,
                CredentialInventory, ResidentCredential
  Protocols/    DI seams used by tests — one gerund per protocol: Enrolling, SecretDeriving, …
  Devices/      libfido2 device access, capability probing, PIN set/change and reset,
                wide inspection, authenticator configuration
  Enrollment/   credential creation, enumeration, deletion
  Secrets/      hmac-secret, HKDF, password mapping
  Support/      salts, crypto helpers, libfido2 context, CborInfo, PinScope

Sources/FidoPassAppKit/
  App/          AppDelegate — assembles the application, main menu, activation policy
  Composition/  AppContainer (object graph, cross-store reactions), WindowRouter
  Backend/      KeyBackend facets, LiveKeyBackend, KeyWorker, KeyAccessQueue
  Stores/       DeviceStore, AccountStore, GenerationStore, InventoryStore, LabelStore, Preferences
  Flows/        PanelStore, ManagerStore, TouchGate, PinFormModel, ResetCoordinator,
                LabelEditor, EditorCoordinator
  Reducers/     PanelReducer (pure), PanelSnapshot, PanelPrimaryAction
  Model/        AccountRef, LabelScope, PresentedError, ResetFlow, TouchPrompt, …
  Services/     system integrations: clipboard, hot-plug and session-lock monitors, PIN vault,
                hotkey registration, launch at login, error presentation, recovery sheet
  Windows/      PanelController, PanelWindow, StatusItemIcon, AuxiliaryWindows, AppWindows
  UI/Panel/     the panel's screens        UI/Manager/   the FIDO manager window
  UI/Editor/    the text editor            UI/Preferences/, UI/Onboarding/
  UI/Shared/    components used by more than one window

Sources/FidoPassApp/   FidoPassMain.swift, the app icon for build_app.sh
```

The stores are separate observable objects on purpose: a clipboard countdown ticking once a
second must not redraw the whole panel. Keep new state in the store that owns it, keep
`PanelReducer` pure, and keep cross-store reactions ("this key went away") in `AppContainer`.

## Conventions

- **One type per file, file named after the type** — strictly for stores, models, protocols,
  backend and reducers. A screen in `UI/` may keep its own private components beside it;
  anything used by two windows goes to `UI/Shared/`.
- **English only** in code, comments, docs, and commit messages.
- **In code the panel is `Panel*`; in prose it is the HUD.** Persisted keys are neither: they
  stay `hud.*`.
- Prefer `async`/`await` over GCD. Do not mix `Task.detached`, `Task`, and `DispatchQueue`
  for the same job.
- Every target is in the **Swift 6 language mode** and CI builds with warnings as errors. A
  callback from C or AppKit says which actor it runs on (`MainActor.assumeIsolated` where the
  API guarantees main); `@unchecked Sendable` is allowed only with a comment saying what
  guards the state (`SecurePinVault`, `DeviceMonitorService`, `KeyAccessQueue`).
- System integrations go through a service wrapper — no direct AppKit calls in views.
- Tests use the protocols in `Protocols/`; shared mocks live in `Tests/TestSupport/`, the
  app-level `MockKeyBackend` and `AppTestFactory` in `Tests/FidoPassAppTests/AppTestSupport.swift`.

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
  opening anything. `DeviceAccessTests` counts the opens, including the one typing a PIN
  triggers for a key nobody has asked yet (`PanelStore.pinDraftDidChange`).
- **Every core operation names the connected key.** `AccountHandle` is an `Account` plus the
  device path it was read from; there is no "first device" fallback, so nothing in the core
  can open a key the caller did not name.
- **Device paths (`ioreg://…`) change on every reconnect.** Never persist one or use it as
  a stable identity — it is a session handle only. A vendor/product signature
  (`FidoDevice.modelSignature`) is no better: two keys of a model share it, and changing
  enabled interfaces changes it. Neither is an AAGUID: WebAuthn requires one to be shared by
  at least 100 000 devices so it cannot identify a person. It is usable only as a negative
  check — a *different* AAGUID proves a different key came back, which is what the reset flow
  uses it for — never as a positive one.
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
  `ResetCoordinator` fires from `DeviceStore.onArmedKeyAppeared` rather than from the usual
  refresh.
- **A key is exclusive, and every call to it is serialised.** `AppContainer` builds exactly
  one `KeyWorker`, which owns the one `KeyAccessQueue`, and hands it to every store. Two
  overlapping operations mean one fails for a reason unrelated to anything the user did —
  impossible while the panel was the only caller, but the manager window can read a key
  while the panel derives a password from it. `KeyAccessSerialisationTests` counts the
  overlap. Never build a second worker to "make it parallel": the device cannot be shared.
- **The FIDO manager window reads the key when it is opened, and never otherwise.** Choosing
  it from a menu is the request — `ManagerStore.deviceDidAppear` is what that request runs,
  and `ManagerStoreTests` pins that a second appearance of the same key reads nothing. What
  must not happen is a read triggered by anything else: a key being plugged in, a refresh, a
  window merely existing. `InventoryStore` never reads on its own, and `InventoryStoreTests`
  pins that the way `DeviceAccessTests` pins it for the panel.
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
