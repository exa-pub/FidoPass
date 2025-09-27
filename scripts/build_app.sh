#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
cd "${PROJECT_ROOT}"

PRODUCT=FidoPassApp
BUNDLE_ID=com.example.FidoPass
BUILD_DIR=".build/release"
APP_DIR="${BUILD_DIR}/FidoPass.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"
FRAMEWORKS_DIR="${CONTENTS}/Frameworks"

swift build -c release

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}" "${FRAMEWORKS_DIR}"
cp "${BUILD_DIR}/${PRODUCT}" "${MACOS_DIR}/${PRODUCT}"

# Copy icon (expects it already generated)
cp Sources/FidoPassApp/Resources/AppIcon.icns "${RES_DIR}/AppIcon.icns"

# Bundle Homebrew dynamic libraries so the app runs without prerequisites.
bundle_dependency() {
  local dylib_path="$1"
  if [[ -z "$dylib_path" ]]; then return; fi

  local name="$(basename "$dylib_path")"
  local target="${FRAMEWORKS_DIR}/${name}"

  if [[ ! -f "$dylib_path" ]]; then
    echo "[warn] dependency not found: $dylib_path" >&2
    return
  fi

  cp "$dylib_path" "$target"
  chmod 755 "$target"
  install_name_tool -id "@rpath/${name}" "$target"

  if otool -L "${MACOS_DIR}/${PRODUCT}" | tail -n +2 | awk '{print $1}' | grep -Fxq "$dylib_path"; then
    install_name_tool -change "$dylib_path" "@rpath/${name}" "${MACOS_DIR}/${PRODUCT}"
  fi

  # Re-point secondary dependencies inside the dylib itself.
  while IFS= read -r dep; do
    [[ "$dep" == "$dylib_path" ]] && continue
    [[ "$dep" == /opt/homebrew/* ]] || continue
    local dep_name="$(basename "$dep")"
    install_name_tool -change "$dep" "@rpath/${dep_name}" "$target"
  done < <(otool -L "$target" | tail -n +2 | awk '{print $1}')
}

# Ensure the executable looks inside the bundled Frameworks directory.
install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${PRODUCT}" 2>/dev/null || true

deps=(
  "$(brew --prefix libfido2 2>/dev/null)/lib/libfido2.1.dylib"
  "$(brew --prefix libcbor 2>/dev/null)/lib/libcbor.0.13.dylib"
  "$(brew --prefix openssl@3 2>/dev/null)/lib/libcrypto.3.dylib"
)

# Write Info.plist
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FidoPass</string>
  <key>CFBundleDisplayName</key><string>FidoPass</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${PRODUCT}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

for dep in "${deps[@]}"; do
  # shellcheck disable=SC2086
  bundle_dependency "$dep"
done

# Re-sign the app bundle after mutating embedded dylibs (ad-hoc signature).
if command -v codesign >/dev/null 2>&1; then
  if [[ -d "$FRAMEWORKS_DIR" ]]; then
    while IFS= read -r -d '' dylib; do
      codesign --force --sign - --timestamp=none "$dylib"
    done < <(find "$FRAMEWORKS_DIR" -type f -name '*.dylib' -print0)
  fi
  codesign --force --deep --sign - --timestamp=none "$APP_DIR"
else
  echo "[warn] codesign tool not available; bundle will remain unsigned" >&2
fi

echo "Created ${APP_DIR}"
