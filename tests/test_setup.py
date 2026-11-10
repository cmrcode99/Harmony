#!/usr/bin/env python3
"""Setup preflight must finish before modifying user-selected media."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='harmony-setup-test-')
        self.root = Path(self.temp.name)
        shutil.copy2(ROOT / 'setup.sh', self.root / 'setup.sh')
        (self.root / 'media').mkdir()
        self.playlist = self.root / 'media/playlist.json'
        self.original = json.dumps([{'file': 'video.mp4', 'title': 'Focus', 'startSeconds': 120}])
        self.playlist.write_text(self.original)
        self.video = self.root / 'my new clip.mp4'
        self.video.write_bytes(b'media fixture')
        (self.root / 'build.sh').write_text('#!/bin/zsh\nprint build > build-called\n')
        (self.root / 'build.sh').chmod(0o755)
        commands = self.root / 'commands'
        commands.mkdir()
        for name, body in {'uname': 'print Darwin', 'sw_vers': 'print 26.0',
                           'xcrun': 'if [[ "$*" == *--show-sdk-version* ]]; then print "${TEST_SDK:-26.0}"; fi'}.items():
            target = commands / name
            target.write_text('#!/bin/zsh\n' + body + '\n')
            target.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(commands) + ':' + os.environ['PATH']}

    def tearDown(self):
        self.temp.cleanup()

    def setup(self, *arguments):
        return subprocess.run(['zsh', str(self.root / 'setup.sh'), *map(str, arguments)],
                              env=self.env, capture_output=True, text=True)

    def assert_unmodified(self):
        self.assertEqual(self.playlist.read_text(), self.original)
        self.assertFalse((self.root / 'video.mp4').exists())
        self.assertFalse((self.root / 'build-called').exists())

    def test_check_with_video_is_read_only(self):
        result = self.setup('--check', '--video', self.video)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_unmodified()

    def test_invalid_argument_and_old_sdk_do_not_copy_media(self):
        result = self.setup('--video', self.video, '--unknown')
        self.assertEqual(result.returncode, 2)
        self.assert_unmodified()
        self.env['TEST_SDK'] = '15.0'
        result = self.setup('--video', self.video, '--no-open')
        self.assertNotEqual(result.returncode, 0)
        self.assert_unmodified()

    def test_valid_setup_updates_custom_media_after_preflight(self):
        result = self.setup('--video', self.video, '--no-open')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'video.mp4').read_bytes(), b'media fixture')
        self.assertEqual(json.loads(self.playlist.read_text())[0]['startSeconds'], 0)
        self.assertTrue((self.root / 'build-called').is_file())


if __name__ == '__main__':
    unittest.main()
