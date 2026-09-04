#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
cd "${PROJECT_ROOT}"

PRODUCT=FidoPassApp
# Derive bundle version from the latest tag.
RAW_VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)"
SHORT_VERSION="${RAW_VERSION#v}"
BUILD_VERSION="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
# Keep the bundle deployment target aligned with Package.swift.
MIN_MACOS="$(sed -n 's/.*\.macOS(\.v\([0-9][0-9]*\)).*/\1/p' Package.swift | head -1)"
MIN_MACOS="${MIN_MACOS:-13}.0"
BUNDLE_ID="${FIDOPASS_BUNDLE_ID:-pub.exa.FidoPass}"
BUILD_DIR=".build/release"
APP_DIR="${BUILD_DIR}/FidoPass.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"
FRAMEWORKS_DIR="${CONTENTS}/Frameworks"

bash scripts/build_dependencies.sh
DEPS_PREFIX="$PROJECT_ROOT/.build/native-dependencies/$(uname -m)/prefix"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig"
swift build -c release "$@"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}" "${FRAMEWORKS_DIR}"
cp "${BUILD_DIR}/${PRODUCT}" "${MACOS_DIR}/${PRODUCT}"

# Copy icon (expects it already generated)
cp Sources/FidoPassApp/Resources/AppIcon.icns "${RES_DIR}/AppIcon.icns"

# Bundle the transitive closure of non-system dylibs. Missing dependencies are fatal.

# Prefixes whose libraries have to travel with the app. Everything under /usr/lib and
# /System belongs to macOS and must be left alone.
is_bundleable() {
  case "$1" in
    /usr/lib/*|/System/Library/*|@*) return 1 ;;
    /*) return 0 ;;
    *) return 1 ;;
  esac
}

# Non-system libraries a Mach-O file links against.
direct_dependencies() {
  otool -L "$1" | tail -n +2 | awk '{print $1}'
}

bundle_dependency() {
  local dylib_path="$1"
  local name target
  name="$(basename "$dylib_path")"
  target="${FRAMEWORKS_DIR}/${name}"

  [[ -f "$target" ]] && return 0   # already bundled

  if [[ ! -f "$dylib_path" ]]; then
    echo "[error] required library not found: $dylib_path" >&2
    exit 1
  fi

  cp "$dylib_path" "$target"
  chmod 755 "$target"
  install_name_tool -id "@rpath/${name}" "$target"

  # Follow this library's own dependencies, then repoint them at the bundle.
  local dep dep_name
  while IFS= read -r dep; do
    is_bundleable "$dep" || continue
    [[ "$dep" == "$dylib_path" ]] && continue
    bundle_dependency "$dep"
    dep_name="$(basename "$dep")"
    install_name_tool -change "$dep" "@rpath/${dep_name}" "$target"
  done < <(direct_dependencies "$target")
}

# Ensure the executable looks inside the bundled Frameworks directory.
install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${PRODUCT}" 2>/dev/null || true

# Start from the executable and pull in the transitive closure.
while IFS= read -r dep; do
  is_bundleable "$dep" || continue
  bundle_dependency "$dep"
  install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "${MACOS_DIR}/${PRODUCT}"
done < <(direct_dependencies "${MACOS_DIR}/${PRODUCT}")

# Write Info.plist
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FidoPass</string>
  <key>CFBundleDisplayName</key><string>FidoPass</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>CFBundleExecutable</key><string>${PRODUCT}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- FidoPass lives in the menu bar: no Dock icon, no window at launch. The "Show in
       Dock" preference flips the activation policy at runtime when a user wants one. -->
  <key>LSUIElement</key><true/>
  <!-- fidopass:// links — an encryption key or a sealed message — open in the app. The
       handler only fills a window with the link; it never touches the security key. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>${BUNDLE_ID}.link</string>
      <key>CFBundleURLSchemes</key><array><string>fidopass</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Sign after install_name_tool changes: dylibs first, hashes next, outer bundle last.
# Local builds use ad-hoc signing; distribution requires Developer ID and hardened runtime.
SIGN_IDENTITY="${FIDOPASS_SIGN_IDENTITY:-}"
if [[ -n "$SIGN_IDENTITY" ]]; then
  CODESIGN_FLAGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
  SIGNING_MODE="Developer ID — ${SIGN_IDENTITY}"
else
  CODESIGN_FLAGS=(--force --timestamp=none --sign -)
  SIGNING_MODE="ad-hoc (set FIDOPASS_SIGN_IDENTITY for a distributable signature)"
fi

if command -v codesign >/dev/null 2>&1; then
  echo "Signing: ${SIGNING_MODE}"
  if [[ -d "$FRAMEWORKS_DIR" ]]; then
    while IFS= read -r -d '' dylib; do
      codesign "${CODESIGN_FLAGS[@]}" "$dylib"
    done < <(find "$FRAMEWORKS_DIR" -type f -name '*.dylib' -print0)
  fi
  # Record source versions and hashes after signing the embedded libraries.
  MANIFEST="${RES_DIR}/DEPENDENCIES.txt"
  {
    echo "FidoPass ${SHORT_VERSION} (build ${BUILD_VERSION})"
    echo "Built: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "macOS SDK: $(xcrun --show-sdk-version 2>/dev/null || echo unknown)"
    echo "Swift: $(swift --version 2>/dev/null | head -1)"
    echo
    echo "Embedded libraries:"
    for lib in "${FRAMEWORKS_DIR}"/*.dylib; do
      [ -e "$lib" ] || continue
      printf '  %-24s %s\n' "$(basename "$lib")" "$(shasum -a 256 "$lib" | awk '{print $1}')"
    done
    echo
    echo "Vendored sources:"
    echo "  argon2 reference implementation, P-H-C/phc-winner-argon2 @ f57e61e (Sources/CArgon2)"
    echo
    echo "Pinned sources (built for macOS ${MIN_MACOS}):"
    echo "  libfido2 1.16.0; libcbor 0.13.0; OpenSSL 3.5.8"
    echo "  SHA-256 source pins: scripts/build_dependencies.sh"
  } > "$MANIFEST"
  cp -R "$DEPS_PREFIX/licenses" "$RES_DIR/DependencyLicenses"

  # Nested libraries are already signed; sign the outer bundle last.
  codesign "${CODESIGN_FLAGS[@]}" "$APP_DIR"
else
  echo "[warn] codesign tool not available; bundle will remain unsigned" >&2
fi

# Developer ID builds also require the hardened runtime.
if [[ -n "$SIGN_IDENTITY" ]]; then
  # Capture output to avoid grep -q causing SIGPIPE under pipefail.
  signature_info="$(codesign --display --verbose=2 "$APP_DIR" 2>&1)"
  if [[ "$signature_info" != *"(runtime)"* ]]; then
    echo "[error] signed with an identity but the hardened runtime is not enabled" >&2
    exit 1
  fi
  echo "Hardened runtime: enabled"
fi

python3 scripts/verify_bundle.py "$APP_DIR"

echo "Bundled libraries:"
ls -1 "${FRAMEWORKS_DIR}"
echo "Created ${APP_DIR}"
