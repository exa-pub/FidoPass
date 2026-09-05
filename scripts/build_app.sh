#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
cd "${PROJECT_ROOT}"

VIRTUAL_KEYS=0
SWIFT_ARGS=()
for argument in "$@"; do
  case "$argument" in
    --virtual-keys) VIRTUAL_KEYS=1 ;;
    *) SWIFT_ARGS+=("$argument") ;;
  esac
done
if [[ "$VIRTUAL_KEYS" == 1 ]]; then
  export FIDOPASS_VIRTUAL_KEYS=1
else
  unset FIDOPASS_VIRTUAL_KEYS
fi

PRODUCT=FidoPassApp
# The version comes from the tag, through one script; see docs/release.md.
eval "$(bash scripts/version.sh)"
SHORT_VERSION="$FIDOPASS_VERSION"
BUILD_VERSION="$FIDOPASS_BUILD"
if [[ -n "${FIDOPASS_EXPECT_VERSION:-}" && "$SHORT_VERSION" != "$FIDOPASS_EXPECT_VERSION" ]]; then
  echo "[error] this checkout builds as ${SHORT_VERSION}, not ${FIDOPASS_EXPECT_VERSION}: the tag is on another commit, the tree is dirty, or tags were not fetched" >&2
  exit 1
fi
# Release constants: the Sparkle public key and feed, the team the certificate must belong to.
# shellcheck disable=SC1091
source scripts/release.env
# Local builds use ad-hoc signing; distribution requires Developer ID and hardened runtime.
SIGN_IDENTITY="${FIDOPASS_SIGN_IDENTITY:-}"
if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != *"(${FIDOPASS_TEAM_ID})"* ]]; then
  echo "[error] ${SIGN_IDENTITY} does not belong to team ${FIDOPASS_TEAM_ID} (scripts/release.env)" >&2
  exit 1
fi
if [[ -n "$SIGN_IDENTITY" && -z "$SPARKLE_PUBLIC_KEY" ]]; then
  echo "[error] SPARKLE_PUBLIC_KEY is empty in scripts/release.env: a Developer ID build would ship an updater that can never verify an update. See docs/release.md." >&2
  exit 1
fi
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
# --disable-keychain: every dependency is public; without it SwiftPM asks for the login
# keychain on machines that keep a github.com credential in it.
swift build --disable-keychain -c release --product "$PRODUCT" ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"}
SWIFT_BIN_DIR="$(swift build --disable-keychain -c release --show-bin-path ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"})"
if [[ "$VIRTUAL_KEYS" == 1 ]]; then
  MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" OPENSSL_DIR="$DEPS_PREFIX" bash scripts/build_test_authenticator.sh --release
fi

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}" "${FRAMEWORKS_DIR}"
cp "${SWIFT_BIN_DIR}/${PRODUCT}" "${MACOS_DIR}/${PRODUCT}"

if [[ "$VIRTUAL_KEYS" == 1 ]]; then
  mkdir -p "${CONTENTS}/Helpers"
  cp .build/test-authenticator/target/release/fidopass-test-authenticator "${CONTENTS}/Helpers/"
fi

# Copy icon (expects it already generated)
cp Sources/FidoPassApp/Resources/AppIcon.icns "${RES_DIR}/AppIcon.icns"

# Sparkle, the updater. SwiftPM puts the framework it linked against next to the binary;
# the bundle needs it under Frameworks, symlinks intact — hence ditto, not cp.
SPARKLE_FRAMEWORK="${FRAMEWORKS_DIR}/Sparkle.framework"
if [[ ! -d "${SWIFT_BIN_DIR}/Sparkle.framework" ]]; then
  echo "[error] Sparkle.framework is missing from ${SWIFT_BIN_DIR}; did swift build resolve the Sparkle package?" >&2
  exit 1
fi
ditto "${SWIFT_BIN_DIR}/Sparkle.framework" "${SPARKLE_FRAMEWORK}"
SPARKLE_BUNDLED="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${SPARKLE_FRAMEWORK}/Resources/Info.plist")"
if [[ "$SPARKLE_BUNDLED" != "$SPARKLE_VERSION" ]]; then
  echo "[error] the linked Sparkle is ${SPARKLE_BUNDLED}, scripts/release.env says ${SPARKLE_VERSION}; update both Package.swift and release.env together" >&2
  exit 1
fi

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

# Both executables resolve their bundled dependencies through the same Frameworks directory.
EXECUTABLES=("${MACOS_DIR}/${PRODUCT}")
if [[ "$VIRTUAL_KEYS" == 1 ]]; then
  EXECUTABLES+=("${CONTENTS}/Helpers/fidopass-test-authenticator")
fi
for binary in "${EXECUTABLES[@]}"; do
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null || true
  while IFS= read -r dep; do
    is_bundleable "$dep" || continue
    bundle_dependency "$dep"
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$binary"
  done < <(direct_dependencies "$binary")
done

# Sparkle keys. The public key is a constant of the repository; the feed URL goes only into
# Developer ID builds, so a local build never offers an update it could not install (Sparkle
# also requires the update's Apple signature to match the running app's). Automatic checks
# are declared on so that Sparkle never asks with a dialog of its own: the switch is in
# Preferences, and onboarding asks new users.
SPARKLE_PLIST="  <key>SUEnableAutomaticChecks</key><true/>"
if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
  SPARKLE_PLIST+=$'\n'"  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  SPARKLE_PLIST+=$'\n'"  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>"
fi

# Write Info.plist
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>FidoPassVirtualKeys</key><integer>${VIRTUAL_KEYS}</integer>
  <key>CFBundleName</key><string>FidoPass</string>
  <key>CFBundleDisplayName</key><string>FidoPass</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
  <key>FidoPassGitCommit</key><string>${FIDOPASS_COMMIT}</string>
${SPARKLE_PLIST}
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

# Sign after install_name_tool changes: Sparkle's helpers and dylibs first, hashes next,
# outer bundle last.
if [[ -n "$SIGN_IDENTITY" ]]; then
  CODESIGN_FLAGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
  SIGNING_MODE="Developer ID — ${SIGN_IDENTITY}"
else
  CODESIGN_FLAGS=(--force --timestamp=none --sign -)
  SIGNING_MODE="ad-hoc (set FIDOPASS_SIGN_IDENTITY for a distributable signature)"
fi

if command -v codesign >/dev/null 2>&1; then
  echo "Signing: ${SIGNING_MODE}"
  # Sparkle's helpers, inside out and one at a time — never --deep, which Sparkle's own
  # documentation warns against. The order is theirs: XPC services, Autoupdate, Updater.app,
  # then the framework. Downloader.xpc keeps whatever entitlements it shipped with.
  sparkle_versions="${SPARKLE_FRAMEWORK}/Versions/B"
  codesign "${CODESIGN_FLAGS[@]}" "${sparkle_versions}/XPCServices/Installer.xpc"
  codesign "${CODESIGN_FLAGS[@]}" --preserve-metadata=entitlements "${sparkle_versions}/XPCServices/Downloader.xpc"
  codesign "${CODESIGN_FLAGS[@]}" "${sparkle_versions}/Autoupdate"
  codesign "${CODESIGN_FLAGS[@]}" "${sparkle_versions}/Updater.app"
  codesign "${CODESIGN_FLAGS[@]}" "${SPARKLE_FRAMEWORK}"
  if [[ -d "$FRAMEWORKS_DIR" ]]; then
    while IFS= read -r -d '' dylib; do
      codesign "${CODESIGN_FLAGS[@]}" "$dylib"
    done < <(find "$FRAMEWORKS_DIR" -type f -name '*.dylib' -print0)
  fi
  if [[ "$VIRTUAL_KEYS" == 1 ]]; then
    codesign "${CODESIGN_FLAGS[@]}" "${CONTENTS}/Helpers/fidopass-test-authenticator"
  fi
  # Record source versions and hashes after signing the embedded libraries.
  MANIFEST="${RES_DIR}/DEPENDENCIES.txt"
  {
    echo "FidoPass ${SHORT_VERSION} (build ${BUILD_VERSION}, commit ${FIDOPASS_COMMIT})"
    echo "Built: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "macOS SDK: $(xcrun --show-sdk-version 2>/dev/null || echo unknown)"
    echo "Swift: $(swift --version 2>/dev/null | head -1)"
    echo "Sparkle: ${SPARKLE_VERSION}"
    echo
    echo "Embedded libraries:"
    for lib in "${FRAMEWORKS_DIR}"/*.dylib; do
      [ -e "$lib" ] || continue
      printf '  %-24s %s\n' "$(basename "$lib")" "$(shasum -a 256 "$lib" | awk '{print $1}')"
    done
    printf '  %-24s %s\n' "Sparkle.framework" "$(shasum -a 256 "${SPARKLE_FRAMEWORK}/Versions/B/Sparkle" | awk '{print $1}')"
    echo
    if [[ "$VIRTUAL_KEYS" == 1 ]]; then
      echo "OpenSK helper (Rust 1.94.1, e161e95944871ccf719945738a272e718076c1df):"
      printf '  fidopass-test-authenticator %s\n' "$(shasum -a 256 "${CONTENTS}/Helpers/fidopass-test-authenticator" | awk '{print $1}')"
      echo
    fi
    echo "Vendored sources:"
    echo "  argon2 reference implementation, P-H-C/phc-winner-argon2 @ f57e61e (Sources/CArgon2)"
    echo
    echo "Pinned sources (built for macOS ${MIN_MACOS}):"
    echo "  libfido2 1.16.0; libcbor 0.13.0; OpenSSL 3.5.8"
    echo "  SHA-256 source pins: scripts/build_dependencies.sh"
  } > "$MANIFEST"
  cp -R "$DEPS_PREFIX/licenses" "$RES_DIR/DependencyLicenses"
  cp scripts/licenses/Sparkle.txt "$RES_DIR/DependencyLicenses/Sparkle.txt"

  if [[ "$VIRTUAL_KEYS" == 1 ]]; then
    rust_host="$(rustc +1.94.1 -vV | sed -n 's/^host: //p')"
    metadata="$(mktemp -t fidopass-cargo-metadata)"
    trap 'rm -f "$metadata"' EXIT
    cargo +1.94.1 metadata --locked --format-version 1 --filter-platform "$rust_host" \
      --manifest-path tools/test-authenticator/Cargo.toml > "$metadata"
    python3 scripts/copy_opensk_licenses.py "$metadata" "$RES_DIR"
    rm -f "$metadata"
    trap - EXIT
  fi

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

python3 scripts/verify_bundle.py "$APP_DIR" --virtual-keys "$VIRTUAL_KEYS" \
  --expect-version "$SHORT_VERSION" --expect-build "$BUILD_VERSION"

echo "Bundled libraries:"
ls -1 "${FRAMEWORKS_DIR}"
echo "Created ${APP_DIR}"
