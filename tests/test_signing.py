#!/usr/bin/env python3
"""Source updates preserve an available identity without keychain changes."""
import hashlib
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('harmony_signing', ROOT / 'tools/select-signing-identity.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningSelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='harmony-signing-test-')
        self.app = Path(self.directory.name) / 'Harmony.app'
        self.app.mkdir()
        self.calls = []
        self.certificate = b'public certificate fixture'
        self.fingerprint = hashlib.sha1(self.certificate).hexdigest().upper()
        self.identities = f'  1) {self.fingerprint} "Local identity"\n  1 valid identities found\n'
        self.has_certificate = True
        self.display_ok = True

    def tearDown(self):
        self.directory.cleanup()

    def command(self, arguments):
        self.calls.append(arguments)
        if arguments[0] == '/usr/bin/codesign':
            if self.has_certificate:
                Path(arguments[2].split('=', 1)[1] + '0').write_bytes(self.certificate)
            return subprocess.CompletedProcess(arguments, 0 if self.display_ok else 1, '', '')
        self.assertEqual(arguments, ['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])
        return subprocess.CompletedProcess(arguments, 0, self.identities, '')

    def test_fresh_install_and_explicit_override_do_not_query_keychain(self):
        self.assertEqual(signing.select_identity(command=self.command), '-')
        self.assertEqual(signing.select_identity(self.app / 'missing', command=self.command), '-')
        self.assertEqual(signing.select_identity(self.app, 'Chosen identity', self.command), 'Chosen identity')
        self.assertEqual(signing.select_identity(self.app, '-', self.command), '-')
        self.assertEqual(self.calls, [])

    def test_update_reuses_exact_available_certificate(self):
        self.assertEqual(signing.select_identity(self.app, command=self.command), self.fingerprint)
        self.assertEqual(len(self.calls), 2)
        self.assertFalse(Path(self.calls[0][2].split('=', 1)[1] + '0').exists(), 'temporary public certificate should be removed')

    def test_ad_hoc_update_does_not_query_keychain(self):
        self.has_certificate = False
        self.assertEqual(signing.select_identity(self.app, command=self.command), '-')
        self.assertEqual(len(self.calls), 1)

    def test_missing_identity_stops_before_replacing_the_app(self):
        self.identities = '  0 valid identities found\n'
        with self.assertRaisesRegex(ValueError, 'HARMONY_SIGN_IDENTITY=-'):
            signing.select_identity(self.app, command=self.command)
        self.assertTrue(self.app.exists())

    def test_invalid_installed_signature_is_not_silently_replaced(self):
        self.display_ok = False
        with self.assertRaisesRegex(ValueError, 'left unchanged'):
            signing.select_identity(self.app, command=self.command)
        self.assertEqual(len(self.calls), 1)

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'macOS signing tools required')
    def test_real_ad_hoc_signature_selects_ad_hoc_without_security_call(self):
        source = Path(self.directory.name) / 'fixture.c'
        binary = Path(self.directory.name) / 'fixture'
        source.write_text('int main(void) { return 0; }\n')
        subprocess.run(['clang', str(source), '-o', str(binary)], check=True, capture_output=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(binary)], check=True, capture_output=True)
        self.assertEqual(signing.select_identity(binary), '-')


if __name__ == '__main__':
    unittest.main()
