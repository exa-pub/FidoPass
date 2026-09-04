#!/usr/bin/env python3
"""Verify deployment targets, dependencies, signed-library hashes and the app signature."""
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


def verify_hashes(frameworks, manifest):
    for binary in frameworks.glob('*.dylib'):
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        if not re.search(r'^\s+' + re.escape(binary.name) + r'\s+' + digest + '$', manifest, re.M):
            sys.exit(f'Signed library hash missing or incorrect: {binary.name}')


def main():
    if len(sys.argv) != 2:
        sys.exit('Usage: verify_bundle.py PATH_TO_APP')
    app = pathlib.Path(sys.argv[1]).resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    minimum = version(info['LSMinimumSystemVersion'])
    frameworks = app / 'Contents/Frameworks'
    binaries = list((app / 'Contents/MacOS').iterdir()) + list(frameworks.glob('*.dylib'))
    for binary in binaries:
        verify_binary(binary, frameworks, minimum)
    verify_hashes(frameworks, (app / 'Contents/Resources/DEPENDENCIES.txt').read_text())
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print(f'Verified {len(binaries)} Mach-O files, all slices, dependencies, hashes and app signature')


if __name__ == '__main__':
    main()
