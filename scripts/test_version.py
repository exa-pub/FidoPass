#!/usr/bin/env python3
"""Pin what scripts/version.sh says for every shape of checkout, on throwaway repositories."""
import os
import pathlib
import subprocess
import sys
import tempfile

SCRIPT = pathlib.Path(__file__).resolve().parent / 'version.sh'


def git(repo, *args):
    env = {**os.environ, 'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@t', 'GIT_COMMITTER_NAME': 't',
           'GIT_COMMITTER_EMAIL': 't@t', 'GIT_AUTHOR_DATE': '2026-01-01T00:00:00Z', 'GIT_COMMITTER_DATE': '2026-01-01T00:00:00Z'}
    subprocess.run(['git', '-C', str(repo), *args], check=True, env=env, capture_output=True)


def commit(repo, name):
    (repo / name).write_text(name)
    git(repo, 'add', name)
    git(repo, 'commit', '-q', '-m', name)


def version(repo):
    result = subprocess.run(['bash', str(SCRIPT)], env={**os.environ, 'FIDOPASS_SOURCE_DIR': str(repo)},
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None, result.stderr.strip()
    return dict(line.split('=', 1) for line in result.stdout.splitlines()), None


def expect(actual, **fields):
    for key, value in fields.items():
        if actual.get(f'FIDOPASS_{key}') != value:
            sys.exit(f'{key}: expected {value!r}, got {actual.get("FIDOPASS_" + key)!r} in {actual}')


def main():
    with tempfile.TemporaryDirectory() as directory:
        repo = pathlib.Path(directory)
        git(repo, 'init', '-q', '-b', 'main')

        commit(repo, 'one')
        untagged, _ = version(repo)
        expect(untagged, VERSION='0.0.0-dev.1', BUILD='0.0.0.1', IS_RELEASE='0', IS_PRERELEASE='0', TAG='')

        # The release shape: an annotated tag on a clean tree.
        git(repo, 'tag', '-a', 'v0.17.0', '-m', 'FidoPass 0.17.0')
        release, _ = version(repo)
        expect(release, VERSION='0.17.0', BUILD='0.17.0', IS_RELEASE='1', IS_PRERELEASE='0', TAG='v0.17.0')
        assert '-dirty' not in release['FIDOPASS_COMMIT'] and len(release['FIDOPASS_COMMIT']) >= 7

        # Work after the tag is named after it, and its build number sorts between releases.
        commit(repo, 'two')
        commit(repo, 'three')
        after, _ = version(repo)
        expect(after, VERSION='0.17.0-dev.2', BUILD='0.17.0.2', IS_RELEASE='0', TAG='')

        # Uncommitted changes are visible in the version and never a release.
        (repo / 'three').write_text('changed')
        dirty, _ = version(repo)
        expect(dirty, VERSION='0.17.0-dev.2.dirty', BUILD='0.17.0.2', IS_RELEASE='0')
        assert dirty['FIDOPASS_COMMIT'].endswith('-dirty')
        git(repo, 'checkout', '--', 'three')

        # A dirty tree on the tag itself is not that release either.
        commit(repo, 'four')
        git(repo, 'tag', '-a', 'v0.18.0-beta.1', '-m', 'beta')
        (repo / 'four').write_text('changed')
        dirty_tag, _ = version(repo)
        expect(dirty_tag, VERSION='0.18.0-beta.1-dev.0.dirty', BUILD='0.18.0b1.0', IS_RELEASE='0')
        git(repo, 'checkout', '--', 'four')

        # Prereleases are releases with a suffix, spelt for Sparkle's comparator in the build
        # number; lightweight tags count too.
        prerelease, _ = version(repo)
        expect(prerelease, VERSION='0.18.0-beta.1', BUILD='0.18.0b1', IS_RELEASE='1', IS_PRERELEASE='1',
               TAG='v0.18.0-beta.1')
        commit(repo, 'five')
        git(repo, 'tag', 'v0.18.0')
        lightweight, _ = version(repo)
        expect(lightweight, VERSION='0.18.0', BUILD='0.18.0', IS_RELEASE='1', IS_PRERELEASE='0', TAG='v0.18.0')

        # A tag that is not a version is refused rather than guessed at.
        commit(repo, 'six')
        git(repo, 'tag', 'v1.0')
        refused, error = version(repo)
        assert refused is None and 'v1.0' in error, (refused, error)

    print('version.sh: all shapes verified')


if __name__ == '__main__':
    main()
