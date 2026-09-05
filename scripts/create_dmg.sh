#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
cd "${PROJECT_ROOT}"

VOL_NAME="FidoPass"
BUILD_DIR=".build/release"
APP_DIR="${BUILD_DIR}/FidoPass.app"
STAGE_DIR=".build/dmg_stage"
SIGN_IDENTITY="${FIDOPASS_SIGN_IDENTITY:-}"

# Rebuild the app, unless the caller has already prepared the bundle it wants packaged.
#
# notarize.sh staples a notarisation ticket into the bundle and only then asks for a DMG
# around it. Rebuilding at that point would throw the ticket away silently, and the DMG
# would ship an app that has to reach Apple over the network on first launch.
if [[ "${FIDOPASS_SKIP_BUILD:-0}" == "1" ]]; then
  if [[ ! -d "${APP_DIR}" ]]; then
    echo "[error] FIDOPASS_SKIP_BUILD=1 but ${APP_DIR} does not exist" >&2
    exit 1
  fi
  echo "Packaging the existing bundle at ${APP_DIR}"
else
  "${SCRIPT_DIR}/build_app.sh" >/dev/null
fi

# The image is named after the bundle it carries, so two releases never share a file name
# and an appcast enclosure points at exactly one artefact.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP_DIR}/Contents/Info.plist")"
DMG_NAME="FidoPass-${VERSION}.dmg"

rm -f "${DMG_NAME}" || true
rm -rf "${STAGE_DIR}" || true
mkdir -p "${STAGE_DIR}"

# ditto, not cp -R: part of a signature lives in extended attributes, and cp is not obliged
# to carry those across. A bundle that loses them looks fine until codesign disagrees.
ditto "${APP_DIR}" "${STAGE_DIR}/FidoPass.app"
ln -s /Applications "${STAGE_DIR}/Applications"

# UDZO — compressed and read-only. A writable image is both larger and pointless for
# something that only ever gets dragged out of.
hdiutil create -ov -fs HFS+ -format UDZO -srcfolder "${STAGE_DIR}" -volname "${VOL_NAME}" "${DMG_NAME}"

# Sign the image itself when there is an identity. Gatekeeper checks the DMG's own
# signature before anything inside it is opened, and notarisation will not take an unsigned
# one. No --options runtime here: a disk image is data, not code.
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing ${DMG_NAME}: ${SIGN_IDENTITY}"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "${DMG_NAME}"
  codesign --verify --strict --verbose=2 "${DMG_NAME}"
fi

echo "Created ${DMG_NAME}"
