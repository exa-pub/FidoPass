#!/usr/bin/env bash
# Release dependencies are built for the app's minimum OS, never copied from brew bottles.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ARCH="$(uname -m)"
MIN_MACOS="$(sed -n 's/.*\.macOS(\.v\([0-9][0-9]*\)).*/\1/p' Package.swift | head -1).0"
BASE="$ROOT/.build/native-dependencies"
PREFIX="$BASE/$ARCH/prefix"
mkdir -p "$BASE/downloads" "$BASE/$ARCH"
command -v cmake >/dev/null || { echo 'cmake is required (brew install cmake)' >&2; exit 1; }
command -v pkg-config >/dev/null || { echo 'pkg-config is required' >&2; exit 1; }
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
JOBS="${FIDOPASS_BUILD_JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"
fetch() {
  local name="$1" url="$2" sha="$3"
  if [[ ! -f "$BASE/downloads/$name" ]]; then
    curl --fail --location --retry 3 "$url" -o "$BASE/downloads/$name.partial"
    mv "$BASE/downloads/$name.partial" "$BASE/downloads/$name"
  fi
  echo "$sha  $BASE/downloads/$name" | shasum -a 256 --check --status
}
fetch openssl-3.5.8.tar.gz https://github.com/openssl/openssl/releases/download/openssl-3.5.8/openssl-3.5.8.tar.gz a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2
fetch libcbor-0.13.0.tar.gz https://github.com/PJK/libcbor/archive/refs/tags/v0.13.0.tar.gz 95a7f0dd333fd1dce3e4f92691ca8be38227b27887599b21cd3c4f6d6a7abb10
fetch libfido2-1.16.0.tar.gz https://developers.yubico.com/libfido2/Releases/libfido2-1.16.0.tar.gz 8c2b6fb279b5b42e9ac92ade71832e485852647b53607c43baaafbbcecea04e4
STAMP="$(shasum -a 256 "$0" | cut -d ' ' -f 1)-$(xcrun --show-sdk-version)-$MIN_MACOS"
if [[ -f "$PREFIX/.stamp" ]] && [[ "$(cat "$PREFIX/.stamp")" == "$STAMP" ]]; then
  echo "Dependencies ready: $PREFIX"
  exit 0
fi
# This directory contains only generated, version-pinned dependency builds.
rm -rf "$BASE/$ARCH"
mkdir -p "$BASE/$ARCH" "$PREFIX"
for archive in openssl-3.5.8 libcbor-0.13.0 libfido2-1.16.0; do
  tar -xf "$BASE/downloads/$archive.tar.gz" -C "$BASE/$ARCH"
done
case "$ARCH" in arm64) OPENSSL_TARGET=darwin64-arm64-cc;; x86_64) OPENSSL_TARGET=darwin64-x86_64-cc;; *) exit 1;; esac
(
  cd "$BASE/$ARCH/openssl-3.5.8"
  ./Configure "$OPENSSL_TARGET" shared no-tests --prefix="$PREFIX" --libdir=lib "-mmacosx-version-min=$MIN_MACOS"
  make -j "$JOBS"
  make install_sw
)
COMMON=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib")
cmake -S "$BASE/$ARCH/libcbor-0.13.0" -B "$BASE/$ARCH/cbor-build" "${COMMON[@]}" -DBUILD_SHARED_LIBS=ON -DWITH_EXAMPLES=OFF
cmake --build "$BASE/$ARCH/cbor-build" -j "$JOBS"
cmake --install "$BASE/$ARCH/cbor-build"
cmake -S "$BASE/$ARCH/libfido2-1.16.0" -B "$BASE/$ARCH/fido-build" "${COMMON[@]}" -DOPENSSL_ROOT_DIR="$PREFIX" -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_MANPAGES=OFF -DBUILD_TOOLS=OFF -DBUILD_STATIC_LIBS=OFF
cmake --build "$BASE/$ARCH/fido-build" -j "$JOBS"
cmake --install "$BASE/$ARCH/fido-build"
mkdir -p "$PREFIX/licenses"
cp "$BASE/$ARCH/openssl-3.5.8/LICENSE.txt" "$PREFIX/licenses/OpenSSL.txt"
cp "$BASE/$ARCH/libcbor-0.13.0/LICENSE.md" "$PREFIX/licenses/libcbor.txt"
cp "$BASE/$ARCH/libfido2-1.16.0/LICENSE" "$PREFIX/licenses/libfido2.txt"
printf '%s\n' "$STAMP" > "$PREFIX/.stamp"
echo "Dependencies ready: $PREFIX"
