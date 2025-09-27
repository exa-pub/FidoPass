# FidoPass

Hardware-backed password generator for macOS that delegates all sensitive operations to a FIDO2 authenticator via the `hmac-secret` extension. FidoPass never writes derived secrets to disk—only deterministic metadata lives on the machine.

## Table of Contents
- [Features](#features)
- [Requirements](#requirements)
- [Getting Started](#getting-started)
- [FidoPassCore Library](#fidopasscore-library)
- [Command-Line Notes](#command-line-notes)
- [Building & Packaging](#building--packaging)
- [Data Storage & Privacy](#data-storage--privacy)
- [How It Works](#how-it-works)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

## Features
- Derives deterministic passwords via a CTAP2/FIDO2 authenticator that advertises the `hmac-secret` extension.
- Leaves secrets on the key: only credential metadata (credential ID, RP ID, password policy, device path) is stored locally in the macOS Keychain.
- SwiftUI app for macOS 12+ with device grouping, PIN-gated unlock, recent-label shortcuts, and live search.
- Portable accounts allow the master key material to be exported and re-imported on another authenticator.
- Copy-to-clipboard helpers, light/dark appearance, and SF Symbol-based UI for accessibility.
- Release bundles include `libfido2`, `libcbor`, and `libcrypto`, so users without Homebrew can run the packaged app.

## Requirements
- macOS 12 Monterey or newer.
- Swift toolchain 5.9 or newer.
- Homebrew packages: `libfido2` and `pkg-config` (brings in `libcbor`, `openssl@3`, etc.).
- Xcode Command Line Tools for `install_name_tool`, `codesign`, and other build utilities.
- A CTAP2/FIDO2 authenticator with `hmac-secret` support (YubiKey 5, Nitrokey 3, SoloKeys, …).

## Getting Started

### 1. Install prerequisites
```bash
brew install libfido2 pkg-config
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH" # adjust if needed
```

### 2. Build and launch the SwiftUI app
```bash
swift build --product FidoPassApp
swift run FidoPassApp
```

### 3. Enroll an account and generate passwords
1. Plug in your authenticator and ensure it has a PIN configured.
2. Use the sidebar to unlock the device (enter the PIN when prompted).
3. Create a new account from the toolbar or **File → New account (⌘N)**.
4. Provide a label (e.g., `example.com`) and click **Generate** to obtain a password. The app can copy the result directly to the clipboard.

The app maintains recent labels, groups accounts by physical device, and surfaces errors through standard macOS alerts.

## FidoPassCore Library
Applications can integrate `FidoPassCore` directly when they need a programmatic API:

```swift
import FidoPassCore

let core = FidoPassCore.shared
let device = try core.listDevices().first
let account = try core.enroll(accountId: "demo", devicePath: device?.path)
let password = try core.generatePassword(account: account, label: "example.com")
```

`Account` models are Codable and can be persisted outside of the supplied Keychain store if you need custom storage.

## Command-Line Notes
Older revisions shipped a CLI target named `fidopass`. If you have that product available locally, the typical workflow looked like:
```bash
swift run fidopass enroll --account demo --rp fidopass.local --user "Demo User" --uv
swift run fidopass gen --account demo --label example.com --len 20 --copy
```
The current package focuses on the SwiftUI app and core library; a refreshed CLI is planned but not yet included in `Package.swift`.

## Building & Packaging
- `swift build -c release --product FidoPassApp` produces a release binary in `.build/release/FidoPassApp`.
- `scripts/build_app.sh` assembles a relocatable `.app` bundle, copying the required dynamic libraries and applying an ad-hoc codesign signature. Adjust the `BUNDLE_ID` in the script before distributing a release build.
- `scripts/create_dmg.sh` stages the bundle into a distributable DMG image (`FidoPass.dmg`). Both scripts determine the project root automatically, so they can be executed from any working directory.
- Packaging requires `brew` in `PATH`, `codesign`, and `hdiutil` (macOS default).
- `scripts/update_icon.sh /path/to/AppIcon.icns` (an `.iconset` directory or a high-resolution `.png`) swaps in a new app icon and refreshes the editable `Icon.iconset` when `iconutil` is available. The `Icon.iconset` folder is only used as a source asset for maintainers; the build consumes the generated `AppIcon.icns`.

## Data Storage & Privacy
- Account metadata is serialized to JSON and stored in the macOS Keychain with `kSecAttrAccessibleAfterFirstUnlock`.
- Recent labels are synced via `UserDefaults` and `NSUbiquitousKeyValueStore` when iCloud is available.
- Generated passwords are kept in memory only; copying moves them to the system clipboard where they follow normal macOS clipboard lifecycle rules.

## How It Works
- Enrollment issues `makeCredential` with `FIDO_EXT_HMAC_SECRET`, creating a resident credential by default.
- Password generation calls `getAssertion` with the saved credential ID, enabling `hmac-secret` and supplying a deterministic salt derived from `label + rpId + accountId`.
- The authenticator returns a 32-byte secret that is stretched via HKDF and mapped into a password respecting the configured policy (length, character classes, ambiguity filters).
- Portable accounts XOR an imported key with the device-derived secret so the same password material can be regenerated on another authenticator.

## Roadmap
- First-class CLI rebuilt on `swift-argument-parser`.
- Editable password policies (length and character classes) from the UI.
- Automatic device hot-plug detection and refreshed lists without manual reloads.
- Additional filters (per-device, per-RP) and password policy profiles.
- Localized interface (English/Russian) backed by resource bundles.
- Import/export utilities for metadata and portable keys.

## Contributing
Issues and pull requests are welcome. If you intend to work on authenticator communication, make sure you can test with real hardware so that changes can be validated end-to-end.

## License
FidoPass is available under the MIT License. Embedded `libfido2` remains under the BSD-2-Clause license.
