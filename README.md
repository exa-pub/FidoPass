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

- macOS 14 Sonoma or newer.
- A FIDO2 security key with `hmac-secret` support, a large-blob store (`largeBlobs` in its
  CTAP info — YubiKey 5 firmware 5.7 and other CTAP 2.1 keys) and a PIN set. A key without a
  large-blob store keeps serving the accounts already on it, but cannot take new ones.

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
   the same passwords. Write it down. The backup key is 64 characters and carries the
   account's *identity* — the coloured strip beside its name — so the copy on the second key
   shows the same one. The form offers a random identity; keep it, or type the one the same
   account already shows elsewhere.
5. Type a label and press **Copy password**. Touch the key when it blinks.

The same account plus the same label always produce the same password, so keep labels
consistent — `vault` and `Vault` are two different passwords.

## Everyday use

⌘⌥P opens the HUD from anywhere, and it remembers the account and label you used last: with
the key already unlocked, ⏎ generates and copies in a single keystroke. Inside the HUD,
**↑↓** pick an account, **←→** move between its labels, **⌘1–⌘3** jump to the first three,
**⌘E** issues an encryption key for the selected account and **⌘D** opens the window that
decrypts messages sealed under one — see [Encrypted messages](#encrypted-messages).

The menu-bar icon shows while a secret is still on the clipboard. Copied secrets are marked
concealed, so clipboard-history apps skip them, and they stay off Universal Clipboard.

The HUD also shows how many PIN attempts remain. **A FIDO2 key locks itself permanently
after 8 wrong PINs** — there is no reset.

## Encrypted messages

Any account can issue an **encryption key**: a `fidopass://keyv1?…` link (right-click the
account → *Encryption key…*, or ⌘E; one touch). The link is public — send it to anyone.
Whoever has it can encrypt a message for you in *Encrypt a message…* (right-click the
menu-bar icon), on any Mac, with no security key at all: paste the link, type the text, copy
the `fidopass://blobv1?…` link it produces. Only your security key opens it: *Decrypt a
message…* (⌘D), paste, press Decrypt, touch. Both kinds of link are clickable and open in
FidoPass; clicking one never touches the key by itself.

Each key shows a fingerprint — six emoji and twelve hex digits. **Compare them with the
key's owner over another channel before encrypting**: the link carries a checksum against
damage in transit, but only that comparison protects against a substituted link. To check a
link without FidoPass:

```bash
printf '%s' '<the link, up to the #>' | argon2 fidopass-keyfp-v1 -id -t 1 -m 15 -p 1 -l 6 -r
```

prints the twelve hex digits; the six emoji are the same six bytes through the
[emoji table](docs/emoji-alphabet.md).

Worth knowing: every press of *Encryption key…* mints a new key, and every key ever issued
keeps working. A key issued by a portable account also opens messages on a second security
key that imported the account's backup; a key issued by a local account dies with that
security key. Messages sealed under one key are visibly for the same key. Anyone with the
link can encrypt, and the recipient cannot tell who did. Nothing about a message is stored:
the text stays in the window until it closes or the key locks.

## If you lose your key

There is no reset, so plan for it in advance:

- **Keep the backup key** of a portable account. Imported on another FIDO2 key (⌘N →
  Import), it makes that key produce the same passwords and show the same identity. Backup
  keys written down by earlier versions — 44 characters — still import; the identity the
  form offers is used then.
- **Print the recovery sheet** (right-click an account). It holds everything needed to
  reproduce that account's passwords and contains no secrets, so it is safe to file with
  your documents — and useless without the key or the backup key.

## What is stored

Never written to disk: passwords, PINs, backup keys, anything derived from your security
key. Account metadata lives on the key itself: one resident credential per account under
the relying party `fidopass.org`, its identity as the credential's user id, its name as the
user name, and a small record in the key's large-blob store saying whether it is local or
portable — and, for a portable one, the masked master key.

The app keeps only two things locally, both clearable in Preferences: the labels you have
used, per account, so it can suggest them; and the account and label used last, so the HUD
can offer the right action before the key is unlocked.

## How it works

Enrollment creates a resident credential with the `hmac-secret` extension. Generating a
password asks the key for an assertion under a salt derived from the label; the key answers
with 32 bytes that never leave it in any other form, which are stretched with HKDF and mapped
into a password. Portable accounts XOR an imported master key with the key-derived secret,
which is what lets a second authenticator reproduce the same passwords.

The salts are wrapped the way the WebAuthn `prf` extension wraps them, so a web page served
from `fidopass.org` could ask the same key the same question through a browser and get the
same answer — the layout on the key is one a browser can read in a single assertion. The
page itself is not part of this release.

Every account also shows an identity: sixteen bytes, drawn as hex and as a strip of sixteen
colours. It takes no part in any derivation and is not a secret — it exists so that the same
account on two keys can be recognised by eye, and told from another account with the same
name. It is chosen when the account is created and stored on the key as the credential's
user id; the backup key carries it too.

An encryption key is derived from the account and a random nonce carried in the link: the
`hmac-secret` answer for that nonce (for a portable account, an HMAC under the master key)
goes through argon2id into an X25519 private key, whose public half is the link. Messages
are sealed with HPKE (RFC 9180 — X25519, HKDF-SHA256, ChaCha20-Poly1305); the recipient
re-derives the private key from the nonce, which is why nothing has to be stored. The
fingerprint is argon2id over the link text, deliberately slow, so that six emoji are enough.

## Accounts from earlier versions

Accounts created by earlier versions are in an older layout on the key. Local ones keep
working exactly as before, marked *v1* in the list; nothing about them can be moved to the
new layout, because their secrets never leave the credential. Portable ones show grey,
marked *needs migration*: they still export their backup key, but generating and encrypting
wait for the migration. It recreates the account in the current layout with the same master
key — so the same passwords — verifies the new record by reading it back from the key, and
only then deletes the old one. Four touches. If the same account was already migrated on
another key, enter the identity that key shows so that both agree about what is the same
account; if a migration is interrupted, the account offers to finish or discard the copy it
left.

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

MIT. Embedded `libfido2` remains under the BSD-2-Clause license; the vendored Argon2 reference
implementation (`Sources/CArgon2`) is CC0-1.0 / Apache-2.0.
