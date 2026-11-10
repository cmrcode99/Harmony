#!/usr/bin/env python3
"""Fetch the default playlist from GitHub, verifying every new file."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlparse
from urllib.request import Request, urlopen


def target_path(root, name):
    relative = Path(name)
    if relative.is_absolute() or '..' in relative.parts or relative.suffix != '.mp4':
        raise ValueError('Default videos must use relative MP4 paths.')
    target = root / relative
    for path in [target, *target.parents]:
        if path == root:
            break
        if path.is_symlink():
            raise ValueError('Default video paths cannot contain symlinks.')
    return target


def entries(root):
    data = json.loads((root / 'media/default-videos.json').read_text())
    if not isinstance(data, list) or not data or len(data) > 32:
        raise ValueError('Invalid default video manifest.')
    seen = set()
    for entry in data:
        if not isinstance(entry, dict):
            raise ValueError('Invalid default video entry.')
        name, url = entry.get('file'), entry.get('url')
        size, digest = entry.get('bytes'), entry.get('sha256')
        if not isinstance(name, str) or name in seen:
            raise ValueError('Default video paths must be unique.')
        target_path(root, name)
        parsed = urlparse(url) if isinstance(url, str) else None
        if not parsed or parsed.scheme != 'https' or parsed.netloc != 'github.com' or not parsed.path.startswith('/cmrcode99/Harmony/releases/download/'):
            raise ValueError('Default video URLs must point to Harmony releases on GitHub.')
        if type(size) is not int or not 0 < size < 2**31 or not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('Default videos need a valid size and SHA-256 hash.')
        seen.add(name)
    return data


def already_present(target):
    if not target.exists():
        return False
    if not target.is_file() or target.stat().st_size == 0:
        raise ValueError(f'{target.name} is empty or is not a regular file; move it before downloading.')
    return True


def fetch_one(root, entry, opener=urlopen):
    target = target_path(root, entry['file'])
    # Existing files may be the user's own videos. Never replace them.
    if already_present(target):
        return False
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.harmony-video-', dir=target.parent)
    temporary = Path(temporary)
    try:
        request = Request(entry['url'], headers={'User-Agent': 'Harmony-Setup', 'Accept': 'application/octet-stream'})
        digest, size = hashlib.sha256(), 0
        with os.fdopen(descriptor, 'wb') as output, opener(request, timeout=30) as source:
            while chunk := source.read(1024 * 1024):
                size += len(chunk)
                if size > entry['bytes']:
                    raise ValueError('The downloaded video is larger than its manifest size.')
                output.write(chunk)
                digest.update(chunk)
        if size != entry['bytes'] or digest.hexdigest() != entry['sha256']:
            raise ValueError(f'Verification failed for {entry["file"]}; no video was installed.')
        temporary.chmod(0o644)
        # Exclusive publication preserves any file added during the download.
        os.link(temporary, target)
        return True
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--check', action='store_true', help='Report missing downloads without changing files or using the network.')
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        videos = entries(root)
        missing = [entry for entry in videos if not already_present(target_path(root, entry['file']))]
        if args.check:
            total = sum(entry['bytes'] for entry in missing) / 1024**2
            print(f'Default videos: {len(missing)} download(s) needed ({total:.0f} MiB).')
            return
        for entry in missing:
            print(f'Downloading {entry["file"]} ({entry["bytes"] / 1024**2:.0f} MiB)…', flush=True)
            fetch_one(root, entry)
        print('Default playlist videos are ready.')
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\nRun setup again to retry, or use --no-default-videos to add your own videos.\n')


if __name__ == '__main__':
    main()
