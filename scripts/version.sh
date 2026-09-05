#!/usr/bin/env bash
# The one place a FidoPass version comes from.
#
# Prints KEY=VALUE lines: shell scripts `eval "$(bash scripts/version.sh)"`, CI appends them
# to $GITHUB_OUTPUT. The tag is the source of truth; see docs/release.md.
#
#   FIDOPASS_VERSION        CFBundleShortVersionString. A tag gives its own number:
#                           0.18.0, or 0.18.0-beta.1. Anything else is a development build,
#                           named after the last tag: 0.17.0-dev.8, 0.17.0-dev.8.dirty.
#   FIDOPASS_BUILD          CFBundleVersion, what Sparkle compares. Equal to the version
#                           for a release tag. A prerelease tag is written the way Sparkle
#                           orders: v0.18.0-beta.1 gives 0.18.0b1, because its comparator
#                           ignores a "-suffix" entirely (0.18.0-beta.1 == 0.18.0) but knows
#                           0.18.0a1 < 0.18.0b1 < 0.18.0rc1 < 0.18.0. A development build
#                           is <tag build>.<commits since>: 0.17.0 < 0.17.0.8 < 0.17.1.
#                           Development builds never update.
#   FIDOPASS_COMMIT         The short hash, with -dirty when the tree has changes.
#   FIDOPASS_IS_RELEASE     1 exactly on a tag with a clean tree.
#   FIDOPASS_IS_PRERELEASE  1 when that tag carries a -beta.N / -rc.N suffix.
#   FIDOPASS_TAG            The tag, when on one; empty otherwise.
#
# FIDOPASS_SOURCE_DIR points at another checkout (the tests use it); the default is this
# repository.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SOURCE_DIR="${FIDOPASS_SOURCE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
git() { command git -C "$SOURCE_DIR" "$@"; }

TAG_PATTERN='^v([0-9]+)\.([0-9]+)\.([0-9]+)(-(alpha|beta|rc)\.[0-9]+)?$'

tag=""
distance=""
commit=""
dirty=""

describe="$(git describe --tags --long --dirty --match 'v[0-9]*' 2>/dev/null || true)"
if [[ -n "$describe" ]]; then
  # v0.17.0-8-g36a05a1[-dirty]; the tag itself may contain dashes (v0.18.0-beta.1).
  if [[ "$describe" =~ ^(.+)-([0-9]+)-g([0-9a-f]+)(-dirty)?$ ]]; then
    tag="${BASH_REMATCH[1]}"
    distance="${BASH_REMATCH[2]}"
    commit="${BASH_REMATCH[3]}"
    dirty="${BASH_REMATCH[4]}"
  else
    echo "version.sh: cannot parse 'git describe' output: $describe" >&2
    exit 1
  fi
  if ! [[ "$tag" =~ $TAG_PATTERN ]]; then
    echo "version.sh: tag '$tag' is not vMAJOR.MINOR.PATCH[-beta.N|-rc.N|-alpha.N]" >&2
    exit 1
  fi
else
  # No tag reachable: a fresh repository, or a checkout without tags.
  tag=""
  distance="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
  commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then dirty="-dirty"; fi
fi

if [[ -n "$tag" ]]; then
  base="${tag#v}"                 # 0.18.0-beta.1
  core="${base%%-*}"              # 0.18.0
  suffix="${base#"$core"}"        # -beta.1 or empty
else
  base="0.0.0"
  core="0.0.0"
  suffix=""
fi

# The tag's own build number, in the notation Sparkle's comparator orders.
case "$suffix" in
  "")        tag_build="$core" ;;
  -alpha.*)  tag_build="${core}a${suffix#-alpha.}" ;;
  -beta.*)   tag_build="${core}b${suffix#-beta.}" ;;
  -rc.*)     tag_build="${core}rc${suffix#-rc.}" ;;
  *)         echo "version.sh: unsupported prerelease suffix '$suffix'" >&2; exit 1 ;;
esac

if [[ -n "$tag" && "$distance" == "0" && -z "$dirty" ]]; then
  version="$base"
  build="$tag_build"
  is_release=1
  is_prerelease=$([[ -n "$suffix" ]] && echo 1 || echo 0)
else
  version="${base}-dev.${distance}"
  [[ -n "$dirty" ]] && version="${version}.dirty"
  build="${tag_build}.${distance}"
  is_release=0
  is_prerelease=0
  tag=""
fi

printf 'FIDOPASS_VERSION=%s\n' "$version"
printf 'FIDOPASS_BUILD=%s\n' "$build"
printf 'FIDOPASS_COMMIT=%s\n' "${commit}${dirty}"
printf 'FIDOPASS_IS_RELEASE=%s\n' "$is_release"
printf 'FIDOPASS_IS_PRERELEASE=%s\n' "$is_prerelease"
printf 'FIDOPASS_TAG=%s\n' "$tag"
