#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
cd "${PROJECT_ROOT}"

PRODUCT=FidoPassApp
# Version strings come from the git tag when there is one, so released bundles can be
# identified. Without them the app reports no version at all.
RAW_VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)"
SHORT_VERSION="${RAW_VERSION#v}"
BUILD_VERSION="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
# Read the deployment target from the single place that defines it. Hardcoding it here too
# let the two drift: the plist still claimed 12.0 after the package moved to 13.
MIN_MACOS="$(sed -n 's/.*\.macOS(\.v\([0-9][0-9]*\)).*/\1/p' Package.swift | head -1)"
MIN_MACOS="${MIN_MACOS:-13}.0"
BUNDLE_ID="${FIDOPASS_BUNDLE_ID:-pub.exa.FidoPass}"
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

# Bundle the dynamic libraries the app needs so it runs without Homebrew installed.
#
# The set is discovered from the binaries themselves rather than listed by hand. A
# hardcoded list carried the soname in it — `libcbor.0.13.dylib` — so the day Homebrew
# moved to 0.14 the file simply was not there, the copy was skipped with a warning, and a
# bundle missing libcbor shipped and crashed on launch with
# "Library not loaded: @rpath/libcbor.0.14.dylib".
#
# Anything that cannot be bundled is now fatal: a broken bundle must never reach a release.

# Prefixes whose libraries have to travel with the app. Everything under /usr/lib and
# /System belongs to macOS and must be left alone.
is_bundleable() {
  case "$1" in
    /opt/homebrew/*|/usr/local/*) return 0 ;;
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

# Nothing inside the bundle may still point outside it. This is the check that would have
# caught the missing libcbor before it reached a release.
leftovers=0
while IFS= read -r -d '' macho; do
  while IFS= read -r dep; do
    if is_bundleable "$dep"; then
      echo "[error] $(basename "$macho") still references $dep" >&2
      leftovers=1
    fi
  done < <(direct_dependencies "$macho")
done < <(find "${MACOS_DIR}" "${FRAMEWORKS_DIR}" -type f -print0)
if [[ "$leftovers" -ne 0 ]]; then
  echo "[error] the bundle is not self-contained" >&2
  exit 1
fi

# Record exactly which libraries this build embedded.
#
# The versions come from whatever Homebrew had on the build machine, so without this a
# released bundle cannot answer "which OpenSSL is inside 0.12.0?" — the answer changes
# between builds of the same commit.
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
  echo "Homebrew formula versions at build time:"
  for formula in libfido2 libcbor openssl@3; do
    printf '  %-12s %s\n' "$formula" "$(brew list --versions "$formula" 2>/dev/null | tr ' ' '\n' | tail -n +2 | tr '\n' ' ' || echo unknown)"
  done
} > "$MANIFEST"

# Re-sign the app bundle after mutating embedded dylibs.
#
# This has to be the last thing that touches these binaries: install_name_tool rewrites the
# load commands above and invalidates any signature made before it. Signing also runs
# inside-out — every embedded dylib first, the bundle last.
#
# Two modes. Without FIDOPASS_SIGN_IDENTITY the signature is ad-hoc, which is all a local
# build needs and all a machine without a certificate can do. With it the bundle is signed
# for distribution: Developer ID, the hardened runtime and a trusted timestamp — the three
# things Apple requires before it will even accept a notarisation submission.
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
  # Deliberately no --deep: Apple does not recommend it for signing, and everything nested
  # was just signed explicitly by the loop above.
  codesign "${CODESIGN_FLAGS[@]}" "$APP_DIR"
else
  echo "[warn] codesign tool not available; bundle will remain unsigned" >&2
fi

echo "Verifying the signature…"
# The bundle's binaries are rewritten by install_name_tool and re-signed afterwards. That is
# exactly the step where a bundle ends up passing every path check while carrying a broken
# signature — and the failure would only appear on a user's machine, or during notarisation.
if ! codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | tail -3; then
  echo "[error] the signed bundle does not verify" >&2
  exit 1
fi

# Assert the hardened runtime here rather than discovering it is missing minutes later,
# when Apple rejects the submission for it.
if [[ -n "$SIGN_IDENTITY" ]]; then
  # Captured rather than piped into grep: under `set -o pipefail`, `grep -q` exits on the
  # first match and hands codesign a SIGPIPE, so the pipeline fails precisely when the flag
  # is present.
  signature_info="$(codesign --display --verbose=2 "$APP_DIR" 2>&1)"
  if [[ "$signature_info" != *"(runtime)"* ]]; then
    echo "[error] signed with an identity but the hardened runtime is not enabled" >&2
    exit 1
  fi
  echo "Hardened runtime: enabled"
fi

echo "Bundled libraries:"
ls -1 "${FRAMEWORKS_DIR}"
echo "Created ${APP_DIR}"
