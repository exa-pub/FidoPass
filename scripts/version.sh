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
#   FIDOPASS_COMMIT         The short hash, with -dirty when tracked files have changes.
#   FIDOPASS_IS_RELEASE     1 exactly on a tag with a clean tree.
#   FIDOPASS_IS_PRERELEASE  1 when that tag carries a -alpha.N / -beta.N / -rc.N suffix.
#   FIDOPASS_TAG            The tag, when on one; empty otherwise.
#
# A commit may carry several version tags — a release is usually cut from the very commit
# the last beta was tested on. The highest one counts: a release above any prerelease of
# the same version, rc above beta above alpha, then the numbers. `git describe` alone would
# pick by tag type and date, which is not that.
#
# FIDOPASS_SOURCE_DIR points at another checkout (the tests use it); the default is this
# repository.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SOURCE_DIR="${FIDOPASS_SOURCE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
git() { command git -C "$SOURCE_DIR" "$@"; }

TAG_PATTERN='^v([0-9]+)\.([0-9]+)\.([0-9]+)(-(alpha|beta|rc)\.([0-9]+))?$'

# A sortable key for a tag: zero-padded numbers, release stage 3 above rc 2, beta 1, alpha 0.
# Failures are returned, not exited: `set -e` does not reach into command substitutions,
# so every caller checks the status itself.
rank() {
  local tag="$1" stage=3 number=0
  if ! [[ "$tag" =~ $TAG_PATTERN ]]; then
    echo "version.sh: tag '$tag' is not vMAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N]" >&2
    return 1
  fi
  case "${BASH_REMATCH[5]}" in alpha) stage=0 ;; beta) stage=1 ;; rc) stage=2 ;; esac
  number="${BASH_REMATCH[6]:-0}"
  printf '%06d.%06d.%06d.%d.%06d\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "$stage" "$number"
}

# The highest version tag on a commit, or nothing. Every version tag there must parse: a
# stray "v1.0" on a released commit is an error, not something to skip quietly.
best_tag_at() {
  local commit="$1" best="" best_key="" tag key
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    key="$(rank "$tag")" || return 1
    if [[ -z "$best" || "$key" > "$best_key" ]]; then
      best="$tag"
      best_key="$key"
    fi
  done < <(git tag --points-at "$commit" --list 'v[0-9]*')
  printf '%s' "$best"
}

head="$(git rev-parse --verify HEAD 2>/dev/null || true)"
commit="unknown"
dirty=""
tag=""
distance=0

if [[ -n "$head" ]]; then
  commit="$(git rev-parse --short HEAD)"
  # Tracked modifications only, like `git describe --dirty`; untracked files do not count.
  git update-index -q --refresh >/dev/null 2>&1 || true
  if ! git diff-index --quiet HEAD -- 2>/dev/null; then dirty="-dirty"; fi

  tag="$(best_tag_at "$head")" || exit 1
  if [[ -z "$tag" ]]; then
    # Not on a tag: name the build after the nearest tagged commit and count from there.
    nearest="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
    if [[ -n "$nearest" ]]; then
      base_commit="$(git rev-parse "${nearest}^{commit}")"
      tag="$(best_tag_at "$base_commit")" || exit 1
      distance="$(git rev-list --count "${base_commit}..HEAD")"
    else
      distance="$(git rev-list --count HEAD)"
    fi
  fi
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
