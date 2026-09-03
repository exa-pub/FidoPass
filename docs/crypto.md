# FidoPass cryptography

Normative definition of every value FidoPass derives, stores and shows. 2026-09-04.

## §0 Status of this document

This document defines bytes. Every statement in it is normative unless marked `Note`. An
implementation that reproduces every vector in Appendix A conforms to this document; an
implementation that differs from it in a single byte does not.

What has shipped does not change. A value marked `Status: frozen` already exists in the
world: passwords people open their vaults with, links in other people's conversations,
records on other people's keys. Such a value cannot be changed; a new one can be introduced
under a new identifier and described in a new section. Where an implementation and this
document disagree about a frozen value, the document is wrong, because the fact has already
happened. Where they disagree about a value that is not frozen, the implementation is wrong.

Section numbers are stable. New material is added as a new subsection or appendix; existing
numbers do not move, so that a reference to "§5.3" means the same thing forever.

## §1 Conventions

Notation:

| Written | Meaning |
|---|---|
| `a ‖ b` | concatenation of bytes |
| `"text"` | the ASCII bytes, without a terminator |
| `utf8(s)` | the string `s` in UTF-8, without a terminator |
| `be32(n)` | `n` as 4 bytes, most significant first |
| `x[a..b)` | the bytes of `x` from index `a` up to but not including `b` |
| `hex` | hexadecimal, lower case |
| `b64(x)` | base64, RFC 4648 §4, with `=` padding |
| `b64url(x)` | base64url, RFC 4648 §5, without padding |
| `SHA-256(x)` | FIPS 180-4 |
| `HMAC(k, m)` | HMAC-SHA-256, RFC 2104 |
| `HKDF(ikm, salt, info, L)` | RFC 5869 with SHA-256, `L` bytes of output |
| `argon2id(pwd, salt, L)` | RFC 9106, version 0x13, `t = 1`, `m = 32 MiB (2¹⁵ KiB)`, `p = 1`, `L` bytes of tag |
| `X25519(sk, u)` | RFC 7748 |
| `PRF(salt)` | the authenticator's `hmac-secret` answer under the salt `salt`, §2.2 |
| `⊕` | XOR, byte by byte, over operands of equal length |

All lengths are in bytes unless stated otherwise. Every derived value has a fixed length,
except the password, whose length the policy sets, and the text of a message, plain and
sealed.

Every versioned section carries a status line. `Frozen`: shipped, never changes. `Current`:
written today, read forever. `Read-only`: read, no longer written.

## §2 The authenticator

### §2.1 The credential

A FidoPass account is one FIDO2 discoverable credential on the authenticator. It is created
with these parameters:

| Parameter | Value |
|---|---|
| algorithm | ES256 (COSE −7) |
| `rk` | true |
| `uv` | true |
| extensions | `hmac-secret`, `largeBlobKey`, `credProtect = 3` |

The credential's signature takes part in no derivation. The algorithm is fixed because it
enters the credential. `credProtect = 3` means the credential answers nothing at all without
user verification. The `rp` and `user` fields are set by the layout, §4.

### §2.2 PRF

`PRF(salt)` is the credential's answer to one assertion with the `hmac-secret` extension,
one salt of 32 bytes, `up = true`, `uv = true`. The answer is 32 bytes.

User verification is mandatory. An authenticator answering without it answers under a
different internal key, and the result is a different number rather than an error. The
assertion's `clientDataHash` is random and enters no output.

The credential's internal key (CredRandom) never leaves the authenticator. Everything the
host knows about a credential is the value of `PRF` under the salts of this document, and
there are exactly three families of them: the password salt (§5.1), the fixed salt (§4.4)
and the message salt (§6.1).

### §2.3 What the host reads back

Through credential management the host reads `rp.id`, `user.id`, `user.name`, the
credential id and the `largeBlobKey`. Under the `largeBlobKey` it reads the account's record
from the large-blob store (§4.1). None of these reads requires a `PRF`.

### §2.4 What the authenticator does not store

The label, the revision and the password policy (§5.5) are written nowhere on the
authenticator. The label is an input to derivation known only to the person: the password
under a forgotten label cannot be reproduced even with the authenticator in hand.

## §3 The PRF wrapping

Status: frozen.

```
wrap(x) = SHA-256("WebAuthn PRF" ‖ 0x00 ‖ x)
```

This is the transformation a WebAuthn client applies to the input of the `prf` extension
before handing it to the authenticator as the `hmac-secret` salt. Every salt of layout v2 is
`wrap` over an input from the table, so that a host talking to the authenticator directly
and a WebAuthn client talking through `prf` ask the credential the same question:

| Question | `x`, the input before wrapping |
|---|---|
| password, v2 local | `"fidopass\|pw\|v2\|" ‖ utf8(label) ‖ be32(revision)` |
| fixed component, v2 | `"fidopass\|fixed\|v2"` |
| message, both layouts | `"fidopass\|hpke\|secret\|v1\|" ‖ nonce` |

The salts of layout v1 (§4.4, §5.1) are not wrapped. They are computed as written and
wrapped in nothing.

Vector: `wrap("fidopass|fixed|v2") = 5d267585fe91a12df6e27959f2be9e38fc12c0f55b4077826211f36b161af4fd`.

## §4 Accounts on the authenticator

### §4.1 Layout v2

Status: current.

One relying party for accounts of both kinds. The account's kind and its key material live
in a record in the large-blob store, not in the credential's fields.

| Credential field | Value |
|---|---|
| `rp.id` | `fidopass.org` |
| `rp.name` | `FidoPass` |
| `user.id` | the identity, 16 bytes (§4.3) |
| `user.name` | `utf8(name)`, 1 to 64 bytes |
| `user.displayName` | `utf8(name)`, non-empty |

The account's record is the plaintext the host places in the large-blob store under this
credential's `largeBlobKey`:

```
byte 0        0x01                 record version
byte 1        0x00 local · 0x01 portable
bytes 2..34   mask, 32 bytes       portable only
```

A record is exactly 2 bytes for local and exactly 34 for portable. A credential whose record
has another length, another version, or no record at all is not an account: nothing is
derived from it.

Compressing the record and encrypting it under the `largeBlobKey` is done by the platform
per CTAP 2.1 §6.10 and is not part of this document. This document defines the plaintext.

### §4.2 Layout v1

Status: read-only.

The account's kind is the relying party. The name lives in `user.id`.

| Credential field | local | portable |
|---|---|---|
| `rp.id` | `fidopass.local` | `fidopass.portable` |
| `user.id` | `utf8(name)` | `utf8(name)` |
| `user.name` | the first 32 characters of `name` | `b64(mask)`, 44 characters |
| `user.displayName` | the display name given at creation, otherwise `name` | `name` |

The `user.name` of a v1 portable account is key material (§4.4), and the host neither shows
nor exports it as a name. Neither `user.name` nor `user.displayName` of layout v1 enters any
derivation; the name in `salt_v1` (§5.1) is taken from `user.id`.

### §4.3 The identity

The identity is 16 bytes that tell one account from another. It is not a secret and not an
input to any derivation: two accounts with different identities and everything else equal
derive the same passwords and the same message keys. Its only cryptographic role is the
locator (§6.3).

| Layout | Where from |
|---|---|
| v2, either kind | `user.id`, chosen at creation: random, or typed by the person |
| v1 local | `SHA-256(credential id)[0..16)` |
| v1 portable | none |

Text form: `hex` in eight groups of four characters separated by spaces. On reading, either
case is accepted, and the separators space, hyphen and colon; nothing else.

Vector: the credential id `utf8("cred")` gives the identity `55d91a3561684b32df5e58a0d91968b9`.

### §4.4 Kinds, the master key and the mask

A local account derives everything from the `PRF` of its credential. A portable account
derives everything from a master key, 32 random or imported bytes, which the authenticator
holds only in masked form:

```
fixed_v1 = PRF(SHA-256("fidopass|fixed-challenge|v1"))     layout v1
fixed_v2 = PRF(wrap("fidopass|fixed|v2"))                   layout v2
mask     = master ⊕ fixed
master   = mask ⊕ fixed
```

`fixed` is the credential's answer to the constant salt of its layout. `mask` lives in the
record (v2) or in `user.name` (v1). Without the credential that produced `fixed`, `mask`
reveals nothing about `master`.

Vectors: `SHA-256("fidopass|fixed-challenge|v1") = 2f39b89f942cdf6d13581e274aa97b9cc591a9b7df2346caea3160a6a56a910d`;
`wrap("fidopass|fixed|v2")`, see §3.

### §4.5 The backup

Status: current (64 characters), read-only (44 characters).

```
backup    = b64(master ‖ identity)      48 bytes, 64 characters
backup_44 = b64(master)                 32 bytes, 44 characters
```

On reading, whitespace is removed. Exactly these two decoded lengths are accepted; anything
else is not a backup. A backup without an identity is given one on import: random, or typed
by the person.

The backup is the only form in which the master key leaves the authenticator.

### §4.6 Copies and migration: invariants

A copy of a portable account on another authenticator or in another layout has the same
`master` and the same identity. Hence the copy has the same passwords (§5) and the same
message keys (§6). Its `fixed` and `mask` are its own, because `fixed` belongs to the
credential.

When an account is carried from layout v1 to v2, the original is deleted only after a
`master` equal to the original has been recovered from the copy. Until then the original is
the account and the copy is not.

A v1 local account is neither copied nor migrated: its secrets are the `PRF` of its
credential, and another credential answers with other numbers. It stays in layout v1 for
good.

On one authenticator the account name is unique across all three relying parties. The one
exception is the pair of a v1 portable account and its unfinished v2 copy.

## §5 Passwords: policy version 1

Status: frozen.

### §5.1 Salts

```
salt_v1(label, rp, name, revision) = SHA-256("fidopass|salt|" ‖ utf8(rp) ‖ "|" ‖ utf8(name) ‖ "|" ‖ utf8(label) ‖ "|" ‖ be32(revision))
salt_v2(label, revision)           = wrap("fidopass|pw|v2|" ‖ utf8(label) ‖ be32(revision))
salt_p(label)                      = SHA-256("fidopass|portable|" ‖ utf8(label))
```

`salt_v1` is the salt of a v1 local account; its `rp` is `fidopass.local`. `salt_v2` is the
salt of a v2 local account. `salt_p` is not sent to the authenticator: it is the HMAC
message under the master key, one for both layouts.

### §5.2 The secret

```
secret_local    = PRF(salt_v1 or salt_v2, by layout)
secret_portable = HMAC(master, salt_p(label))
```

Both are 32 bytes.

### §5.3 The material

```
material = HKDF(secret, salt = "pw-map", info = "fidopass|pw|v1", L = max(64, 3 · length))
```

`length` is the password length from the policy (§5.5).

### §5.4 Mapping to a password

Four character classes, each a string, in this order:

```
lower   = "abcdefghjkmnpqrstuvwxyz"      23 characters
upper   = "ABCDEFGHJKMNPQRSTUVWXYZ"      23 characters
digits  = "23456789"                      8 characters
symbols = "!#$%&*+-.:;<=>?@^_~"          19 characters
```

The characters `i l o I L O 0 1` appear in no class.

The alphabet `A` is the concatenation of the enabled classes in the order `lower ‖ upper ‖
digits ‖ symbols`. If no class is enabled, `A = lower ‖ upper ‖ digits`, and the top-up step
is not performed.

```
limit = 256 − (256 mod |A|)
out   = empty sequence
i     = 0
while |out| < length:
    b = material[i] if i < |material|, otherwise 0x00
    i = i + 1
    if b ≥ limit: continue
    append A[b mod |A|] to out
```

Top-up. Let `C₀, C₁, …` be the enabled classes in the order `lower, upper, digits, symbols`,
numbered from zero among the enabled ones. For each `Cⱼ` in increasing `j`:

```
if no character of out belongs to Cⱼ:
    pos      = material[j mod |material|] mod |out|
    out[pos] = Cⱼ[material[(j + 7) mod |material|] mod |Cⱼ|]
```

The password is `out` as a string.

Note. The top-up for class `j` may overwrite the character placed by the top-up for a class
`k < j`, so the presence of every enabled class is not guaranteed. About 3 % of passwords of
length 8 lack some class; at length 20 the share is negligible.

### §5.5 Parameters

| Parameter | Value |
|---|---|
| `length` | 8 to 128; a value outside the range is clamped to the nearest bound; 20 by default |
| classes | all four enabled by default |
| `version` | 1 |
| `revision` | 1 |

None of the parameters is stored on the authenticator. Every account today derives its
passwords with `revision = 1` and the default policy.

### §5.6 Properties

- The identity does not affect the password.
- The account name does not affect the password of a v2 local account or of any portable
  account. The password of a v1 local account is affected by all four components of
  `salt_v1`.
- The layout does not affect the password of a portable account: `secret_portable` depends
  on `master` and `label` only.
- Two labels differing in case give two passwords.

Note. In `salt_v1` the components are separated by `|` without lengths, and the pairs
`(name = "a|b", label = "c")` and `(name = "a", label = "b|c")` give one salt. This is a
property of the frozen format. It concerns two accounts of one owner on one authenticator
and does not weaken the password.

## §6 Encrypted messages: `hpkev1`, `hpkeblobv1`

Status: frozen.

A message key is an X25519 key pair derived from an account and a `nonce`, 32 random bytes.
The `nonce` is public and lives in the key link (§7.1). Nothing is stored: the recipient
derives the private key from the `nonce` anew every time.

### §6.1 The message secret

```
S(nonce)        = wrap("fidopass|hpke|secret|v1|" ‖ nonce)
secret_local    = PRF(S(nonce))
secret_portable = HMAC(master, S(nonce))
```

One salt for both layouts and both kinds. `secret` is 32 raw bytes, not a password, and no
value of §5 enters §6.

### §6.2 The key pair

```
ikm      = argon2id("fidopass|hpke|ikm|v1" ‖ secret, salt = nonce, L = 32)
(sk, pk) = DeriveKeyPair(ikm)
```

`DeriveKeyPair` is the function of DHKEM(X25519, HKDF-SHA256) from RFC 9180 §7.1.3, written
out in full:

```
suite_id = "KEM" ‖ 0x00 0x20
dkp_prk  = HMAC(key = 32 zero bytes, msg = "HPKE-v1" ‖ suite_id ‖ "dkp_prk" ‖ ikm)
sk       = HKDF-Expand(dkp_prk, info = 0x00 0x20 ‖ "HPKE-v1" ‖ suite_id ‖ "sk", L = 32)
pk       = X25519(sk, 9)
```

The first line is `HKDF-Extract` with an empty salt, which by RFC 5869 means HMAC under a
key of zeros of the hash length. The first two bytes of `info` are the length 32 as
`I2OSP(32, 2)`; their coincidence with the last bytes of `suite_id` is accidental. `sk` is
used as is: X25519 brings the scalar to canonical form itself, and `pk` is a function of
the bytes of `sk` without any further masking.

### §6.3 The locator

```
idfp = argon2id("fidopass|hpke|idfp|v1" ‖ identity, salt = nonce, L = 16)
```

The locator lets the recipient find the account by the `nonce` without naming it: the
recipient computes `idfp` for every identity on the authenticator and takes the one that
matches. An account without an identity (v1 portable) has no locator and issues no message
keys.

### §6.4 The fingerprint

```
keyfp = argon2id(utf8(payload), salt = "fidopass-keyfp-v1", L = 6)
```

`payload` is the text of the key link from `hpkev1?` up to but not including `&keyfp=`
(§7.1), without the carrier. The fingerprint is shown as six emoji by the alphabet of §7.3
and as 12 hex characters.

`keyfp` is a checksum, not a signature: whoever substitutes `pubkey` recomputes `keyfp` as
well. Comparing the emoji with the key's owner over another channel is the only defence
against a substituted link.

### §6.5 Sealing

HPKE, RFC 9180, base mode, suite `kem = 0x0020, kdf = 0x0001, aead = 0x0001`: DHKEM(X25519,
HKDF-SHA256), HKDF-SHA256, AES-128-GCM. This is the suite of RFC 9180 Appendix A.1.

```
info      = "fidopass|hpke|info|v1" ‖ nonce ‖ idfp                  21 + 32 + 16 bytes
enc, ctx  = SetupBaseS(pk, info)
ct        = ctx.Seal(aad = empty, pt = utf8(text))                 |pt| + 16 bytes
content   = enc ‖ ct                                                 32 + |pt| + 16 bytes
```

One context per message: a fresh ephemeral pair, one `Seal`, sequence number 0. `aad` is
empty: the binding of the message to its key is made through `info`, once. The plaintext is
UTF-8. The host refuses to seal a text longer than 65 536 characters; the format does not
limit the length.

### §6.6 Opening

```
ctx = SetupBaseR(enc, sk, info)
pt  = ctx.Open(aad = empty, ct)
```

`sk` is derived per §6.1–6.2 from the message's `nonce`. A message whose `nonce` or `idfp`
differs from the key's does not open by definition, before any AEAD check. An AEAD failure
does not distinguish a wrong key from damaged data.

### §6.7 Properties

- A portable account on two authenticators issues, under one `nonce`, the same `pk` and the
  same `idfp`, whatever the name and the layout. A key issued before a migration opens
  messages after it.
- A password and a message key cannot be computed from one another: different salts to
  `PRF`, different HMAC messages, different domains.
- Anyone holding a key link can seal; the recipient cannot establish who did.
- Every message under one key carries the same `nonce` and the same `idfp`: messages to one
  key are visibly addressed to one key. Different keys of one account are not linked.

## §7 Encodings: what a person sees and sends

### §7.1 Links

Status: frozen.

```
key-link     = carrier "hpkev1?nonce=" b64url(nonce) "&pubkey=" b64url(pk) "&idfp=" b64url(idfp) "&keyfp=" hex(keyfp)
message-link = carrier "hpkeblobv1?nonce=" b64url(nonce) "&idfp=" b64url(idfp) "&content=" b64url(content)
carrier      = "https://fidopass.org/link#" / "fidopass://"
```

Lengths: `nonce` and `pk` encode to 43 characters, `idfp` to 22, `keyfp` to 12; `content`
to 64 or more. A key link is 180 characters with the `https` carrier and 165 with the
`fidopass://` carrier; a message link is at least 187 and 172 respectively.

The carrier written is `https://fidopass.org/link#`. The whole payload sits in the fragment,
and the fragment never leaves the client: the server `fidopass.org` receives neither keys nor
messages. The `fidopass://` carrier is the form the operating system delivers to the
application.

Reading. Whitespace is removed everywhere before parsing. The carrier is compared without
regard to the case of ASCII letters. `keyfp` is read in either case. Everything else is
compared byte for byte with what this document would write: the order of the fields,
`b64url` without padding, the absence of any other character. A link that fails this
comparison is not a FidoPass link. A `#` inside the payload makes the link not a FidoPass
link.

Every proper prefix of a valid link is an unfinished link, not an error. A key link cut off
at `&keyfp=` is unfinished: the checksum is required, but its absence is indistinguishable
from a string not yet finished.

The identifiers `hpkev<n>` and `hpkeblobv<n>` for any `n` are reserved: a link with another
`n` is a link of an unsupported version, not a foreign one.

### §7.2 The identity and the fingerprint as text

Identity: see §4.3. Fingerprint: 12 hex characters in lower case and six emoji, one per
byte of `keyfp`, by the alphabet of §7.3.

### §7.3 The emoji alphabet

Status: frozen.

256 emoji, one per byte value, in the order of the `andrew-d/emoji256` table. The table is
given in `docs/emoji-alphabet.md` and pinned here:

```
SHA-256(utf8(the 256 scalars in byte order 0x00..0xff)) = 46d5672e8e5a6a2d54c7d5a720d36368b0b842ee8324631a37b83066a6303d92
```

The identity of a character is its code point. The variation selector `U+FE0F`, added at
rendering to the 44 entries without an emoji presentation of their own, is not in the hash
and not part of the format.

### §7.4 The backup as text

See §4.5.

## §8 Randomness

| Value | Length | When |
|---|---|---|
| `master` | 32 | creating a portable account without an import |
| identity | 16 | creating a v2 account, unless typed by the person |
| `nonce` | 32 | issuing a message key |
| `clientDataHash` | 32 | every assertion and every credential creation |
| the HPKE ephemeral pair | 32 | every sealing, inside `SetupBaseS` |

All are drawn from the system's cryptographic generator. Nothing else in this document is
random: equal inputs give equal outputs.

## §9 Properties and limits

Public: the identity, `nonce`, `pk`, `idfp`, `keyfp`, both links in full, `mask` by itself.
Secret: the PIN, the credential's internal key, `master`, `secret`, `ikm`, `sk`, the
passwords, the backup.

What a loss means:

| Lost | Local account | Portable account |
|---|---|---|
| the authenticator | every password and every message of the account is unrecoverable | nothing, given the backup |
| the backup | does not exist | every password of the account and every message ever sealed under any of its keys is computable without the authenticator |
| a label | the password under it cannot be reproduced | the same |
| a key link | nothing: the holder can only seal | the same |

Limits:

- `keyfp` is 48 bits. Finding a link with the same six emoji takes about 2⁴⁸ argon2id
  computations at 32 MiB each. A substitution that does not reproduce the emoji is caught
  only by comparing with the owner.
- Base mode does not authenticate the sender.
- A message opens for as long as the account exists: neither a key nor a message expires.
- Messages under one key are linked by their shared `nonce` and `idfp` (§6.7).
- The presence of every character class in a password is not guaranteed (§5.4).
- The separator `|` in `salt_v1` is not escaped (§5.6).
- A FIDO2 authenticator locks itself permanently after eight wrong PINs in a row. That is a
  property of the authenticator; every `PRF` in this document requires the correct PIN.

## §10 Version registry

| Identifier | Where | Status |
|---|---|---|
| `policy version 1`, `revision 1` | §5 | frozen |
| `fidopass.local`, `fidopass.portable` | §4.2 | read-only |
| `fidopass.org` | §4.1 | current |
| record `0x01` | §4.1 | current |
| backup, 64 characters | §4.5 | current |
| backup, 44 characters | §4.5 | read-only |
| `hpkev1`, `hpkeblobv1` | §6, §7.1 | frozen |
| `argon2id t=1, m=32 MiB, p=1` | §1, §6 | frozen |
| emoji alphabet `46d5672e…` | §7.3 | frozen |
| `"WebAuthn PRF" ‖ 0x00` | §3 | frozen |
| `"fidopass\|salt\|"`, `"fidopass\|fixed-challenge\|v1"`, `"fidopass\|portable\|"` | §4.4, §5.1 | frozen |
| `"fidopass\|pw\|v2\|"`, `"fidopass\|fixed\|v2"` | §3, §4.4, §5.1 | frozen |
| `"pw-map"`, `"fidopass\|pw\|v1"` | §5.3 | frozen |
| `"fidopass\|hpke\|secret\|v1\|"`, `"fidopass\|hpke\|ikm\|v1"`, `"fidopass\|hpke\|idfp\|v1"`, `"fidopass\|hpke\|info\|v1"` | §6 | frozen |
| `"fidopass-keyfp-v1"` | §6.4 | frozen |

New behaviour gets a new identifier. The old one is read forever.

## Appendix A. Vectors

Every vector is self-contained: all inputs are written as bytes. The named byte strings
below are used by several vectors.

### A.1 Named inputs

```
ANSWER   = 05101b26313c47525d68737e89949faab5c0cbd6e1ecf7020d18232e39444f5a
FIXED    = 01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3da
MASTER_A = f0efeeedecebeae9e8e7e6e5e4e3e2e1e0dfdedddcdbdad9d8d7d6d5d4d3d2d1
MASK_B   = c3c2c1c0bfbebdbcbbbab9b8b7b6b5b4b3b2b1b0afaeadacabaaa9a8a7a6a5a4
MASK_C   = 0714212e3b4855626f7c8996a3b0bdcad7e4f1fe0b1825323f4c596673808d9a
NONCE    = 030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dc
SK_D     = 0b10151a1f24292e33383d42474c51565b60656a6f74797e83888d92979ca1a6
ID_E     = 0102030405060708090a0b0c0d0e0f10
ID_F     = 00112233445566778899aabbccddeeff
```

`ANSWER` plays the role of `PRF` under any password salt and under the message salt;
`FIXED` the role of `PRF` under the fixed salt of either layout.

### A.2 The wrapping and the salts

```
wrap("fidopass|fixed|v2")                         = 5d267585fe91a12df6e27959f2be9e38fc12c0f55b4077826211f36b161af4fd
SHA-256("fidopass|fixed-challenge|v1")            = 2f39b89f942cdf6d13581e274aa97b9cc591a9b7df2346caea3160a6a56a910d
salt_v2("vault", 1)                               = 346ef5e42fd931efdcfedc85cdbd31b3d1b5289e337c17a2dc604f8954419a7f
S(NONCE)                                          = 7e7abd979da6b556e7187e5fef573407579a800aaf4268c39c25dd33cb3a6ae3
S(0x42 × 32)                                      = 86fd9f523121d9d4703554ed7a4c8421d777b29584009be85a187dd224b89589
```

`salt_v1(label, rp, name, revision)`:

```
("default",    "fidopass.local",    "acct",  1)   = 3e344e45ab2332b1b6ebed8c0dce9cf02c8fb24961307c9ec47ba1e1b8fc73f9
("default",    "fidopass.local",    "acct",  2)   = b2f4b8dc84a3bc709e296300dcd95b11864d6060a53bb28fd66997c73107ac90
("github.com", "fidopass.local",    "acct",  1)   = cecfd652320c0b1b95a80f35bdd0867cb8345202b88e52ceefb0ed833dfd6204
("github.com", "fidopass.local",    "other", 1)   = 3dca97025c5222982e07e1c497d8f013556eda2b3fc00c2ee2e1df962926b3f6
("",           "fidopass.local",    "acct",  1)   = 3c89ed8a73cfe4dd748a4c090d544a7f337d52c2723cd1e8ddd9c1c3dcc0f311
("vault",      "fidopass.local",    "acct",  7)   = 33daf100aa04f817f26f6d662b609cadf49d00fd5831c4702766c2f47d4311f7
```

`salt_p(label)`:

```
("")            = 09ec36cfdc49bd24f0feb77d7bbb8bf33e8bef1343ba6a80de04cd2a115cb658
("default")     = ff6ed56457877d04ca8186d7ce5b2ccb9b6c4c1c157e03560bd6955bee924758
("github.com")  = 7dc424d3765c57bb35efb7e6f59044f8811be0079f29d2c0459fb2e9f1ef19f2
("vault")       = 6137d1d0e1eb7be06ebaebd0f6dbe73c859024b3c258f9e1fc4e693790616073
```

### A.3 Mapping to a password

The input `material` is fed directly into §5.4, bypassing HKDF. `RAMP` is the 192 bytes
`00 01 02 … bf`; `FILL(b)` is 128 bytes of the value `b`. The policy is written as the
enabled classes and the length.

```
RAMP,     all/8         = aJ3;efgh
RAMP,     all/12        = aJ3;efghjkmn
RAMP,     all/20        = aJ3;efghjkmnpqrstuvw
RAMP,     all/32        = ab3;efghjkmnpqrstuvwxyzABCDEFGHJ
RAMP,     lower/16      = abcdefghjkmnpqrs
RAMP,     upper/16      = ABCDEFGHJKMNPQRS
RAMP,     digits/16     = 2345678923456789
RAMP,     symbols/16    = !#$%&*+-.:;<=>?@
RAMP,     no symbols/20 = aJ3defghjkmnpqrstuvw
RAMP,     alnum/12      = aJ3defghjkmn
RAMP,     none/8        = abcdefgh
FILL(00), all/8         = !aaaaaaa
FILL(00), no symbols/20 = 2aaaaaaaaaaaaaaaaaaa
FILL(5a), all/8         = uu?uuuuu
FILL(5a), lower/16      = yyyyyyyyyyyyyyyy
FILL(ff), all/8         = aaaaaaa.
FILL(ff), all/32        = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.
```

`FILL(00), all/8` shows the top-up overwriting itself: three top-ups in a row land on
position 0, and only the last survives.

### A.4 Passwords

Local, `secret = ANSWER`, default policy, `revision = 1`:

```
material (L = 64)  = 3bb2ae8ae2a7b8dfee07115f85c38b15dbe0393bda706d20f992616e10d28a42b861dee199d54d11bc1b1a571f7f05c816d25a3ffd86dbeccc947fcdaf910359
all/20             = *KF<yShuz+5=y%*~TQKa
all/12             = *KF<yShuz+5=
alnum/16           = ftpHfzhuVCMJyd9e
```

Portable, `master = MASTER_A` (that is, `fixed = FIXED`, `mask = MASTER_A ⊕ FIXED`):

```
label "",           all/20    = &tSSV4*Sa5RrMs.Gp!k_
label "default",    all/20    = RHV-jJ>6gJQnuefr<kw4
label "github.com", all/20    = -Z=s7Ts-$+<;qhCbaxfH
label "",           all/12    = &tSSV4*Sa5Rr
label "default",    all/12    = RHV-jJ>6gJQn
label "github.com", all/12    = -Z=s7Ts-$+<;
label "",           alnum/16  = ePdzgKXSSMy8uNjG
label "default",    alnum/16  = R5gD26K6gsQnQef8
label "github.com", alnum/16  = Dm6NPT9ZygHGKDCT
```

Portable v2, `fixed = FIXED`, `mask = MASK_B`, label `vault`, default policy:

```
master          = c2caced6a29a968e82fafef6e2ead6dec2cace36223a360e021a1e16626a767e
secret_portable = 8a23937e812766a1aac10ea97f263076f8d3a5f55df2701eaae8798fb89126ae
password        = n+nQfBY!T_=Fh<m=S3#b
```

The same `master` in layout v1 gives the same password.

### A.5 Message keys

Local, `secret = ANSWER`, `nonce = NONCE`:

```
ikm = deb2fb37181668ac27b0c28886391181669f62dd00aecf22bb2b91a3ab28c03b
sk  = e8b8678e1d1c697cecbd5f5c2a2d40e5b3f7584514e867a14aaa925afde16063
pk  = 8c2338937e539280959bfaa628c3c0c97f0a9e8785a1da7605311eb063aa3a37
```

Portable, `fixed = FIXED`, `mask = MASK_C`, `nonce = NONCE`:

```
master = 061c2e38266c7e50563cced8f6ecdea0a69c8e78868cbe9096fceed8b64c5e40
pk     = 49e537c146b4262205e6506859aae25403bd33198a949a80a3ca52d7b0849a0a
```

Portable, `fixed = FIXED`, `mask = MASK_B`, `nonce = NONCE`:

```
master          = c2caced6a29a968e82fafef6e2ead6dec2cace36223a360e021a1e16626a767e
secret_portable = 24e7c24bb6060ee3719ec31e556263adeb82e7fc2185c096866d917aa7e858fd
pk              = f5bfd00d18b227928b82e0405e45e8dd16a51a795935fce03d962ad81831db77
```

Locators, `nonce = NONCE`:

```
idfp(ID_E) = 1597dcc1ca95f46445e632916017cfc9
idfp(ID_F) = 39d755fabbbb7d6ec99a54ff043bf9ab
```

`DeriveKeyPair` against RFC 9180 Appendix A.1: `ikmR =
6db9df30aa07dd42ee5e8181afdb977e538f5e1fec8a06223f33f7013e525037` gives `pkRm =
3948cfe0ad1ddb695d780e59077195da6c56506b027329794ab02bca80815c4d`, and the key opens the
A.1 ciphertext with that appendix's `info` and `aad`. Appendix A.2 of the RFC gives an
`skRm` with its top bit set; it is used unchanged.

### A.6 Links and a message

A key with `sk = SK_D`, `nonce = NONCE`, identity `ID_E`:

```
pk      = 446e5080171513a59ffbf40bd6a9dd388de4347afe92b00bde8d7beffec05e75
idfp    = 1597dcc1ca95f46445e632916017cfc9
payload = hpkev1?nonce=AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw&pubkey=RG5QgBcVE6Wf-_QL1qndOI3kNHr-krAL3o177_7AXnU&idfp=FZfcwcqV9GRF5jKRYBfPyQ
keyfp   = e8b701cbc159
emoji   = ⏸ 🔒 👎 🚽 👟 🧀
```

```
https://fidopass.org/link#hpkev1?nonce=AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw&pubkey=RG5QgBcVE6Wf-_QL1qndOI3kNHr-krAL3o177_7AXnU&idfp=FZfcwcqV9GRF5jKRYBfPyQ&keyfp=e8b701cbc159
fidopass://hpkev1?nonce=AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw&pubkey=RG5QgBcVE6Wf-_QL1qndOI3kNHr-krAL3o177_7AXnU&idfp=FZfcwcqV9GRF5jKRYBfPyQ&keyfp=e8b701cbc159
```

180 and 165 characters. A message under this key:

```
https://fidopass.org/link#hpkeblobv1?nonce=AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw&idfp=FZfcwcqV9GRF5jKRYBfPyQ&content=UYQyuFMtbgrHGFOfKywBJdW0z8Poem_7fLpZcrF_n1DqYOqz824Nv5Uj96quFjlFG3VolME-CFC1oSmUd3bODFIuEkauS815AMQgCEvaIbiNCKJR
```

opens with the key `SK_D` to the text `frozen on 2026-09-04 — do not thaw` (the dash is
U+2014). An empty text under any key gives a `content` of 48 bytes and a link of 187
characters with the `https` carrier, 172 with the `fidopass://` carrier.

### A.7 The emoji alphabet

`SHA-256` over the 256 scalars in UTF-8, in byte order, is
`46d5672e8e5a6a2d54c7d5a720d36368b0b842ee8324631a37b83066a6303d92`. The first eight:
👍 👎 👊 ✌ ✋ 👌 👏 👋. The last eight: 🎵 🎺 🎿 🏋 🏭 👅 👀 👯.

## Appendix B. Terms

| Term | Meaning |
|---|---|
| authenticator | the FIDO2 key that holds the credentials |
| host | the party asking the authenticator questions: the application, or a WebAuthn client |
| credential | a FIDO2 discoverable credential; one credential is one account |
| account, name | a FidoPass credential and its name |
| kind: local, portable | whose secrets the account has: this credential's alone, or the master key's |
| layout v1, v2 | how an account is laid out across the credential's fields and the record |
| identity | 16 bytes that tell an account apart; not a secret and not an input to derivation |
| record | the plaintext of the account's record in the large-blob store |
| fixed component, `fixed` | the credential's answer to the constant salt |
| master key, `master` | the 32 bytes of a portable account from which everything is derived |
| mask, `mask` | `master ⊕ fixed`, what lies on the authenticator |
| backup | `b64(master ‖ identity)`, what the person writes down |
| label, revision, policy | the inputs to password derivation not stored on the authenticator |
| PRF wrapping, `wrap` | the transformation of a `prf` extension input into an `hmac-secret` salt |
| message key | an X25519 key pair derived from an account and a `nonce` |
| `nonce` | 32 random bytes from which a message key is derived; public |
| locator, `idfp` | 16 bytes that find an account by the `nonce` without naming it |
| fingerprint, `keyfp` | 6 bytes over a key link's payload; six emoji, 12 hex characters |
| carrier, payload | a link's prefix, and what follows it |
| key link, message link | `hpkev1?…`, `hpkeblobv1?…` behind a carrier |
