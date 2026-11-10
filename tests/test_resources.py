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

    def test_empty_bundle_allows_adding_videos_in_the_app(self):
        target = self.root / 'output'
        resources.copy_resources(target, self.root, allow_empty=True)
        self.assertIn('window.harmonyPlaylist = []', (target / 'playlist.js').read_text())
        self.assertTrue((target / 'player.html').is_file())

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
                      {'file': 'video.mp4', 'title': 'bad', 'startSeconds': True},
                      {'file': 'video.mp4', 'title': 'bad', 'startSeconds': 10**1000}]:
            with self.subTest(entry=entry):
                self.entries = [entry]
                self.save()
                with self.assertRaises(ValueError):
                    resources.available_playlist(self.root)
        self.entries = [{'file': 'video.mp4', 'title': 'one'}, {'file': 'video.mp4', 'title': 'two'}]
        self.save()
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            resources.available_playlist(self.root)

    def test_equivalent_paths_and_aliases_cannot_duplicate_a_video(self):
        video = self.root / 'video.mp4'
        video.write_bytes(b'local fixture')
        for alias in ['./video.mp4', 'media/alias.mp4']:
            with self.subTest(alias=alias):
                if alias.startswith('media/'):
                    (self.root / alias).symlink_to(video)
                self.entries = [{'file': 'video.mp4', 'title': 'one'}, {'file': alias, 'title': 'two'}]
                self.save()
                with self.assertRaisesRegex(ValueError, 'Duplicate'):
                    resources.available_playlist(self.root)

    def test_resource_copy_normalizes_paths_without_losing_special_filenames(self):
        name = 'focus #1?100%:ready.mp4'
        (self.root / name).write_bytes(b'local fixture')
        self.entries = [{'file': './' + name, 'title': 'Special name'}]
        self.save()
        target = self.root / 'output'
        resources.copy_resources(target, self.root)
        self.assertEqual((target / name).read_bytes(), b'local fixture')
        bundled = (target / 'playlist.js').read_text()
        self.assertIn(name, bundled)
        self.assertNotIn('./' + name, bundled)

    def test_symlink_cannot_escape_project(self):
        with tempfile.TemporaryDirectory() as directory:
            external = Path(directory) / 'external.mp4'
            external.write_bytes(b'outside fixture')
            (self.root / 'video.mp4').symlink_to(external)
            with self.assertRaisesRegex(ValueError, 'inside the project'):
                resources.available_playlist(self.root)

    def test_playlist_matches_native_track_index_limit(self):
        self.entries = [{'file': f'media/{i}.mp4', 'title': 'Track'} for i in range(1025)]
        self.save()
        with self.assertRaisesRegex(ValueError, '1024'):
            resources.available_playlist(self.root)

    def test_setup_check_with_custom_video_is_read_only(self):
        (self.root / 'tools').mkdir()
        shutil.copy2(ROOT / 'setup.sh', self.root / 'setup.sh')
        shutil.copy2(ROOT / 'tools/copy-player-resources.py', self.root / 'tools/copy-player-resources.py')
        video = self.root / 'my clip.mp4'
        video.write_bytes(b'fixture')
        missing = subprocess.run(['zsh', str(self.root / 'setup.sh'), '--check'], capture_output=True, text=True)
        self.assertEqual(missing.returncode, 0, missing.stderr)
        self.assertIn('0 local video(s)', missing.stdout)
        result = subprocess.run(['zsh', str(self.root / 'setup.sh'), '--video', str(video), '--check'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / 'video.mp4').exists())
        self.assertEqual(json.loads((self.root / 'media/playlist.json').read_text()), self.entries)
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
