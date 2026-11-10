#!/usr/bin/env python3
"""Validate a local playlist and bundle the files that are available."""
import argparse
import json
import math
from pathlib import Path
import shutil
import stat
import sys


def available_playlist(root: Path, video_override: Path = None) -> list:
    root = root.resolve()
    playlist = json.loads((root / 'media/playlist.json').read_text())
    if not isinstance(playlist, list) or not playlist:
        raise ValueError('The video playlist is empty or invalid.')
    if video_override is not None:
        if not isinstance(playlist[0], dict):
            raise ValueError('Each playlist entry must describe a video.')
        playlist[0] = {**playlist[0], 'file': 'video.mp4', 'title': 'My focus video', 'startSeconds': 0}
    if len(playlist) > 1024:
        raise ValueError('The video playlist supports at most 1024 entries.')
    files, identities, available = set(), set(), []
    for index, entry in enumerate(playlist):
        if not isinstance(entry, dict):
            raise ValueError('Each playlist entry must describe a video.')
        name = entry.get('file')
        if not isinstance(name, str) or not isinstance(entry.get('title'), str):
            raise ValueError('Each video needs a file and title.')
        relative = Path(name)
        source = (root / relative).resolve()
        if relative.is_absolute() or '..' in relative.parts or source.suffix.lower() != '.mp4' or not source.is_relative_to(root):
            raise ValueError('Playlist videos must be local MP4 files inside the project.')
        normalized_name = relative.as_posix()
        if normalized_name in files:
            raise ValueError('Duplicate playlist file: ' + name)
        files.add(normalized_name)
        start = entry.get('startSeconds', 0)
        try:
            valid_start = not isinstance(start, bool) and isinstance(start, (int, float)) and math.isfinite(start) and start >= 0
        except OverflowError:
            valid_start = False
        if not valid_start:
            raise ValueError('Video start times must be finite, nonnegative seconds.')
        try:
            metadata = (video_override if index == 0 and video_override is not None else source).stat()
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size == 0:
            raise ValueError('Empty or invalid video: ' + name)
        identity = (metadata.st_dev, metadata.st_ino)
        if identity in identities:
            raise ValueError('Duplicate playlist file: ' + name)
        identities.add(identity)
        available.append({**entry, 'file': normalized_name})
    if not available:
        raise FileNotFoundError('Add a local MP4 with ./setup.sh --video /path/to/video.mp4, or add videos listed in media/playlist.json.')
    return available


def copy_resources(destination: Path, root: Path = None) -> None:
    root = root or Path(__file__).resolve().parents[1]
    playlist = available_playlist(root)
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root / 'player.html', destination / 'player.html')
    for entry in playlist:
        target = destination / entry['file']
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / entry['file'], target)
    (destination / 'playlist.js').write_text('window.harmonyPlaylist = ' + json.dumps(playlist) + ';\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', nargs='?', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--video', type=Path, help='Check an effective first-video replacement without writing it.')
    args = parser.parse_args()
    if args.check == (args.destination is not None) or (args.video is not None and not args.check):
        parser.error('Use DESTINATION, or --check [--video FILE].')
    try:
        if args.check:
            root = Path(__file__).resolve().parents[1]
            print(f'{len(available_playlist(root, video_override=args.video))} local video(s) available.')
        else:
            copy_resources(args.destination)
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
