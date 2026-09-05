#!/usr/bin/env python3
"""Verify deployment targets, dependencies, signed-library hashes, the updater and the app signature."""
import argparse
import hashlib
import pathlib
import plistlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent

# Every piece of code inside Sparkle.framework that carries its own signature, relative to
# Versions/B. The framework binary is listed with them because it is hashed and checked too.
SPARKLE_CODE = {
    'Sparkle.framework': 'Sparkle',
    'Installer.xpc': 'XPCServices/Installer.xpc/Contents/MacOS/Installer',
    'Downloader.xpc': 'XPCServices/Downloader.xpc/Contents/MacOS/Downloader',
    'Autoupdate': 'Autoupdate',
    'Updater.app': 'Updater.app/Contents/MacOS/Updater',
}
SPARKLE_SIGNED = {
    'Installer.xpc': 'XPCServices/Installer.xpc',
    'Downloader.xpc': 'XPCServices/Downloader.xpc',
    'Autoupdate': 'Autoupdate',
    'Updater.app': 'Updater.app',
}


def version(text):
    return tuple((list(map(int, text.split('.'))) + [0, 0])[:3])


def release_env():
    values = {}
    for line in (HERE / 'release.env').read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            key, value = line.split('=', 1)
            values[key] = value
    return values


def verify_binary(binary, frameworks, minimum):
    architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    for arch in architectures:
        commands = subprocess.check_output(['otool', '-arch', arch, '-l', str(binary)], text=True)
        versions = re.findall(r'\bminos (\d+(?:\.\d+)*)', commands)
        versions += re.findall(
            r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+)*)', commands
        )
        if not versions or any(version(value) > minimum for value in versions):
            sys.exit(f'{binary.name} ({arch}) requires {versions}; bundle promises {minimum}')

        dependencies = subprocess.check_output(['otool', '-arch', arch, '-L', str(binary)], text=True)
        for line in dependencies.splitlines()[1:]:
            dependency = line.strip().split(' (')[0]
            if dependency.startswith(('/usr/lib/', '/System/Library/')):
                continue
            if dependency.startswith('@rpath/') and (frameworks / dependency.removeprefix('@rpath/')).is_file():
                continue
            sys.exit(f'Unresolved dependency in {binary.name} ({arch}): {dependency}')


def verify_hashes(named_binaries, manifest):
    for name, binary in named_binaries:
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        if not re.search(r'^\s+' + re.escape(name) + r'\s+' + digest + '$', manifest, re.M):
            sys.exit(f'Signed binary hash missing or incorrect: {name}')


def signing_info(path):
    """codesign's description of a signature: flags, authorities, team."""
    result = subprocess.run(['codesign', '--display', '--verbose=2', str(path)], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f'{path.name} is not signed: {result.stderr.strip()}')
    return result.stderr


def verify_sparkle(app, info, env, developer_id):
    framework = app / 'Contents/Frameworks/Sparkle.framework'
    versions = framework / 'Versions/B'
    if not framework.is_dir():
        sys.exit('Sparkle.framework is missing from the bundle')
    shipped = plistlib.loads((framework / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
    if shipped != env['SPARKLE_VERSION']:
        sys.exit(f'Bundle carries Sparkle {shipped}; scripts/release.env pins {env["SPARKLE_VERSION"]}')
    code = {}
    for name, relative in SPARKLE_CODE.items():
        path = versions / relative
        if not path.is_file():
            sys.exit(f'Sparkle is incomplete: {relative} is missing')
        code[name] = path

    # A local build has no feed and offers nothing; a Developer ID build must have the feed,
    # the key, and helpers signed by the same team with the hardened runtime — anything less
    # and notarisation, or Sparkle itself, refuses the update later, on the user's Mac.
    if info.get('SUEnableAutomaticChecks') is not True:
        sys.exit('SUEnableAutomaticChecks must be true, or Sparkle would ask with a dialog of its own')
    expected_key = env.get('SPARKLE_PUBLIC_KEY', '')
    if expected_key and info.get('SUPublicEDKey') != expected_key:
        sys.exit('SUPublicEDKey does not match scripts/release.env')
    if not expected_key and 'SUPublicEDKey' in info:
        sys.exit('SUPublicEDKey is set but scripts/release.env has no public key')
    if developer_id:
        if info.get('SUFeedURL') != env['SPARKLE_FEED_URL']:
            sys.exit('A Developer ID build must carry the release feed URL from scripts/release.env')
        if not expected_key:
            sys.exit('A Developer ID build must carry SUPublicEDKey')
        for name, relative in SPARKLE_SIGNED.items():
            description = signing_info(versions / relative)
            if '(runtime)' not in description and 'runtime' not in re.search(r'flags=\S+', description).group(0):
                sys.exit(f'Sparkle helper {name} is signed without the hardened runtime')
            if f'TeamIdentifier={env["FIDOPASS_TEAM_ID"]}' not in description:
                sys.exit(f'Sparkle helper {name} is not signed by team {env["FIDOPASS_TEAM_ID"]}')
        description = signing_info(framework)
        if f'TeamIdentifier={env["FIDOPASS_TEAM_ID"]}' not in description:
            sys.exit(f'Sparkle.framework is not signed by team {env["FIDOPASS_TEAM_ID"]}')
    elif 'SUFeedURL' in info:
        sys.exit('Only a Developer ID build may carry SUFeedURL; an ad-hoc build could never install what it finds')
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('--virtual-keys', type=int, choices=[0, 1])
    parser.add_argument('--expect-version', help='the CFBundleShortVersionString the bundle must carry')
    parser.add_argument('--expect-build', help='the CFBundleVersion the bundle must carry')
    args = parser.parse_args()
    app = args.app.resolve()
    env = release_env()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    virtual = info.get('FidoPassVirtualKeys', 0)
    if virtual not in (0, 1) or (args.virtual_keys is not None and virtual != args.virtual_keys):
        sys.exit('Bundle virtual-key mode does not match the requested build')
    if args.expect_version and info.get('CFBundleShortVersionString') != args.expect_version:
        sys.exit(f'CFBundleShortVersionString is {info.get("CFBundleShortVersionString")!r}, expected {args.expect_version!r}')
    if args.expect_build and info.get('CFBundleVersion') != args.expect_build:
        sys.exit(f'CFBundleVersion is {info.get("CFBundleVersion")!r}, expected {args.expect_build!r}')
    if not info.get('FidoPassGitCommit'):
        sys.exit('FidoPassGitCommit is missing: the bundle does not say what it was built from')
    minimum = version(info['LSMinimumSystemVersion'])
    frameworks = app / 'Contents/Frameworks'
    helpers = list((app / 'Contents/Helpers').glob('*'))
    expected = ['fidopass-test-authenticator'] if virtual else []
    if sorted(path.name for path in helpers) != expected:
        sys.exit('Unexpected or missing bundled OpenSK helper')
    resources = app / 'Contents/Resources'
    if virtual and not (resources / 'OpenSKLicenses/SOURCES.txt').is_file():
        sys.exit('OpenSK license metadata is missing')
    if not virtual and (resources / 'OpenSKLicenses').exists():
        sys.exit('OpenSK resources found in a physical-key build')
    if not (resources / 'DependencyLicenses/Sparkle.txt').is_file():
        sys.exit('Sparkle license is missing from DependencyLicenses')

    app_signature = signing_info(app)
    developer_id = 'Authority=Developer ID Application' in app_signature
    if developer_id and f'TeamIdentifier={env["FIDOPASS_TEAM_ID"]}' not in app_signature:
        sys.exit(f'The app is signed by another team than {env["FIDOPASS_TEAM_ID"]}')
    sparkle = verify_sparkle(app, info, env, developer_id)

    libraries = list(frameworks.glob('*.dylib'))
    binaries = list((app / 'Contents/MacOS').iterdir()) + libraries + helpers + list(sparkle.values())
    app_archs = set(subprocess.check_output(
        ['lipo', '-archs', str(app / 'Contents/MacOS' / info['CFBundleExecutable'])], text=True).split())
    for binary in binaries:
        archs = set(subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split())
        if not app_archs.issubset(archs):
            sys.exit(f'{binary.name} is missing app architectures: {app_archs - archs}')
        verify_binary(binary, frameworks, minimum)
    manifest = (resources / 'DEPENDENCIES.txt').read_text()
    verify_hashes([(path.name, path) for path in libraries + helpers] + [('Sparkle.framework', sparkle['Sparkle.framework'])],
                  manifest)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print(f'Verified {len(binaries)} Mach-O files, all slices, dependencies, hashes, Sparkle {env["SPARKLE_VERSION"]} '
          f'and the {"Developer ID" if developer_id else "ad-hoc"} app signature')


if __name__ == '__main__':
    main()
