# FidoPass

[![Build & Release](https://github.com/exa-pub/FidoPass/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/exa-pub/FidoPass/actions/workflows/build.yml)
[![Latest Release](https://img.shields.io/github/v/release/exa-pub/FidoPass?display_name=tag&sort=semver)](https://github.com/exa-pub/FidoPass/releases/latest)

**A menu-bar app for macOS that turns your security key into a password generator.**

Press ⌘⌥P, touch your key — a strong password lands on your clipboard. The same key and the
same label always give the same password, so there is nothing to store and nothing to sync.
The password does not exist until you ask for it, and then it lives only in memory and on
the clipboard, which clears itself after 45 seconds.

## What it is for

The handful of passwords you cannot keep in a password manager, because they are what
*opens* the password manager: a vault master password, a FileVault passphrase, a recovery
key.

It is deliberately not a manager for every website — no autofill, no browser extension. For
hundreds of site logins a real vault does the job better. FidoPass protects the one password
that vault depends on. And since these passwords often get typed by hand, the alphabet
leaves out characters that are easy to confuse: `i l o I L O 0 1`.

## What you need

- macOS 13 Ventura or newer.
- A FIDO2 security key with `hmac-secret` support and a PIN set — YubiKey 5, Nitrokey 3,
  SoloKey 2 and most modern keys qualify.

## Install

Download the DMG from the [latest release](https://github.com/exa-pub/FidoPass/releases/latest)
and drag FidoPass into Applications.

Releases are signed and notarised by Apple, so the DMG opens normally. The first launch
asks for confirmation because the app was downloaded from the internet — that is the usual
macOS prompt, not an error.

## First run

1. Plug in your security key.
2. Press **⌘⌥P**, or click the key icon in the menu bar.
3. Enter the key's PIN. It stays in memory for five minutes of inactivity and is never
   written anywhere; locking the Mac or unplugging the key clears it at once.
4. Press **⌘N** to create an account — `vault`, say. Leave it **portable**: such an account
   shows a backup key once, and that backup key imported on a second security key reproduces
   the same passwords. Write it down. The backup key is 60 characters and carries the
   account's *identity* — the coloured strip under its name — so the copy on the second key
   shows the same one.
5. Type a label and press **Copy password**. Touch the key when it blinks.

The same account plus the same label always produce the same password, so keep labels
consistent — `vault` and `Vault` are two different passwords.

## Everyday use

⌘⌥P opens the HUD from anywhere, and it remembers the account and label you used last: with
the key already unlocked, ⏎ generates and copies in a single keystroke. Inside the HUD,
**↑↓** pick an account, **←→** move between its labels, **⌘1–⌘3** jump to the first three,
and **⌘E** encrypts a piece of text with the same key — for notes or recovery codes you have
to keep somewhere you do not control.

The menu-bar icon shows while a secret is still on the clipboard. Copied secrets are marked
concealed, so clipboard-history apps skip them, and they stay off Universal Clipboard.

The HUD also shows how many PIN attempts remain. **A FIDO2 key locks itself permanently
after 8 wrong PINs** — there is no reset.

## If you lose your key

There is no reset, so plan for it in advance:

- **Keep the backup key** of a portable account. Imported on another FIDO2 key (⌘N →
  Import), it makes that key produce the same passwords and show the same identity. Backup
  keys written down by earlier versions — 44 characters — still import; the form asks for an
  identity then.
- **Print the recovery sheet** (right-click an account). It holds everything needed to
  reproduce that account's passwords and contains no secrets, so it is safe to file with
  your documents — and useless without the key or the backup key.

## What is stored

Never written to disk: passwords, PINs, backup keys, anything derived from your security
key. Account metadata lives on the key itself, as resident credentials.

The app keeps only two things locally, both clearable in Preferences: the labels you have
used, per account, so it can suggest them; and the account and label used last, so the HUD
can offer the right action before the key is unlocked.

## How it works

Enrollment creates a resident credential with the `hmac-secret` extension. Generating a
password asks the key for an assertion with a salt derived from `label + rpId + accountId`;
the key answers with 32 bytes that never leave it in any other form, which are stretched
with HKDF and mapped into a password. Portable accounts XOR an imported master key with the
key-derived secret, which is what lets a second authenticator reproduce the same passwords.

Every account also shows an identity: twelve bytes, drawn as hex and as a strip of twelve
colours. It takes no part in any derivation and is not a secret — it exists so that the same
account on two keys can be recognised by eye, and told from another account with the same
name. Local accounts derive it from their credential id; portable accounts keep it on the key
after the key material and carry it in the backup key.

## Accounts from earlier versions

A portable account created before identities existed shows grey, marked *needs migration*.
Its passwords are unchanged and it still exports its backup key; generating and encrypting
wait for the migration, which writes an identity to the key under the PIN, without a touch.
If the same account was already migrated on another key, enter the identity that key shows so
that both agree about what is the same account.

Derivation for policy version 1 is a frozen contract: the output will never change. Golden
vectors pin the salts, the character mapping and the generator, so an accidental change
fails the build instead of silently invalidating passwords already in use.

## Building from source

```bash
brew install libfido2 pkg-config
bash scripts/build_app.sh
open .build/release/FidoPass.app
```

FidoPass is a menu-bar app and has to start from the bundle — `swift run` will not behave
correctly. `swift test` runs the whole suite and needs no hardware. The domain logic ships
as `FidoPassCore`, a library with no UI dependencies.

## Contributing

Issues and pull requests are welcome. [AGENTS.md](AGENTS.md) describes the architecture and
the invariants that must not be broken. If you plan to work on authenticator communication,
make sure you can test against real hardware.

## License

MIT. Embedded `libfido2` remains under the BSD-2-Clause license.
