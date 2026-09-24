"""Verify the three portable variants using only the Python standard library."""
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('aes_package', ROOT / 'scripts/package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PortablePackages(unittest.TestCase):
    def test_gui_readme_images_are_packaged(self):
        members = package.package_members(ROOT, 'gui')
        images = re.findall(r'!\[[^\]]*\]\(([^)]+)\)', members['README.md'].decode('utf-8-sig'))
        self.assertTrue(images, 'README must contain its visual comparison')
        for image in images:
            if image.startswith(('https://', 'http://')):
                continue
            self.assertIn(image, members, 'The portable README must retain its local images')
            self.assertEqual(members[image], (ROOT / image).read_bytes())

    def test_panel_package_is_independent_and_matches_gui(self):
        if not (ROOT / 'bin/PanelController.exe').is_file():
            with self.assertRaisesRegex(ValueError, 'Missing or unsafe package file: bin/Panel'):
                package.package_members(ROOT, 'panel')
            return
        with tempfile.TemporaryDirectory(prefix='AES-PanelPackage-') as temporary:
            root = Path(temporary)
            version = (ROOT / 'VERSION').read_text().strip()
            panel = package.build(ROOT, root, version, 'panel')
            with ZipFile(panel['archive']) as bundle:
                names = {name.removeprefix('AppleEmojiSwitcher-Panel/') for name in bundle.namelist()}
                self.assertEqual(names, {*package.panel_members(ROOT), 'README.md', 'manifest.sha256'})
                self.assertEqual(sum(n.endswith('.png') for n in names), 3963)
                self.assertNotIn('bin/PanelHook.dll', names)
                self.assertFalse(any('python' in name.lower() or 'builder/' in name or 'fonts.lock' in name for name in names))
                gui = package.package_members(ROOT, 'gui')
                for name in package.PANEL_SHARED:
                    self.assertEqual(bundle.read('AppleEmojiSwitcher-Panel/' + name), gui[name])

    def test_analysis_artifacts_are_not_shipped(self):
        with tempfile.TemporaryDirectory(prefix='AES-PackageAnalysis-') as temporary:
            root = Path(temporary)
            for name, content in package.package_members(ROOT, 'gui').items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            import shutil
            shutil.copytree(ROOT / 'picker/data', root / 'picker/data', dirs_exist_ok=True)
            analysis = root / 'native/panel/.analysis/local-process.json'
            analysis.parent.mkdir(parents=True)
            analysis.write_text('{"machineOnly":true}')
            self.assertNotIn('native/panel/.analysis/local-process.json',
                             package.package_members(root, 'gui'))

    def test_cli_is_minimal_and_uses_same_core(self):
        with tempfile.TemporaryDirectory(prefix='AES-Packages-') as temporary:
            directory = Path(temporary)
            version = (ROOT / 'VERSION').read_text().strip()
            cli = package.build(ROOT, directory, version, 'cli')
            gui = package.build(ROOT, directory, version, 'gui')
            self.assertLessEqual(cli['bytes'], 64 * 1024)
            self.assertLess(cli['bytes'], gui['bytes'])
            with ZipFile(cli['archive']) as c, ZipFile(gui['archive']) as g:
                names = {str(Path(n).relative_to('AppleEmojiSwitcher-CLI')).replace('\\', '/') for n in c.namelist()}
                self.assertEqual(names, {'aes.cmd', 'AppleEmojiSwitcher.Cli.ps1', 'VERSION', 'README.md',
                                         'fonts.lock.json', 'manifest.sha256', *package.CLI_SHARED})
                for name in package.CLI_SHARED:
                    self.assertEqual(c.read('AppleEmojiSwitcher-CLI/' + name), g.read('AppleEmojiSwitcher/' + name))
                lock = json.loads(c.read('AppleEmojiSwitcher-CLI/fonts.lock.json'))
                self.assertEqual(set(lock), {'version', 'font'})
                self.assertEqual(lock['font'], json.loads((ROOT / 'fonts.lock.json').read_text())['font'])
                for bundle, prefix in ((c, 'AppleEmojiSwitcher-CLI/'), (g, 'AppleEmojiSwitcher/')):
                    for line in bundle.read(prefix + 'manifest.sha256').decode().splitlines():
                        digest, name = line.split('  ', 1)
                        self.assertEqual(hashlib.sha256(bundle.read(prefix + name)).hexdigest(), digest)
            self.assertEqual(cli['sha256'], package.build(ROOT, directory, version, 'cli')['sha256'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
