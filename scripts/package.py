"""Build GUI / lightweight CLI portable ZIPs from the same source tree.

Usage: python scripts/package.py --variant all [--output-dir dist]
Only the GUI build includes the renderer, builder and development material.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

PINNED_APPLE_SHA256 = '18e48f1785564fbf511241e0963b265057bfe742036d8543406c6ce07e48ec0b'
PINNED_APPLE_BYTES = 256391076
CLI_LIMIT = 64 * 1024
CLI_SHARED = ('lib/Common.ps1', 'lib/SystemTransaction.psm1',
              'lib/NativeTransaction.cs', 'lib/Finalize-Transaction.ps1')


def read_source(root: Path, relative: str) -> bytes:
    path = root / relative
    if not path.is_file() or path.is_symlink():
        raise ValueError(f'Missing or unsafe package file: {relative}')
    return path.read_bytes()


def package_members(root: Path, variant: str) -> dict[str, bytes]:
    lock = json.loads(read_source(root, 'fonts.lock.json').decode('utf-8-sig'))
    if lock['font']['sha256'] != PINNED_APPLE_SHA256 or lock['font']['size'] != PINNED_APPLE_BYTES:
        raise ValueError('Font lock differs from the audited pinned release')
    if variant == 'cli':
        names = ['aes.cmd', 'AppleEmojiSwitcher.Cli.ps1', 'VERSION', *CLI_SHARED]
        members = {name: read_source(root, name) for name in names}
        members['README.md'] = read_source(root, 'docs/CLI.md')
        members['fonts.lock.json'] = (json.dumps({'version': lock['version'], 'font': lock['font']},
                                                ensure_ascii=False, indent=2) + '\n').encode('utf-8')
        return members
    names = ['AppleEmojiSwitcher.ps1', 'AppleEmojiSwitcher.Cli.ps1', 'aes.cmd', '启动.vbs',
             '应用显示验收.html', 'fonts.lock.json', 'VERSION', 'README.md', 'VALIDATION.md',
             'SOURCES.md', 'THIRD_PARTY.md', 'CHANGELOG.md', '.gitattributes', '.gitignore']
    suffixes = {'.py', '.ps1', '.psm1', '.cs', '.cpp', '.cmd', '.md', '.json', '.tsv'}
    for folder in ('builder', 'lib', 'native', 'tests', 'scripts', 'docs'):
        names.extend(path.relative_to(root).as_posix() for path in (root / folder).rglob('*')
                     if path.is_file() and path.suffix in suffixes
                     and '__pycache__' not in path.parts and '.build' not in path.parts)
    names.append('bin/EmojiRender.exe')
    return {name: read_source(root, name) for name in sorted(set(names))}


def build(root: Path, output: Path, version: str, variant: str) -> dict:
    members = package_members(root, variant)
    manifest = ''.join(hashlib.sha256(data).hexdigest() + '  ' + name + '\n'
                       for name, data in sorted(members.items()))
    members['manifest.sha256'] = manifest.encode('utf-8')
    prefix = 'AppleEmojiSwitcher-CLI' if variant == 'cli' else 'AppleEmojiSwitcher'
    archive = output / f'{prefix}-{version}.zip'
    with ZipFile(archive, 'w', ZIP_DEFLATED, compresslevel=9) as bundle:
        for name, data in sorted(members.items()):
            info = ZipInfo(prefix + '/' + name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            bundle.writestr(info, data, compress_type=ZIP_DEFLATED, compresslevel=9)
    with ZipFile(archive) as bundle:
        if bundle.testzip() is not None:
            raise ValueError('Archive integrity check failed')
        for line in manifest.splitlines():
            expected, name = line.split('  ', 1)
            if hashlib.sha256(bundle.read(prefix + '/' + name)).hexdigest() != expected:
                raise ValueError(f'Archive hash mismatch: {name}')
    size = archive.stat().st_size
    if variant == 'cli' and size > CLI_LIMIT:
        raise ValueError(f'CLI archive exceeds 64 KiB: {size} bytes')
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix('.zip.sha256').write_text(checksum + '  ' + archive.name + '\n', encoding='ascii')
    return {'variant': variant, 'archive': str(archive), 'files': len(members),
            'bytes': size, 'sha256': checksum}


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=root / 'dist')
    parser.add_argument('--variant', choices=('gui', 'cli', 'all'), default='gui')
    args = parser.parse_args()
    version = read_source(root, 'VERSION').decode('utf-8-sig').strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[a-zA-Z0-9.]+)?', version):
        raise ValueError('Invalid VERSION')
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    variants = ('gui', 'cli') if args.variant == 'all' else (args.variant,)
    for variant in variants:
        print(json.dumps(build(root, output, version, variant), ensure_ascii=False))


if __name__ == '__main__':
    main()
