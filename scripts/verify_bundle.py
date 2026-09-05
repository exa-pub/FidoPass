#!/usr/bin/env python3
"""Verify deployment targets, dependencies, signed-library hashes and the app signature."""
import argparse
import hashlib
import pathlib
import plistlib
import re
import subprocess
import sys


def version(text):
    return tuple((list(map(int, text.split('.'))) + [0, 0])[:3])


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


def verify_hashes(binaries, manifest):
    for binary in binaries:
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        if not re.search(r'^\s+' + re.escape(binary.name) + r'\s+' + digest + '$', manifest, re.M):
            sys.exit(f'Signed binary hash missing or incorrect: {binary.name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('--virtual-keys', type=int, choices=[0, 1])
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    virtual = info.get('FidoPassVirtualKeys', 0)
    if virtual not in (0, 1) or (args.virtual_keys is not None and virtual != args.virtual_keys):
        sys.exit('Bundle virtual-key mode does not match the requested build')
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
    libraries = list(frameworks.glob('*.dylib'))
    binaries = list((app / 'Contents/MacOS').iterdir()) + libraries + helpers
    app_archs = set(subprocess.check_output(
        ['lipo', '-archs', str(app / 'Contents/MacOS' / info['CFBundleExecutable'])], text=True).split())
    for binary in binaries:
        archs = set(subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split())
        if not app_archs.issubset(archs):
            sys.exit(f'{binary.name} is missing app architectures: {app_archs - archs}')
        verify_binary(binary, frameworks, minimum)
    verify_hashes(libraries + helpers, (resources / 'DEPENDENCIES.txt').read_text())
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print(f'Verified {len(binaries)} Mach-O files, all slices, dependencies, hashes and app signature')


if __name__ == '__main__':
    main()
