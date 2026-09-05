# Working on FidoPass

FidoPass is a macOS menu-bar app for a few important passwords: vault, disk and backup
passphrases. Keep that scope; do not add per-site password-manager features.

## Commands

Local development needs Swift 6 and `brew install libfido2 pkg-config`.

```sh
swift build --disable-keychain --product FidoPassApp
swift test --disable-keychain                # no hardware; skips OpenSK if unbuilt
swift test --disable-keychain --filter GoldenVectors   # frozen password contract
bash scripts/test_keys.sh                    # required OpenSK tests; needs rustup
swift build --disable-keychain -Xswiftc -warnings-as-errors
bash scripts/build_app.sh                    # runnable bundle; also needs cmake
open .build/release/FidoPass.app
bash scripts/version.sh                      # what this checkout builds as
python3 scripts/test_version.py              # the version scheme, on throwaway repos
```

Run the bundle, not `swift run`. `--disable-keychain` stops SwiftPM asking for the login
keychain over the public Sparkle package. See [README](README.md#development) for build
prerequisites, [OpenSK setup](tools/test-authenticator/README.md#run) for the pinned Rust
toolchain, and [docs/release.md](docs/release.md) for tags, versions and the release job.

## Boundaries

- Dependencies: `FidoPassApp` (entry point) → `FidoPassAppKit` (UI/stores) → `FidoPassCore`.
  `FidoPassApp` also links `FidoPassUpdater`, which implements `UpdateService` over Sparkle.
- Only Core imports `CLibfido2`; only `Support/Argon2.swift` imports `CArgon2`; only
  `FidoPassUpdater` imports Sparkle. No C handles in public APIs. Pair C allocations with
  `defer` frees; use `DeviceAccessing.withOpenedDevice` and `CborInfo`.
- The updater never touches a key and never shows a window: every Sparkle callback becomes
  an `UpdateState`, rendered as a dot, a menu item and a row in Preferences. Release
  constants (team, feed, Sparkle public key and version) live in `scripts/release.env`.
- One `AppContainer`, one `KeyWorker`, one serial key queue. Views call flow actions;
  key work goes through `TouchGate` with its owning surface.
- Each window owns its forms. Stores use `WindowRouter`, keep `PresentedError`, and leave
  cross-store reactions to `AppContainer`. Keep reducers pure.

## Do not break

- **Compatibility:** preserve v1 password derivation, released account/link formats and
  golden vectors. New outputs need a new version. Accounts use `DerivationParameters.v1`
  until parameters can be stored on the key. See the [byte specification](docs/crypto.md).
- **Secrets:** never log or persist PINs, PRF output, passwords, master keys or message
  plaintext. Use `ClipboardService.copySecret` and `SecretTextView`; clear plaintext Undo.
  Do not log signing credentials or enable shell tracing around them.
- **Hardware:** open only for an explicit user action, with a named device and a deadline.
  Hot-plug and incoming links must not open a key. Tests use mocks/OpenSK, never real PIN
  guesses or a fallback to physical devices.
- **Operations:** keep exclusivity until the native call returns, even after abandonment.
  Invalidate queued work and late results with `OperationLease`. Never retry an
  authenticated command after PIN rejection; revoke the matching cached session.
- **Credentials:** check collisions before creation, fail closed on missing/corrupt records,
  and verify a migration copy before deleting the original. Delete a credential before its
  blob record; reconcile partial mutations from the key.
- **Identity:** use credential IDs and the current device path, never account names or model
  signatures. Paths are session handles. Preserve label bytes and scope history by
  credential; keep persisted `hud.*` and `labelHistory.v2` formats.
- **Interaction:** with an unlocked key and selected account, Return generates and copies.
  Keep `PanelReducer` and screen default buttons consistent; no second Return dispatcher.
- **Releases:** the version comes from `scripts/version.sh` alone; `CFBundleVersion` must
  stay ordered for Sparkle's comparator (`VersionComparatorTests`). Never move a tag or
  replace a published asset. Only Developer ID builds carry `SUFeedURL`; never point another
  build at the production feed. No `set -x` around signing keys; the Sparkle private key
  exists only in the `release` environment.

## Style and references

English in code, comments and docs. One type per file for models, stores, protocols,
backends and reducers; private UI components may stay with their screen. Use `Panel*` in
code and “HUD” in prose. Prefer async/await. Keep Swift 6 warnings clean; explain the
synchronization behind every `@unchecked Sendable`.

Read [test infrastructure](tools/test-authenticator/README.md) when changing transport tests.
Run checks relevant to the change; preserve compatibility test expectations.
