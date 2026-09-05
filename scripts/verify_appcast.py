#!/usr/bin/env python3
"""Check a generated appcast against the archive it describes, before anything is published.

Structure first — one item, the versions the bundle was built as, the immutable download
URL, the archive's exact length — then the EdDSA signature, verified offline with the
public key committed in scripts/release.env. A private key in CI that does not match the
public key in the app would otherwise be discovered by every user at once.
"""
import argparse
import pathlib
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
HERE = pathlib.Path(__file__).resolve().parent


def sparkle_attribute(element, name):
    return element.get(f'{{{SPARKLE}}}{name}')


def sparkle_child(item, name):
    child = item.find(f'{{{SPARKLE}}}{name}')
    return None if child is None else (child.text or '').strip()


def release_env():
    values = {}
    for line in (HERE / 'release.env').read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            key, value = line.split('=', 1)
            values[key] = value
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('appcast', type=pathlib.Path)
    parser.add_argument('--archive', type=pathlib.Path, required=True, help='the zip the enclosure points at')
    parser.add_argument('--version', required=True, help='CFBundleShortVersionString of the release')
    parser.add_argument('--build', required=True, help='CFBundleVersion of the release')
    parser.add_argument('--url', required=True, help='the exact enclosure URL expected')
    parser.add_argument('--channel', default='', help='expected sparkle:channel; empty for the default channel')
    parser.add_argument('--minimum-system', default='14.0')
    parser.add_argument('--public-key', default=None, help='base64 EdDSA public key; default from release.env')
    args = parser.parse_args()

    public_key = args.public_key or release_env().get('SPARKLE_PUBLIC_KEY', '')
    if not public_key:
        sys.exit('No SPARKLE_PUBLIC_KEY: set it in scripts/release.env before publishing')

    items = ET.parse(args.appcast).getroot().findall('./channel/item')
    if len(items) != 1:
        sys.exit(f'Expected exactly one <item>, found {len(items)}')
    item = items[0]

    if sparkle_child(item, 'version') != args.build:
        sys.exit(f'sparkle:version is {sparkle_child(item, "version")!r}, bundle was built as {args.build!r}')
    if sparkle_child(item, 'shortVersionString') != args.version:
        sys.exit(f'sparkle:shortVersionString is {sparkle_child(item, "shortVersionString")!r}, expected {args.version!r}')
    if sparkle_child(item, 'minimumSystemVersion') != args.minimum_system:
        sys.exit(f'sparkle:minimumSystemVersion is {sparkle_child(item, "minimumSystemVersion")!r}, expected {args.minimum_system!r}')
    channel = sparkle_child(item, 'channel') or ''
    if channel != args.channel:
        sys.exit(f'sparkle:channel is {channel!r}, expected {args.channel!r}')

    enclosure = item.find('enclosure')
    if enclosure is None:
        sys.exit('The item has no <enclosure>')
    if enclosure.get('url') != args.url:
        sys.exit(f'enclosure url is {enclosure.get("url")!r}, expected {args.url!r}')
    length = int(enclosure.get('length') or -1)
    actual = args.archive.stat().st_size
    if length != actual:
        sys.exit(f'enclosure length is {length}, {args.archive.name} is {actual} bytes')
    signature = sparkle_attribute(enclosure, 'edSignature')
    if not signature:
        sys.exit('The enclosure carries no sparkle:edSignature')

    result = subprocess.run(['swift', str(HERE / 'ed25519_verify.swift'), public_key, signature, str(args.archive)])
    if result.returncode == 1:
        sys.exit('The EdDSA signature does not verify with SPARKLE_PUBLIC_KEY: the signing key in CI is not the one in the app')
    if result.returncode != 0:
        sys.exit('Signature verification could not run')

    print(f'appcast: {args.version} ({args.build}) -> {args.url}, {actual} bytes, signature valid')


if __name__ == '__main__':
    main()
