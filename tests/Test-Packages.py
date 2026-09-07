"""Verify both portable variants using only the Python standard library."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('aes_package', ROOT / 'scripts/package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PortablePackages(unittest.TestCase):
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
