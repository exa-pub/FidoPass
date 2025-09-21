#!/usr/bin/env bash
set -euo pipefail

PRODUCT=FidoPassApp
VOL_NAME="FidoPass"
DMG_NAME="FidoPass.dmg"
BUNDLE_ID=com.example.FidoPass
BUILD_DIR=".build/release"
APP_DIR="${BUILD_DIR}/FidoPass.app"
STAGE_DIR=".build/dmg_stage"
MOUNT_DIR="/Volumes/${VOL_NAME}"

# Reuse build script to ensure fresh .app
./build_app.sh >/dev/null

rm -f "${DMG_NAME}" || true
rm -rf "${STAGE_DIR}" || true
mkdir -p "${STAGE_DIR}"

cp -R "${APP_DIR}" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"

# Optional: create background image (skip if custom later)
# sips -s format png icon.png --out "${STAGE_DIR}/.background.png" >/dev/null 2>&1 || true

# Calculate size (add margin) in MB
SIZE_MB=$(du -sm "${STAGE_DIR}" | awk '{print $1 + 20}')

hdiutil create -ov -fs HFS+ -srcfolder "${STAGE_DIR}" -volname "${VOL_NAME}" -size ${SIZE_MB}m "${DMG_NAME}.temp.dmg"

# (Optional layout customization using AppleScript / hdiutil attach + SetFile) skipped for brevity
mv "${DMG_NAME}.temp.dmg" "${DMG_NAME}"

echo "Created ${DMG_NAME}" 
