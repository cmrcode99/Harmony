#!/usr/bin/env python3
"""Privacy gates and deterministic release publication; no app is installed."""
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('harmony_release', ROOT / 'tools/check-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='harmony-release-test-')
        self.root = Path(self.temporary.name)
        self.package = self.root / 'Harmony'
        self.package.mkdir()
        (self.package / 'readme.txt').write_text('Harmony\n')
        script = self.package / 'Install.command'
        script.write_text('#!/bin/zsh\nexit 0\n')
        script.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    def test_private_files_in_assets_are_not_ignored(self):
        directory = self.package / 'assets'
        directory.mkdir()
        (directory / 'phone-vault.json').write_text('{}')
        self.assertTrue(any('phone-vault.json' in item for item in release.check(self.package)))

    def test_all_symlinks_are_reported_without_reading_targets(self):
        secret = self.root / 'outside'
        secret.mkdir()
        (secret / 'private.txt').write_text('not part of the package')
        (self.package / 'linked-directory').symlink_to(secret, target_is_directory=True)
        (self.package / 'broken').symlink_to(self.root / 'missing')
        findings = release.check(self.package)
        self.assertEqual(len(findings), 2)
        self.assertTrue(all('symlink' in item for item in findings))
        self.assertFalse(any('private.txt' in item for item in findings))

    def test_source_skips_build_caches_but_package_rejects_them(self):
        directory = self.package / 'dist'
        directory.mkdir()
        (directory / 'configuration.json').write_text('{}')
        self.assertEqual(release.check(self.package, 'source'), [])
        self.assertEqual(release.check(self.package, 'package'), ['dist: repository/build metadata in package'])

    def test_force_tracked_generated_files_do_not_bypass_source_gate(self):
        subprocess.run(['git', 'init', '-q', str(self.package)], check=True)
        directory = self.package / 'dist'
        directory.mkdir()
        (directory / 'configuration.json').write_text('{}')
        subprocess.run(['git', '-C', str(self.package), 'add', '-f', 'dist/configuration.json'], check=True)
        self.assertEqual(release.check(self.package), ['dist: generated metadata is tracked in source'])

    def test_private_types_are_rejected_but_example_env_is_allowed(self):
        for name in ['.env', '.env.local', 'key.pem', 'identity.p12', 'signing.keychain-db']:
            (self.package / name).write_text('placeholder')
        (self.package / '.env.example').write_text('EXAMPLE=')
        findings = release.check(self.package)
        self.assertEqual(len(findings), 5)
        self.assertFalse(any('.env.example' in item for item in findings))

    def test_archive_is_deterministic_and_preserves_executability(self):
        one, two = self.root / 'one.zip', self.root / 'two.zip'
        checksum = release.write_archive(self.package, one)
        os.utime(self.package / 'readme.txt', (1800000000, 1800000000))
        release.write_archive(self.package, two)
        self.assertEqual(one.read_bytes(), two.read_bytes())
        self.assertEqual(checksum.read_text(), hashlib.sha256(one.read_bytes()).hexdigest() + '  one.zip\n')
        with zipfile.ZipFile(one) as archive:
            self.assertEqual(archive.namelist(), ['Harmony/', 'Harmony/Install.command', 'Harmony/readme.txt'])
            self.assertEqual(archive.getinfo('Harmony/Install.command').external_attr >> 16 & 0o777, 0o755)
            self.assertEqual(archive.getinfo('Harmony/readme.txt').date_time, (1980, 1, 1, 0, 0, 0))

    def test_archive_refuses_overwrite_and_output_inside_package(self):
        destination = self.root / 'release.zip'
        destination.write_bytes(b'existing release')
        with self.assertRaises(FileExistsError):
            release.write_archive(self.package, destination)
        self.assertEqual(destination.read_bytes(), b'existing release')
        with self.assertRaisesRegex(ValueError, 'outside'):
            release.write_archive(self.package, self.package / 'release.zip')
        self.assertFalse((self.package / 'release.zip').exists())

    def test_archive_does_not_publish_after_privacy_failure(self):
        (self.package / 'configuration.json').write_text('{}')
        destination = self.root / 'release.zip'
        with self.assertRaises(ValueError):
            release.write_archive(self.package, destination)
        self.assertFalse(destination.exists())
        self.assertFalse(destination.with_name('release.zip.sha256').exists())
        self.assertEqual(list(self.root.glob('.harmony-*')), [])

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'macOS signing tools required')
    def test_package_script_builds_checked_versioned_archive_without_overwrite(self):
        source = self.root / 'source'
        for name in ['tools', 'sharing', 'bin']:
            (source / name).mkdir(parents=True, exist_ok=True)
        for name in ['package.sh', 'check-release.py']:
            shutil.copy2(ROOT / 'tools' / name, source / 'tools' / name)
        shutil.copy2(ROOT / 'Info.plist', source / 'Info.plist')
        (source / 'LICENSE').write_text('Test license fixture\n')
        (source / 'bin/harmony').write_text('#!/bin/zsh\nexit 0\n')
        (source / 'sharing/Install Harmony.command').write_text('#!/bin/zsh\nexit 0\n')
        (source / 'fixture.c').write_text('int main(void) { return 0; }\n')
        build = source / 'build.sh'
        build.write_text("""#!/bin/zsh
set -eu
[[ $1 == --stage-only ]]
print build >> build-called
mkdir -p "$2/Contents/MacOS"
cp Info.plist "$2/Contents/Info.plist"
xcrun clang -target "$HARMONY_ARCH-apple-macos13.0" fixture.c -o "$2/Contents/MacOS/HarmonyFocus"
codesign --force --sign - "$2"
""")
        build.chmod(0o755)
        environment = {**os.environ, 'HARMONY_ARCH': os.uname().machine, 'SOURCE_DATE_EPOCH': '315532800'}
        first = subprocess.run(['./tools/package.sh'], cwd=source, env=environment, capture_output=True, text=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        artifacts = list((source / 'dist').glob('Harmony-*-*.zip'))
        self.assertEqual(len(artifacts), 1)
        original = artifacts[0].read_bytes()
        with zipfile.ZipFile(artifacts[0]) as archive:
            self.assertEqual(archive.read('Harmony/LICENSE'), b'Test license fixture\n')
            self.assertIn('Harmony/Harmony.app/Contents/MacOS/HarmonyFocus', archive.namelist())
        second = subprocess.run(['./tools/package.sh'], cwd=source, env=environment, capture_output=True, text=True)
        self.assertNotEqual(second.returncode, 0)
        self.assertIn('already exists', second.stderr)
        self.assertEqual(artifacts[0].read_bytes(), original)
        self.assertEqual((source / 'build-called').read_text().splitlines(), ['build'])

    def test_package_script_checks_architecture_before_building(self):
        script_root = self.root / 'source'
        (script_root / 'tools').mkdir(parents=True)
        shutil.copy2(ROOT / 'tools/package.sh', script_root / 'tools/package.sh')
        result = subprocess.run(['zsh', str(script_root / 'tools/package.sh')],
                                env={**os.environ, 'HARMONY_ARCH': '../../invalid'},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('HARMONY_ARCH must be', result.stderr)
        self.assertFalse((script_root / 'dist').exists())


if __name__ == '__main__':
    unittest.main()
