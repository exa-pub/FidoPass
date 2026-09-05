#!/usr/bin/env bash
# Fetches the Sparkle release tarball — the one the app's framework comes from — for its
# command-line tools: generate_appcast, sign_update, generate_keys. Pinned by SHA-256 in
# scripts/release.env, like every other native dependency. Prints the bin directory.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source scripts/release.env
: "${SPARKLE_VERSION:?}" "${SPARKLE_TOOLS_SHA256:?}"

BASE=".build/sparkle-tools"
ARCHIVE="$BASE/Sparkle-$SPARKLE_VERSION.tar.xz"
DEST="$BASE/$SPARKLE_VERSION"
mkdir -p "$BASE"

if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --silent --show-error --retry 3 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    -o "$ARCHIVE.partial"
  mv "$ARCHIVE.partial" "$ARCHIVE"
fi
echo "$SPARKLE_TOOLS_SHA256  $ARCHIVE" | shasum -a 256 --check --status || {
  echo "fetch_sparkle_tools.sh: $ARCHIVE does not match SPARKLE_TOOLS_SHA256" >&2
  rm -f "$ARCHIVE"
  exit 1
}

if [[ ! -x "$DEST/bin/generate_appcast" ]]; then
  rm -rf "$DEST"
  mkdir -p "$DEST"
  tar -xf "$ARCHIVE" -C "$DEST"
fi

# The tools must match the framework the app carries, or the appcast they write could
# describe features that framework does not read.
shipped="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Sparkle.framework/Resources/Info.plist")"
if [[ "$shipped" != "$SPARKLE_VERSION" ]]; then
  echo "fetch_sparkle_tools.sh: tarball is Sparkle $shipped, release.env says $SPARKLE_VERSION" >&2
  exit 1
fi

echo "$PWD/$DEST/bin"
