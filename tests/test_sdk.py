#!/usr/bin/env python3
"""Builds use an installed SDK the toolchain can compile SwiftUI against."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('harmony_sdk', ROOT / 'tools/select-sdk.py')
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)


class SDKSelectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='harmony-sdk-test-')
        self.sdks = Path(self.directory.name).resolve() / 'SDKs'
        self.sdks.mkdir()
        for name in ('MacOSX15.5.sdk', 'MacOSX26.2.sdk', 'MacOSX26.5.sdk', 'MacOSX27.2.sdk'):
            (self.sdks / name).mkdir()
        (self.sdks / 'MacOSX.sdk').symlink_to('MacOSX27.2.sdk')
        (self.sdks / 'MacOSX26.sdk').symlink_to('MacOSX26.5.sdk')
        self.working = {'MacOSX15.5.sdk', 'MacOSX26.2.sdk', 'MacOSX26.5.sdk', 'MacOSX27.2.sdk'}
        self.has_default = True
        self.probed = []

    def tearDown(self):
        self.directory.cleanup()

    def command(self, arguments):
        if arguments[0] == 'xcrun':
            self.assertEqual(arguments, ['xcrun', '--sdk', 'macosx', '--show-sdk-path'])
            return subprocess.CompletedProcess(arguments, 0 if self.has_default else 1,
                                               f'{self.sdks}/MacOSX.sdk\n' if self.has_default else '', '')
        self.assertEqual(arguments[:3], ['swiftc', '-typecheck', '-sdk'])
        name = Path(arguments[3]).resolve().name
        self.probed.append(name)
        return subprocess.CompletedProcess(arguments, 0 if name in self.working else 1, '', '')

    def test_explicit_sdk_is_used_without_probing(self):
        self.assertEqual(sdk.select_sdk('/chosen/MacOSX.sdk', command=self.command), '/chosen/MacOSX.sdk')
        self.assertEqual(self.probed, [])

    def test_working_default_is_kept(self):
        self.assertEqual(sdk.select_sdk(command=self.command), str(self.sdks / 'MacOSX.sdk'))
        self.assertEqual(self.probed, ['MacOSX27.2.sdk'])

    def test_broken_default_falls_back_to_newest_working_sdk(self):
        self.working.discard('MacOSX27.2.sdk')
        self.assertEqual(sdk.select_sdk(command=self.command), str(self.sdks / 'MacOSX26.5.sdk'))
        self.assertEqual(self.probed, ['MacOSX27.2.sdk', 'MacOSX26.5.sdk'])

    def test_sdks_older_than_the_minimum_are_not_used(self):
        self.working = {'MacOSX15.5.sdk'}
        with self.assertRaisesRegex(ValueError, 'Nothing was built'):
            sdk.select_sdk(command=self.command)
        self.assertNotIn('MacOSX15.5.sdk', self.probed)

    def test_missing_sdk_stops_with_install_guidance(self):
        self.has_default = False
        with self.assertRaisesRegex(ValueError, 'xcode-select --install'):
            sdk.select_sdk(command=self.command)


if __name__ == '__main__':
    unittest.main()
