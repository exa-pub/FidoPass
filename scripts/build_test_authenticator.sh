#!/bin/bash
# Used by transport tests and build_app.sh --virtual-keys.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
revision=e161e95944871ccf719945738a272e718076c1df
source_dir="$root/.build/test-authenticator/opensk"
if [ ! -d "$source_dir/.git" ]; then
    mkdir -p "$(dirname "$source_dir")"
    git clone --no-checkout https://github.com/google/OpenSK.git "$source_dir"
    git -C "$source_dir" checkout --detach "$revision"
fi
if [ "$(git -C "$source_dir" rev-parse HEAD)" != "$revision" ] || [ -n "$(git -C "$source_dir" status --porcelain)" ]; then
    echo "OpenSK checkout must be clean at $revision" >&2
    exit 1
fi
export CARGO_TARGET_DIR="$root/.build/test-authenticator/target"
cargo +1.94.1 build --locked --manifest-path "$root/tools/test-authenticator/Cargo.toml" "$@"
