#!/usr/bin/env python3
"""Copy licenses from Cargo's resolved packages into the virtual app's resources."""
import json
import pathlib
import shutil
import sys


def main():
    metadata = json.loads(pathlib.Path(sys.argv[1]).read_text())
    destination = pathlib.Path(sys.argv[2]) / 'OpenSKLicenses'
    root = pathlib.Path(__file__).resolve().parent.parent
    upstream = root / '.build/test-authenticator/opensk'
    destination.mkdir(parents=True, exist_ok=True)
    records = ['OpenSK e161e95944871ccf719945738a272e718076c1df', 'Rust 1.94.1', '']
    for package in sorted(metadata['packages'], key=lambda package: (package['name'], package['version'])):
        source = pathlib.Path(package['manifest_path']).parent
        files = [path for path in source.iterdir() if path.is_file()
                 and path.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE', 'UNLICENSE'))]
        if package['name'] == 'opensk':
            files += [upstream / 'LICENSE']
        if package['name'] == 'fidopass-test-authenticator':
            files += [root / 'LICENSE']
        if not files:
            sys.exit(f'Missing license text: {package["name"]}')
        target = destination / f'{package["name"]}-{package["version"]}'
        target.mkdir(exist_ok=True)
        for path in files:
            shutil.copy2(path, target / path.name)
        records.append(f'{package["name"]} {package["version"]}: {package.get("license") or "MIT"}')
    (destination / 'SOURCES.txt').write_text('\n'.join(records) + '\n')
    shutil.copy2(root / 'tools/test-authenticator/Cargo.lock', destination / 'Cargo.lock')


if __name__ == '__main__':
    main()
