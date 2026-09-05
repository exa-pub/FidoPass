# FidoPass

[![Build & Release](https://github.com/exa-pub/FidoPass/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/exa-pub/FidoPass/actions/workflows/build.yml)
[![Latest Release](https://img.shields.io/github/v/release/exa-pub/FidoPass?display_name=tag&sort=semver)](https://github.com/exa-pub/FidoPass/releases/latest)

**Generate passwords from a FIDO2 security key on macOS.**

FidoPass lives in the menu bar. Choose an account and a label, touch your key, and copy the
password. The same account and exact label reproduce the same password without storing it.

It is designed for a handful of important passwords: a password-vault master password, a
disk-encryption passphrase or a backup key. The alphabet excludes `i l o I L O 0 1` to make
passwords easier to type by hand. Portable accounts can be backed up to another security
key, and accounts can also receive encrypted messages.

## Install

You need:

- **macOS 14 Sonoma or newer.**
- **A FIDO2 security key** supporting `hmac-secret` and `largeBlobs` to create accounts.
  Keys without `largeBlobs` can still use their existing FidoPass accounts.

Download the DMG from the [latest release](https://github.com/exa-pub/FidoPass/releases/latest)
and drag FidoPass into Applications. Release builds are Developer ID signed and notarised
by Apple.

FidoPass updates itself from there. It checks GitHub once a day; when a new release exists,
a dot appears next to the menu-bar icon and the menu offers **Update to …**. Nothing opens
on its own, and nothing installs until you click. Every update is signed twice — with the
FidoPass release key and by Apple — and verified before it is installed. Preferences →
Updates shows the version and holds the switches. Versions before 0.18 have no updater
and are updated by downloading the DMG once more.

## Get started

1. Connect your security key and open FidoPass.
2. Press **⌘⌥P**, or click its menu-bar icon, to open the HUD.
3. Enter the key's PIN. If it has no PIN, FidoPass offers to set one.
4. Press **⌘N** to create an account. Choose **Portable** if you need a backup, and keep
   the backup key shown after creation in a safe place.
5. Enter a label, such as `vault`, and press **Copy password**. Touch the key when prompted.

Labels are part of the password: `vault` and `Vault` produce different results. Preserve
the exact label when using an account on another Mac. Empty input blocks generation; Escape
restores the last confirmed label. New labels with surrounding whitespace require a choice:
**Use without surrounding whitespace** reproduces the earlier UI behaviour, while **Keep
exact label** uses those bytes as typed. Saved history is always used unchanged. Tabs, line
breaks and invisible control characters are rejected in new labels.

The PIN stays in memory for five minutes of inactivity by default; change the timeout in
Preferences. Locking the Mac or disconnecting the key clears the cached PIN. Failed PIN
attempts consume the authenticator's limited retries. Resetting it erases its credentials
and does not recover their passwords.

## Accounts and recovery

| Account | Where it works | Recovery |
| --- | --- | --- |
| **Portable** | On any key that imports its backup | Import the backup through **⌘N → Import**. |
| **Local** | Only on the key where it was created | Cannot be recovered if that key is lost or reset. |

A portable backup is a secret: it contains the master key needed to reproduce passwords.
Its 64 characters also carry the account's identity, shown as a coloured strip. Imported
copies show the same identity. Older 44-character backups still import.

The **recovery sheet**, available from an account's context menu, records labels and account
details. It contains no PIN, password or backup key; it helps you remember the inputs but
cannot replace the security key or a portable backup.

Accounts from earlier releases remain readable. Local v1 accounts keep their existing
passwords. Portable v1 accounts offer migration on keys with `largeBlobs`; the app verifies
the new copy before deleting the original. An interrupted migration can be finished or
its copy discarded. Existing passwords are preserved.

## Shortcuts

With the key unlocked and an account selected, **Return** generates and copies its password.
The HUD can remember the last account and keeps label history separately, per account.

| Shortcut | Action |
| --- | --- |
| **⌘⌥P** | Open the HUD from anywhere; configurable in Preferences |
| **↑ / ↓** | Select an account |
| **← / →** | Move between labels when not editing text |
| **⌘1–⌘3** | Select one of the first three accounts |
| **⌘N** | Create or import an account |
| **⌘E** | Issue an encryption key for the selected account |
| **⌘D** | Open the receiving window for the unlocked key |
| **⌘L** | Lock the selected key |

Key settings, PIN changes and reset are in the FIDO manager. Use **Manage this key…** in the
HUD to open the selected key; finish or cancel any existing form before switching keys.

## Encrypted messages

1. **Recipient:** select an account and press **⌘E**. Touch the key to issue a public
   encryption-key link, then share that link with the sender.
2. **Sender:** open **Encrypt a message…** from the menu-bar menu. Paste the key link,
   enter text and copy the resulting message link. Sending needs no security key.
3. **Recipient:** open **Decrypt a message…**, paste the message link and press **Decrypt**.
   Touch the security key when prompted.

Before encrypting, **compare the key's six emoji or twelve hex digits with its owner over
another channel**. The fingerprint is a checksum; someone replacing the link can recompute
it. Anyone with the public link can encrypt, so a message does not authenticate its sender.

Links carry their payload after `#`, which the browser does not send to `fidopass.org`.
Opening a link fills the appropriate window; it never accesses the key automatically.
A portable copy with the same identity can decrypt the same messages. Previously issued
key links remain usable; messages sent to the same key link are visibly related.

## Privacy and storage

- Account credentials and records live on the security key. FidoPass does not save PINs,
  generated passwords, portable backup keys or message plaintext to disk.
- Preferences and account label history stay on the Mac. Remembered account selection and
  label history can be cleared in Preferences.
- Copied secrets are excluded from Universal Clipboard and marked concealed for clipboard
  managers that honour that convention. They are cleared after 45 seconds, unless you
  have copied something else since.
- Closing a message window clears its text. The receiving window also closes when its key
  disconnects or locks; a sending draft stays open across a session lock.
- The update check is the app's only network request: one `GET` of the release list from
  `github.com` a day, and when you ask. GitHub sees your IP address and the app version;
  nothing about you or your keys is sent. Turn it off in Preferences → Updates. Builds you
  make yourself never check.

Passwords use `hmac-secret`, HKDF and a fixed character mapping. Messages use HPKE with
X25519, HKDF-SHA256 and AES-128-GCM. Released derivations and formats are pinned by test
vectors. See the [cryptographic specification](docs/crypto.md) for the exact bytes and
[emoji alphabet](docs/emoji-alphabet.md) for fingerprint encoding.

## Development

Build on macOS with a Swift 6 toolchain. CI requires the macOS 26 SDK or newer for the
current system appearance; the deployment target remains macOS 14.

For local development and unit tests:

```sh
brew install libfido2 pkg-config
swift build --disable-keychain --product FidoPassApp
swift test --disable-keychain
swift build --disable-keychain -Xswiftc -warnings-as-errors
```

`--disable-keychain` keeps SwiftPM from asking for your login keychain: it would look
there for a `github.com` credential before fetching the Sparkle package, which is public.

Tests need no physical key. To run the OpenSK integration suite, install Rust through
rustup, then follow [the test setup](tools/test-authenticator/README.md#run).
`swift test` skips that suite until its helper is built; CI requires it to run.

To build and launch the app:

```sh
brew install cmake pkg-config
bash scripts/build_app.sh
open .build/release/FidoPass.app
```

Run the `.app` bundle: `swift run` does not initialise the menu-bar app correctly.
The bundle script builds pinned libfido2, libcbor and OpenSSL sources for macOS 14, includes
them and the Sparkle framework in the app, and verifies dependencies and signatures. The
first build downloads them. It uses an ad-hoc signature unless `FIDOPASS_SIGN_IDENTITY`
names a Developer ID identity; only a Developer ID build carries an update feed, so a local
build never checks for updates. The version comes from the nearest git tag through
`scripts/version.sh`; a build made after a tag calls itself `0.17.0-dev.8`.

Use `bash scripts/create_dmg.sh` to package a DMG. Signed distribution also requires the
credentials described in [scripts/notarize.sh](scripts/notarize.sh). Releases are cut by
tagging; [docs/release.md](docs/release.md) has the procedure, the one-time setup and the
recovery steps.

For contributions, start with [AGENTS.md](AGENTS.md) and the
[OpenSK test harness](tools/test-authenticator/README.md).

### Virtual keys

Build the same app with OpenSK devices in place of USB keys:

```sh
bash scripts/build_app.sh --virtual-keys
open .build/release/FidoPass.app
```

The Virtual Devices panel lets you add/remove keys, connect/disconnect them and grant each
requested touch. Set PINs and manage accounts through the usual HUD and manager. Disconnecting
preserves a key's accounts; removing it or quitting the app discards its RAM-backed storage.
The app name, preferences, shortcuts and `fidopass://` links stay the same. Build again without
`--virtual-keys` to use physical keys.

Building this mode also needs the [pinned Rust toolchain](tools/test-authenticator/README.md#run).
The finished bundle includes the helper and runs without Rust or the checkout. It exposes no
system HID devices, so browsers and other FIDO clients cannot see these virtual keys.

```sh
FIDOPASS_VIRTUAL_KEYS=1 bash scripts/test_keys.sh
```

## License

[MIT](LICENSE). Bundled libfido2 is BSD-2-Clause, libcbor is MIT, OpenSSL is Apache-2.0,
and [Sparkle](https://sparkle-project.org) is MIT. The
[vendored Argon2 implementation](Sources/CArgon2/README.md) is CC0-1.0 / Apache-2.0.
Their license texts are included in the app resources. OpenSK is Apache-2.0 and used only
by tests.
