# Releasing FidoPass

A release is a git tag. CI builds, signs, notarises and publishes it; installed copies find
it through Sparkle. This is the whole procedure, the one-time setup behind it, and what to
do when something goes wrong.

## Versions

`scripts/version.sh` is the only source of a version. It reads `git describe` and prints:

| Checkout | `CFBundleShortVersionString` | `CFBundleVersion` | Updates itself |
| --- | --- | --- | --- |
| tag `v0.18.0`, clean tree | `0.18.0` | `0.18.0` | yes |
| tag `v0.18.0-beta.2`, clean tree | `0.18.0-beta.2` | `0.18.0b2` | yes, `beta` channel |
| 8 commits after `v0.17.0` | `0.17.0-dev.8` | `0.17.0.8` | never |
| the same with local changes | `0.17.0-dev.8.dirty` | `0.17.0.8` | never |

`CFBundleVersion` is what Sparkle compares, with its own comparator. That comparator ignores
a semver `-suffix` entirely — `0.18.0-beta.1` and `0.18.0` are the same version to it — but
orders `0.18.0a1 < 0.18.0b1 < 0.18.0rc1 < 0.18.0`, which is why a prerelease tag is spelt
that way in the bundle. `Tests/FidoPassUpdaterTests/VersionComparatorTests.swift` pins the
scheme against the real comparator; `scripts/test_version.py` pins the script.

Tags are `vMAJOR.MINOR.PATCH`, optionally `-alpha.N`, `-beta.N` or `-rc.N`. MINOR for a new
capability or a changed format, PATCH for fixes. The app's version has nothing to do with
the data-format versions in `docs/crypto.md`.

A commit may carry several version tags: the release is normally cut from the very commit
the last beta was tested on. The highest tag counts — a release above any prerelease of
the same version, rc above beta above alpha — so that commit builds as the release.

Never move or reuse a tag that has a release, and never replace a published asset:
installed copies compare against what they already downloaded. A tag whose build failed
before the release job published anything can be deleted and recreated; nothing has seen it.

Every bundle also records `FidoPassGitCommit`; About shows the version, Preferences shows it
with the commit for development builds.

## Cutting a release

1. Everything is on `main` and the last run of `main` is green.
2. Tag the commit and push the tag:

   ```sh
   git tag -a v0.18.0 -m "FidoPass 0.18.0"
   git push origin v0.18.0
   ```

3. CI runs the usual build and tests, then, for a tag only: checks that the tag names
   this commit cleanly and is on `main`, signs with Developer ID, notarises and staples,
   and builds `FidoPass-0.18.0.dmg` and `FidoPass-0.18.0.zip`.
4. The `release` job waits for approval in the `release` environment, then verifies the
   tickets again, writes GitHub's release notes, signs the zip with the Sparkle key,
   verifies that signature against the public key in `scripts/release.env`, publishes the
   release with the DMG, the zip, `SHA256SUMS` and `appcast.xml`, and finally downloads
   what installed apps will fetch to confirm the feed serves this release.
5. Check the release page, then an installed copy: Preferences → Updates → Check now.

A prerelease tag (`v0.18.0-beta.1`) goes through the same steps, is marked a prerelease,
does not become `latest`, and puts its appcast item on the `beta` channel. Released builds
never see it.

Releases are created only by CI. A release made by hand on GitHub becomes `latest` without
an appcast, and every installed copy starts reporting that the feed is broken.

## How installed copies update

The app checks `https://github.com/exa-pub/FidoPass/releases/latest/download/appcast.xml`
once a day, or when asked. Nothing about the user is sent; GitHub sees an IP address and a
User-Agent naming the app version. A found update shows as a dot next to the menu-bar icon
and a first item in its menu; there are no windows. The click downloads the zip, Sparkle
verifies its EdDSA signature against `SUPublicEDKey` and its Apple signature against the
running app's Team ID, installs, and relaunches. Preferences → Updates shows state,
progress and errors, and holds the two switches.

Only Developer ID builds carry `SUFeedURL`. A local or ad-hoc build embeds Sparkle but never
starts it: it could not install a Developer ID release anyway (the Team IDs differ), and it
should not offer to.

## One-time setup

### The Sparkle key

Made once, on the maintainer's Mac, never in CI, and without any keychain:

```sh
swift scripts/sparkle_keygen.swift ~/Desktop/sparkle-private.key
```

The script writes the private key — the base64 of a 32-byte Ed25519 seed, the file format
Sparkle's tools read — and prints the matching `SPARKLE_PUBLIC_KEY` line. (Sparkle's own
`generate_keys` from `bash scripts/fetch_sparkle_tools.sh` does the same through the login
keychain and exports the same format with `-x`; either works.)

- The printed public key goes into `scripts/release.env` as `SPARKLE_PUBLIC_KEY` and is
  committed. `verify_bundle.py` checks every bundle against it.
- The contents of `sparkle-private.key` become the secret `SPARKLE_PRIVATE_KEY` in the
  GitHub environment `release` (Settings → Environments → release → Environment secrets).
  Add a required reviewer to the environment: that is the human gate before a release.
- Back the file up offline, with the Developer ID certificate, then delete it from disk.
  Nothing in the repository ever needs it again; CI reads the secret through a pipe.

To convince yourself the pair works before trusting it with a release:

```sh
bin="$(bash scripts/fetch_sparkle_tools.sh)"
sig="$("$bin/sign_update" --ed-key-file ~/Desktop/sparkle-private.key -p some-file)"
swift scripts/ed25519_verify.swift "<SPARKLE_PUBLIC_KEY>" "$sig" some-file && echo valid
```

Losing the private key means no installed copy can ever update again without a manual
reinstall. Rotating it is possible only through an intermediate release signed with the old
key that carries the new public key — see Sparkle's documentation before attempting it.

### The team

`FIDOPASS_TEAM_ID` in `scripts/release.env` is the Apple team of the Developer ID
certificate. CI refuses a certificate from another team, and `build_app.sh` refuses an
identity that names another one: Sparkle would reject the resulting update on every Mac.

### The environment

The `release` environment holds `SPARKLE_PRIVATE_KEY`. The signing and notarisation secrets
(`MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`,
`NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY_P8`) stay repository secrets, used by the
build job.

## Proving the update path

Before the first stable release that carries the updater, and after any change to signing,
packaging or the release job:

1. Tag `v0.18.0-beta.1` and approve the release. Install it from its DMG into
   `/Applications`. Preferences → Updates says "Up to date".
2. Make a trivial change, tag `v0.18.0-beta.2`, approve.
3. On the installed beta.1, point it at the beta.2 feed and channel — developer overrides,
   read from the app's defaults; signatures are verified exactly as before:

   ```sh
   defaults write pub.exa.FidoPass updates.feedOverride "https://github.com/exa-pub/FidoPass/releases/download/v0.18.0-beta.2/appcast.xml"
   defaults write pub.exa.FidoPass updates.channel beta
   ```

   Relaunch, Check now. The dot appears, the menu offers "Update to 0.18.0-beta.2…",
   the click shows progress in Preferences, the app relaunches, About says beta.2, the dot
   is gone, Launch at login is still on, the shortcut works. No window opened at any point.
   Click "Update…" while a touch is pending: the relaunch waits for it.
4. `defaults delete pub.exa.FidoPass SULastCheckTime`, relaunch, work in another app: the
   dot appears without stealing focus.
5. Run the app from the DMG: Preferences explains why it cannot update. Disconnect the
   network, Check now: an error sentence, no dialog.
6. Remove the overrides and tag the stable release:

   ```sh
   defaults delete pub.exa.FidoPass updates.feedOverride
   defaults delete pub.exa.FidoPass updates.channel
   ```

## When something goes wrong

- **The feed check step fails after publishing.** The release exists but `latest` does not
  serve its appcast. Open the release, make sure `appcast.xml` is attached and the release
  is not a draft; re-run the job if an upload failed. Until then installed copies report an
  error on check and nothing else.
- **A bad release.** Delete it (or mark it a prerelease); `latest` moves back to the previous
  one. Copies that already installed it are not rolled back — ship a fix as the next
  version. `<sparkle:criticalUpdate>` exists for a fix that must not be skipped; the
  headless driver does not treat it differently yet.
- **"The update is improperly signed" on users' Macs.** The signing key in CI is not the
  public key in the app. `verify_appcast.py` is meant to catch this before publishing; if
  it did not, the app's `SUPublicEDKey` and the secret have diverged since — compare with
  `generate_keys -p`.
- **A tag build fails in `build_app.sh` with an empty `SPARKLE_PUBLIC_KEY`.** The one-time
  setup above has not happened. A Developer ID build without a key is refused on purpose.
- **`verify_appcast.py` says the enclosure carries no `sparkle:edSignature`.**
  `generate_appcast` signs only a bundle that declares `SUPublicEDKey`; the archive it was
  given came from a build without one. The key belongs in `scripts/release.env` before the
  tag is pushed, not after.
- **Changing the Developer ID certificate.** Same team: nothing to do. Another team: every
  installed copy will refuse the next update; plan an intermediate release and read
  Sparkle's guidance first.
