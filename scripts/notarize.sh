#!/usr/bin/env bash
set -euo pipefail

# Builds a signed FidoPass.dmg, has Apple notarise it, and staples the resulting tickets.
#
# Signing alone is not enough: since macOS 10.15 Gatekeeper blocks a Developer ID app that
# Apple has not seen, with a different message but the same result. Notarisation is what
# lifts that, and stapling is what makes the check work without a network round trip.
#
# Both the app and the disk image are submitted, in that order. A ticket stapled to the DMG
# covers the image only — the app copied out of it into /Applications carries none, so its
# first launch would have to ask Apple over the internet and would fail offline. One extra
# submission buys a bundle that verifies on its own.
#
# Prerequisites are the manual half of the job: a Developer ID certificate and notarisation
# credentials. See docs/release.md.
#
# Never add `set -x` here: credentials pass through this script.

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
cd "${PROJECT_ROOT}"

APP_DIR=".build/release/FidoPass.app"
ZIP_PATH=".build/release/FidoPass.zip"
SIGN_IDENTITY="${FIDOPASS_SIGN_IDENTITY:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  cat >&2 <<'MSG'
[error] FIDOPASS_SIGN_IDENTITY is not set.

  Pass the Developer ID identity to sign with, for example:

    export FIDOPASS_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"

  `security find-identity -v -p codesigning` lists what this machine has. A missing one
  is issued at developer.apple.com (Certificates → Developer ID Application) and imported
  into the login keychain; see docs/release.md.
MSG
  exit 1
fi

# Two ways to authenticate. A keychain profile is the local convenience; the explicit API
# key is what CI uses, where storing credentials in a keychain would be pointless.
if [[ -n "${FIDOPASS_NOTARY_KEY:-}" ]]; then
  : "${FIDOPASS_NOTARY_KEY_ID:?FIDOPASS_NOTARY_KEY is set but FIDOPASS_NOTARY_KEY_ID is not}"
  : "${FIDOPASS_NOTARY_ISSUER:?FIDOPASS_NOTARY_KEY is set but FIDOPASS_NOTARY_ISSUER is not}"
  NOTARY_ARGS=(--key "$FIDOPASS_NOTARY_KEY"
               --key-id "$FIDOPASS_NOTARY_KEY_ID"
               --issuer "$FIDOPASS_NOTARY_ISSUER")
  echo "Notarisation: App Store Connect API key ${FIDOPASS_NOTARY_KEY_ID}"
else
  NOTARY_PROFILE="${FIDOPASS_NOTARY_PROFILE:-fidopass}"
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<MSG
[error] no notarisation credentials for profile "${NOTARY_PROFILE}".

  Store them once with:

    xcrun notarytool store-credentials ${NOTARY_PROFILE} \\
      --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>

  The key file, its ID and the issuer come from App Store Connect → Users and Access →
  Integrations → App Store Connect API; the key must belong to the same team as the
  certificate. See docs/release.md.
MSG
    exit 1
  fi
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  echo "Notarisation: keychain profile ${NOTARY_PROFILE}"
fi

# Submit one artefact and wait. On anything other than Accepted, print Apple's own reasons
# before failing — the status alone ("Invalid") says nothing about what to fix.
submit() {
  local artefact="$1"
  local response status id

  echo "Submitting $(basename "$artefact") — Apple usually answers within a few minutes…"
  response="$(xcrun notarytool submit "$artefact" "${NOTARY_ARGS[@]}" --wait --output-format json 2>&1)" || true

  if [[ -z "$response" ]]; then
    echo "[error] notarytool returned nothing — check network and credentials" >&2
    exit 1
  fi

  id="$(printf '%s' "$response" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("id",""))
except Exception: print("")' 2>/dev/null || true)"
  status="$(printf '%s' "$response" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("status",""))
except Exception: print("")' 2>/dev/null || true)"

  if [[ -z "$status" ]]; then
    echo "[error] could not read a status out of notarytool:" >&2
    printf '%s\n' "$response" >&2
    exit 1
  fi

  echo "  submission ${id}: ${status}"
  if [[ "$status" != "Accepted" ]]; then
    echo "[error] notarisation was refused. Apple's reasons:" >&2
    xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" >&2 || true
    echo >&2
    echo "[hint] if the log mentions the team, check that the notarisation key and the" >&2
    echo "       signing certificate belong to the same Apple Developer team." >&2
    exit 1
  fi
}

if [[ "${FIDOPASS_SKIP_BUILD:-0}" == "1" ]]; then
  # CI has already built, signed and verified the bundle by this point; rebuilding it would
  # only throw away those checks and cost another few minutes.
  if [[ ! -d "$APP_DIR" ]]; then
    echo "[error] FIDOPASS_SKIP_BUILD=1 but ${APP_DIR} does not exist" >&2
    exit 1
  fi
  echo "==> Using the bundle already at ${APP_DIR}"
else
  echo "==> Building and signing the bundle"
  FIDOPASS_SIGN_IDENTITY="$SIGN_IDENTITY" bash "${SCRIPT_DIR}/build_app.sh"
fi

# create_dmg.sh names the image after the bundle; this must agree with it.
DMG_NAME="FidoPass-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist").dmg"

echo "==> Notarising the app"
rm -f "$ZIP_PATH"
# notarytool takes a zip, a DMG or a pkg — never a bare .app. ditto is what produces an
# archive Apple's service accepts.
ditto -c -k --keepParent --sequesterRsrc "$APP_DIR" "$ZIP_PATH"
submit "$ZIP_PATH"
xcrun stapler staple "$APP_DIR"
rm -f "$ZIP_PATH"

echo "==> Packaging the stapled bundle"
# Skip the rebuild: the bundle now carries a ticket that a rebuild would discard.
FIDOPASS_SKIP_BUILD=1 FIDOPASS_SIGN_IDENTITY="$SIGN_IDENTITY" bash "${SCRIPT_DIR}/create_dmg.sh"

echo "==> Notarising the disk image"
submit "$DMG_NAME"
xcrun stapler staple "$DMG_NAME"

echo "==> Verifying"
# What a user's Mac will check, checked here instead of on their machine.
xcrun stapler validate "$APP_DIR"
xcrun stapler validate "$DMG_NAME"
spctl --assess --type exec --verbose=2 "$APP_DIR"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_NAME"

echo
echo "${DMG_NAME} is signed, notarised and stapled."
