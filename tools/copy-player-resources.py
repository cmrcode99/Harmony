#!/usr/bin/env python3
"""Validate a local playlist and bundle the files that are available."""
import json
import math
from pathlib import Path
import shutil
import sys


def available_playlist(root: Path) -> list:
    root = root.resolve()
    playlist = json.loads((root / 'media/playlist.json').read_text())
    if not isinstance(playlist, list) or not playlist:
        raise ValueError('The video playlist is empty or invalid.')
    files, available = set(), []
    for entry in playlist:
        if not isinstance(entry, dict):
            raise ValueError('Each playlist entry must describe a video.')
        name = entry.get('file')
        if not isinstance(name, str) or not isinstance(entry.get('title'), str):
            raise ValueError('Each video needs a file and title.')
        relative = Path(name)
        source = (root / relative).resolve()
        if relative.is_absolute() or '..' in relative.parts or source.suffix.lower() != '.mp4' or not source.is_relative_to(root):
            raise ValueError('Playlist videos must be local MP4 files inside the project.')
        if name in files:
            raise ValueError('Duplicate playlist file: ' + name)
        files.add(name)
        start = entry.get('startSeconds', 0)
        if isinstance(start, bool) or not isinstance(start, (int, float)) or not math.isfinite(start) or start < 0:
            raise ValueError('Video start times must be finite, nonnegative seconds.')
        if not source.exists():
            continue
        if not source.is_file() or source.stat().st_size == 0:
            raise ValueError('Empty or invalid video: ' + name)
        available.append(entry)
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
    if len(sys.argv) != 2:
        raise SystemExit('Usage: copy-player-resources.py DESTINATION | --check')
    try:
        if sys.argv[1] == '--check':
            print(f'{len(available_playlist(Path(__file__).resolve().parents[1]))} local video(s) available.')
        else:
            copy_resources(Path(sys.argv[1]))
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
