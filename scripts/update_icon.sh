#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE >&2
Usage: $0 /path/to/AppIcon.icns
       $0 /path/to/Icon.iconset
       $0 /path/to/source.png
USAGE
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

INPUT_PATH="$1"
if [[ ! -e "$INPUT_PATH" ]]; then
  echo "[error] icon path not found: $INPUT_PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." &>/dev/null && pwd)"
TARGET_ICON="${PROJECT_ROOT}/Sources/FidoPassApp/Resources/AppIcon.icns"
ICONSET_DIR="${PROJECT_ROOT}/Icon.iconset"

cleanup_dirs=()
cleanup_files=()
cleanup() {
  for f in "${cleanup_files[@]:-}"; do rm -f "$f" 2>/dev/null || true; done
  for d in "${cleanup_dirs[@]:-}"; do rm -rf "$d" 2>/dev/null || true; done
}
trap cleanup EXIT

copy_icns() {
  local src="$1"
  mkdir -p "$(dirname "$TARGET_ICON")"
  local tmp_file="${TARGET_ICON}.tmp"
  cleanup_files+=("$tmp_file")
  install -m 0644 "$src" "$tmp_file"
  mv "$tmp_file" "$TARGET_ICON"
}

regenerate_iconset_from_icns() {
  local icns="$1"
  if ! command -v iconutil >/dev/null 2>&1; then
    echo "[info] iconutil not found; skipping iconset regeneration" >&2
    return
  fi
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  cleanup_dirs+=("$tmp_dir")
  if iconutil -c iconset -o "${tmp_dir}/Icon.iconset" "$icns" >/dev/null 2>&1; then
    rm -rf "$ICONSET_DIR"
    mv "${tmp_dir}/Icon.iconset" "$ICONSET_DIR"
  else
    echo "[warn] iconutil failed to generate iconset from $icns; leaving existing iconset untouched" >&2
  fi
}

generate_iconset_from_png() {
  local png="$1"
  if ! command -v sips >/dev/null 2>&1; then
    echo "[error] sips is required when providing a PNG source" >&2
    exit 1
  fi
  if ! command -v iconutil >/dev/null 2>&1; then
    echo "[error] iconutil is required when providing a PNG source" >&2
    exit 1
  fi

  local work_dir
  work_dir="$(mktemp -d)"
  cleanup_dirs+=("$work_dir")
  local iconset_dir="${work_dir}/Icon.iconset"
  mkdir -p "$iconset_dir"

  local sizes=(16 32 64 128 256 512)
  for size in "${sizes[@]}"; do
    local retina=$((size * 2))
    local file_name="icon_${size}x${size}.png"
    local retina_name="icon_${size}x${size}@2x.png"
    sips -z "$size" "$size" "$png" --out "${iconset_dir}/${file_name}" >/dev/null
    sips -z "$retina" "$retina" "$png" --out "${iconset_dir}/${retina_name}" >/dev/null
  done

  iconutil -c icns -o "${work_dir}/AppIcon.icns" "$iconset_dir"
  copy_icns "${work_dir}/AppIcon.icns"
  rm -rf "$ICONSET_DIR"
  cp -R "$iconset_dir" "$ICONSET_DIR"
}

if [[ -d "$INPUT_PATH" ]]; then
  case "$INPUT_PATH" in
    *.iconset )
      if ! command -v iconutil >/dev/null 2>&1; then
        echo "[error] iconutil is required when providing an .iconset directory" >&2
        exit 1
      fi
      tmp_dir_from_iconset="$(mktemp -d)"
      cleanup_dirs+=("$tmp_dir_from_iconset")
      iconutil -c icns -o "${tmp_dir_from_iconset}/AppIcon.icns" "$INPUT_PATH"
      copy_icns "${tmp_dir_from_iconset}/AppIcon.icns"
      rm -rf "$ICONSET_DIR"
      cp -R "$INPUT_PATH" "$ICONSET_DIR"
      ;;
    * )
      echo "[error] unsupported directory input (expecting *.iconset): $INPUT_PATH" >&2
      exit 1
      ;;
  esac
elif [[ -f "$INPUT_PATH" ]]; then
  case "$INPUT_PATH" in
    *.icns )
      copy_icns "$INPUT_PATH"
      regenerate_iconset_from_icns "$INPUT_PATH"
      ;;
    *.png )
      generate_iconset_from_png "$INPUT_PATH"
      ;;
    *.iconset )
      echo "[error] pass the iconset directory (not an archive): $INPUT_PATH" >&2
      exit 1
      ;;
    * )
      echo "[error] unsupported file type (expect .icns, .png, or .iconset directory): $INPUT_PATH" >&2
      exit 1
      ;;
  esac
else
  echo "[error] unsupported input: $INPUT_PATH" >&2
  exit 1
fi

trap - EXIT
cleanup

echo "Updated app icon at ${TARGET_ICON}"
