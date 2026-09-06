"""Build and verify a portable release using only public repository files.

Usage: python scripts/package.py [--output-dir dist]
No fonts, downloaded dependencies, local logs, or system backups are included.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=root / 'dist')
    args = parser.parse_args()
    version = (root / 'VERSION').read_text(encoding='utf-8').strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[a-zA-Z0-9.]+)?', version):
        raise ValueError('Invalid VERSION')
    names = ['AppleEmojiSwitcher.ps1', '启动.vbs', '应用显示验收.html',
             'fonts.lock.json', 'VERSION', 'README.md', 'VALIDATION.md',
             'SOURCES.md', 'THIRD_PARTY.md', 'CHANGELOG.md', '.gitattributes', '.gitignore']
    files = [root / name for name in names]
    suffixes = {'.py', '.ps1', '.psm1', '.cs', '.cpp', '.cmd', '.md', '.json', '.tsv'}
    for folder in ('builder', 'lib', 'native', 'tests', 'scripts', 'docs'):
        files.extend(path for path in (root / folder).rglob('*')
                     if path.is_file() and path.suffix in suffixes
                     and '__pycache__' not in path.parts and '.build' not in path.parts)
    files.append(root / 'bin' / 'EmojiRender.exe')
    files = sorted(set(files), key=lambda path: path.relative_to(root).as_posix())
    for path in files:
        if not path.is_file() or path.is_symlink():
            raise ValueError(f'Missing or unsafe package file: {path.relative_to(root)}')
    manifest = ''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' +
                       path.relative_to(root).as_posix() + '\n' for path in files)
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f'AppleEmojiSwitcher-{version}.zip'
    with ZipFile(archive, 'w', ZIP_DEFLATED, compresslevel=9) as bundle:
        for path in files:
            bundle.write(path, 'AppleEmojiSwitcher/' + path.relative_to(root).as_posix())
        bundle.writestr('AppleEmojiSwitcher/manifest.sha256', manifest)
    with ZipFile(archive) as bundle:
        if bundle.testzip() is not None:
            raise ValueError('Archive integrity check failed')
        for line in manifest.splitlines():
            expected, name = line.split('  ', 1)
            actual = hashlib.sha256(bundle.read('AppleEmojiSwitcher/' + name)).hexdigest()
            if actual != expected:
                raise ValueError(f'Archive hash mismatch: {name}')
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix('.zip.sha256').write_text(checksum + '  ' + archive.name + '\n', encoding='ascii')
    print(json.dumps({'archive': str(archive), 'files': len(files) + 1,
                      'bytes': archive.stat().st_size, 'sha256': checksum}, ensure_ascii=False))


if __name__ == '__main__':
    main()
