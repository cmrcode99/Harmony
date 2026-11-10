import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('default_videos', ROOT / 'tools/fetch-default-videos.py')
downloads = importlib.util.module_from_spec(spec)
spec.loader.exec_module(downloads)


class DefaultVideoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'media').mkdir()
        self.data = b'default video fixture'
        self.entry = {'file': 'media/focus.mp4',
                      'url': 'https://github.com/cmrcode99/Harmony/releases/download/default-videos-v1/focus.mp4',
                      'bytes': len(self.data), 'sha256': hashlib.sha256(self.data).hexdigest()}

    def manifest(self, entries):
        (self.root / 'media/default-videos.json').write_text(json.dumps(entries))

    def fetch(self, data):
        return downloads.fetch_one(self.root, self.entry, opener=lambda *args, **kwargs: io.BytesIO(data))

    def test_verified_file_is_published_and_temporary_removed(self):
        self.assertTrue(self.fetch(self.data))
        self.assertEqual((self.root / self.entry['file']).read_bytes(), self.data)
        self.assertEqual(list((self.root / 'media').glob('.harmony-video-*')), [])

    def test_existing_user_video_is_not_overwritten_or_downloaded(self):
        target = self.root / self.entry['file']
        target.write_bytes(b'my own video')
        def forbidden(*args, **kwargs):
            self.fail('Existing videos must not trigger a request')
        self.assertFalse(downloads.fetch_one(self.root, self.entry, opener=forbidden))
        self.assertEqual(target.read_bytes(), b'my own video')

    def test_corrupt_truncated_or_oversized_download_never_publishes(self):
        for data in [b'wrong hash of same!!!', self.data[:-1], self.data + b'extra']:
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    self.fetch(data)
                self.assertFalse((self.root / self.entry['file']).exists())
                self.assertEqual(list((self.root / 'media').glob('.harmony-video-*')), [])

    def test_interrupted_download_is_clean_and_retry_succeeds(self):
        class Broken(io.BytesIO):
            def read(self, size=-1):
                raise OSError('connection interrupted')
        with self.assertRaises(OSError):
            downloads.fetch_one(self.root, self.entry, opener=lambda *args, **kwargs: Broken())
        self.assertFalse((self.root / self.entry['file']).exists())
        self.assertTrue(self.fetch(self.data))

    def test_manifest_rejects_escape_urls_duplicates_and_bad_hashes(self):
        for changes in [{'file': '../outside.mp4'}, {'url': 'http://github.com/file'},
                        {'url': 'https://example.com/focus.mp4'}, {'sha256': 'invalid'}]:
            with self.subTest(changes=changes):
                self.manifest([{**self.entry, **changes}])
                with self.assertRaises(ValueError):
                    downloads.entries(self.root)
        self.manifest([self.entry, self.entry])
        with self.assertRaises(ValueError):
            downloads.entries(self.root)

    def test_symlink_target_is_rejected(self):
        outside = self.root / 'outside.mp4'
        outside.write_bytes(b'keep')
        (self.root / self.entry['file']).symlink_to(outside)
        with self.assertRaises(ValueError):
            self.fetch(self.data)
        self.assertEqual(outside.read_bytes(), b'keep')

    def test_release_manifest_matches_default_playlist(self):
        files = {entry['file'] for entry in downloads.entries(ROOT)}
        playlist = json.loads((ROOT / 'media/playlist.json').read_text())
        self.assertEqual(files, {entry['file'] for entry in playlist})


if __name__ == '__main__':
    unittest.main()
