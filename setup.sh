#!/bin/zsh
# One entry point for a fresh checkout; never starts focus restrictions.
set -eu
cd "${0:A:h}"
check_only=0
configure=1
video=''
while (( $# )); do
  case "$1" in
    --check) check_only=1; shift ;;
    --no-open) configure=0; shift ;;
    --video)
      if (( $# < 2 )) || [[ -n "$video" || ! -f "$2" || "${2:e:l}" != mp4 ]]; then
        print -u2 'Use --video /path/to/a-video.mp4 once.'; exit 2
      fi
      video="${2:A}"
      shift 2 ;;
    --help|-h)
      print 'Usage: ./setup.sh [--check] [--no-open] [--video /path/to/video.mp4]'
      print 'Checks requirements, builds, installs, and opens first-run setup only.'
      print '--check validates without changing files or the installed app.'
      exit 0 ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
  esac
done
if [[ "$(uname -s)" != Darwin ]]; then print -u2 'Harmony requires macOS.'; exit 1; fi
if (( ${$(sw_vers -productVersion)%%.*} < 13 )); then print -u2 'Harmony requires macOS 13 or later.'; exit 1; fi
if ! command -v python3 >/dev/null; then print -u2 'Install Python 3, then run setup again.'; exit 1; fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 'Install Apple Command Line Tools with: xcode-select --install'; exit 1
fi
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
if (( ${sdk_version%%.*} < 26 )); then
  print -u2 'Install Xcode 26 or newer Command Line Tools (macOS SDK 26+ is required), then run setup again.'
  exit 1
fi
if [[ -n "$video" ]]; then
  [[ -s "$video" ]] || { print -u2 'The selected video is empty.'; exit 1; }
else
  python3 tools/copy-player-resources.py --check
fi
print 'Requirements ready: macOS, Swift, Python, local video.'
if (( check_only )); then exit 0; fi
if [[ -n "$video" ]]; then
  python3 - "$video" <<'MEDIA'
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

source = Path(sys.argv[1])
path = Path('media/playlist.json')
playlist = json.loads(path.read_text())
if not isinstance(playlist, list) or not playlist or not isinstance(playlist[0], dict):
    raise SystemExit('media/playlist.json needs at least one valid entry.')
playlist[0].update(file='video.mp4', title='My focus video', startSeconds=0)
# Stage complete files beside their destinations before replacing either one.
with tempfile.TemporaryDirectory(prefix='.harmony-media-', dir='.') as directory:
    stage = Path(directory)
    if source.resolve() != Path('video.mp4').resolve():
        shutil.copyfile(source, stage / 'video.mp4')
    (stage / 'playlist.json').write_text(json.dumps(playlist, indent=2) + '\n')
    if (stage / 'video.mp4').exists():
        os.replace(stage / 'video.mp4', 'video.mp4')
    os.replace(stage / 'playlist.json', path)
MEDIA
fi
HARMONY_BUILD_ONLY=1 ./build.sh
if (( configure )); then /usr/bin/open "$HOME/Applications/Harmony.app" --args --configure-only; fi
print 'Installed Harmony. Complete setup, then run ~/.local/bin/harmony when ready.'
print 'To use harmony by name, add ~/.local/bin to your shell PATH.'
