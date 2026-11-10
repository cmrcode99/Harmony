#!/usr/bin/env python3
"""Fresh-checkout media, install preflight, and release privacy checks."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


resources = load('resources', 'copy-player-resources.py')
release = load('release', 'check-release.py')


class ResourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'media').mkdir()
        (self.root / 'player.html').write_text('<video></video>')
        self.entries = [{'file': 'video.mp4', 'title': 'Focus', 'startSeconds': 0},
                        {'file': 'media/optional.mp4', 'title': 'Optional', 'startSeconds': 120}]
        self.save()

    def tearDown(self):
        self.temp.cleanup()

    def save(self):
        (self.root / 'media/playlist.json').write_text(json.dumps(self.entries))

    def test_missing_media_has_actionable_setup_message(self):
        with self.assertRaisesRegex(FileNotFoundError, 'setup.sh --video'):
            resources.available_playlist(self.root)

    def test_one_video_is_enough_and_missing_optional_is_not_bundled(self):
        (self.root / 'video.mp4').write_bytes(b'local fixture')
        target = self.root / 'output'
        resources.copy_resources(target, self.root)
        self.assertEqual((target / 'video.mp4').read_bytes(), b'local fixture')
        self.assertFalse((target / 'media/optional.mp4').exists())
        self.assertIn('window.harmonyPlaylist', (target / 'playlist.js').read_text())
        self.assertNotIn('optional.mp4', (target / 'playlist.js').read_text())

    def test_invalid_paths_duplicates_and_trim_rejected(self):
        for entry in [{'file': '../outside.mp4', 'title': 'bad'},
                      {'file': '/tmp/outside.mp4', 'title': 'bad'},
                      {'file': 'video.mp4', 'title': 'bad', 'startSeconds': -1},
                      {'file': 'video.mp4', 'title': 'bad', 'startSeconds': True}]:
            with self.subTest(entry=entry):
                self.entries = [entry]
                self.save()
                with self.assertRaises(ValueError):
                    resources.available_playlist(self.root)
        self.entries = [{'file': 'video.mp4', 'title': 'one'}, {'file': 'video.mp4', 'title': 'two'}]
        self.save()
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            resources.available_playlist(self.root)

    def test_setup_check_is_read_only_and_custom_video_has_no_intro_trim(self):
        (self.root / 'tools').mkdir()
        shutil.copy2(ROOT / 'setup.sh', self.root / 'setup.sh')
        shutil.copy2(ROOT / 'tools/copy-player-resources.py', self.root / 'tools/copy-player-resources.py')
        video = self.root / 'my clip.mp4'
        video.write_bytes(b'fixture')
        missing = subprocess.run(['zsh', str(self.root / 'setup.sh'), '--check'], capture_output=True, text=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('setup.sh --video', missing.stderr)
        result = subprocess.run(['zsh', str(self.root / 'setup.sh'), '--video', str(video), '--check'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'video.mp4').read_bytes(), b'fixture')
        entry = json.loads((self.root / 'media/playlist.json').read_text())[0]
        self.assertEqual(entry['startSeconds'], 0)
        self.assertFalse((self.root / 'Applications').exists())

    def test_release_rejects_private_files_and_embedded_digest(self):
        (self.root / 'configuration.json').write_text('{}')
        digest = 'a' * 64
        (self.root / 'main.swift').write_text('let unlockDigest = "' + digest + '"')
        failures = release.check(self.root)
        self.assertEqual(len(failures), 2)
        self.assertTrue(any('embedded password hash' in problem for problem in failures))


if __name__ == '__main__':
    unittest.main()
