# FidoPass

[![Build & Release](https://github.com/exa-pub/FidoPass/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/exa-pub/FidoPass/actions/workflows/build.yml)
[![Latest Release](https://img.shields.io/github/v/release/exa-pub/FidoPass?display_name=tag&sort=semver)](https://github.com/exa-pub/FidoPass/releases/latest)

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
- Leaves secrets on the key; credential metadata stays on the authenticator and the app only caches it in memory while running.
- Lives in the menu bar: a compact HUD opens with a global shortcut (⌘⌥P by default) or a
  click on the key icon. The usual password reaches the clipboard in two clicks, or in two
  keystrokes when the key is already unlocked.
- Remembers the account and label used last, so unlocking continues the action you asked
  for instead of dropping you on a list.
- Portable accounts allow the master key material to be exported and re-imported on another authenticator.
- Copy-to-clipboard helpers that mark the value as concealed, keep it off Universal
  Clipboard, and clear it automatically after a short delay.
- Shows how many PIN attempts remain before an authenticator locks itself permanently.
- Exports a printable recovery sheet holding everything needed to reproduce an account's
  passwords — and no secrets.
- Encrypts and decrypts short texts with the same key (AES-256-GCM), for secrets that have
  to be stored somewhere you do not control.
- Every release bundle carries `Contents/Resources/DEPENDENCIES.txt` recording the exact
  libraries and versions it was built from.
- Release bundles include `libfido2`, `libcbor`, and `libcrypto`, so users without Homebrew can run the packaged app.

## Requirements
- macOS 13 Ventura or newer.
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

### 2. Build and launch the app
FidoPass is a menu-bar application: the status item and the activation policy only behave
correctly from an app bundle, so `swift run` is not the way to start it.

```bash
bash scripts/build_app.sh
open .build/release/FidoPass.app
```

### 3. Enroll an account and generate passwords
1. Plug in your authenticator and ensure it has a PIN configured.
2. Open the HUD from the menu-bar key icon, or press ⌘⌥P.
3. Enter the key PIN. It is kept in memory for five minutes.
4. Press ⌘N (or use the ··· menu) to create an account — `vault`, say. Portable is the
   default: its backup key can be entered on a second authenticator, so the passwords
   survive losing this key. Write the backup key down when it is shown; it is shown once.
5. Pick a label and press **Copy password**. The clipboard clears itself after 45 seconds,
   and the menu-bar icon shows that a secret is still on it.

Rare actions — backup key, recovery sheet, text encryption, deleting an account — are on the
right-click menu of an account row (and on the `···` button that appears on hover). The
menu-bar icon also has a right-click menu with the same commands.

## FidoPassCore Library
Applications can integrate `FidoPassCore` directly when they need a programmatic API:

```swift
import FidoPassCore

let core = FidoPassCore.shared
let device = try core.listDevices().first
let account = try core.enroll(accountId: "demo", kind: .portable, devicePath: device?.path)
let password = try core.generatePassword(account: account, label: "vault")
```

`Account` models are Codable and can be persisted using any storage backend your app provides.

## Building & Packaging
- `swift build -c release --product FidoPassApp` produces a release binary in `.build/release/FidoPassApp`.
- `scripts/build_app.sh` assembles a relocatable `.app` bundle, copying the required dynamic libraries and applying an ad-hoc codesign signature. Adjust the `BUNDLE_ID` in the script before distributing a release build.
- `scripts/create_dmg.sh` stages the bundle into a distributable DMG image (`FidoPass.dmg`). Both scripts determine the project root automatically, so they can be executed from any working directory.
- Packaging requires `brew` in `PATH`, `codesign`, and `hdiutil` (macOS default).
- `scripts/update_icon.sh /path/to/AppIcon.icns` (an `.iconset` directory or a high-resolution `.png`) swaps in a new app icon and refreshes the editable `Icon.iconset` when `iconutil` is available. The `Icon.iconset` folder is only used as a source asset for maintainers; the build consumes the generated `AppIcon.icns`.

## Compatibility
Password derivation is a frozen contract: for `PasswordPolicy.version == 1` the output will
never change. `GoldenVectorsTests` pins the salts, the character mapping and the full
generator, so an accidental change fails the build rather than silently invalidating
passwords already in use.

## Data Storage & Privacy
- Account metadata lives on the authenticator as resident credentials; the macOS app keeps only in-memory copies during a session.
- Recent labels are synced via `UserDefaults` and `NSUbiquitousKeyValueStore` when iCloud is available.
- The account and label used last are written to `UserDefaults`, so the HUD can offer the
  right action before the key is unlocked. That account id is the only account data that
  reaches the disk, and it can be switched off — Preferences → "Remember the last account
  and label", with "Forget last used" to erase what was already stored. No password, PIN or
  backup key is ever written anywhere.
- Generated passwords are kept in memory only; copying moves them to the system clipboard where they follow normal macOS clipboard lifecycle rules.

## How It Works
- Enrollment issues `makeCredential` with `FIDO_EXT_HMAC_SECRET`, creating a resident credential by default.
- Password generation calls `getAssertion` with the saved credential ID, enabling `hmac-secret` and supplying a deterministic salt derived from `label + rpId + accountId`.
- The authenticator returns a 32-byte secret that is stretched via HKDF and mapped into a password respecting the configured policy (length, character classes, ambiguity filters).
- Portable accounts XOR an imported key with the device-derived secret so the same password material can be regenerated on another authenticator.

## Installing a Release Build
Release DMGs are signed ad-hoc rather than notarised, so Gatekeeper quarantines them after
download and reports the app as damaged. Until notarisation is in place, either right-click
the app and choose **Open**, or clear the quarantine flag:

```bash
xattr -d com.apple.quarantine /Applications/FidoPass.app
```

Building locally with `scripts/build_app.sh` avoids this entirely.

## Roadmap
- Notarised, Developer ID-signed releases so downloads open without a Gatekeeper warning.
- On-key management: set and change the PIN, enrol fingerprints.
- Real cancellation of a pending key operation (`fido_dev_cancel`); today the Cancel button
  hides the prompt and discards the result while the call finishes in the background.
- Editable password policies. Requires storing metadata on the authenticator first
  (`largeBlobs`) — see `AGENTS.md`, rule 6.
- Localized interface (English/Russian) backed by resource bundles.

## Contributing
Issues and pull requests are welcome. If you intend to work on authenticator communication, make sure you can test with real hardware so that changes can be validated end-to-end.

## License
FidoPass is available under the MIT License. Embedded `libfido2` remains under the BSD-2-Clause license.
