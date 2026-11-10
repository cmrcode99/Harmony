#!/bin/zsh
# One entry point for a fresh checkout; never starts focus restrictions.
set -eu
cd "${0:A:h}"
check_only=0
configure=1
while (( $# )); do
  case "$1" in
    --check) check_only=1; shift ;;
    --no-open) configure=0; shift ;;
    --video)
      if (( $# < 2 )) || [[ ! -f "$2" || "${2:e:l}" != mp4 ]]; then
        print -u2 'Use --video /path/to/a-video.mp4'; exit 2
      fi
      video="${2:A}"
      if [[ "$video" != "$PWD/video.mp4" ]]; then cp "$video" video.mp4; fi
      python3 - <<'MEDIA'
import json
from pathlib import Path
path = Path('media/playlist.json')
playlist = json.loads(path.read_text())
playlist[0].update(file='video.mp4', title='My focus video', startSeconds=0)
path.write_text(json.dumps(playlist, indent=2) + '\n')
MEDIA
      shift 2 ;;
    --help|-h)
      print 'Usage: ./setup.sh [--check] [--no-open] [--video /path/to/video.mp4]'
      print 'Checks requirements, builds, installs, and opens first-run setup only.'
      exit 0 ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
  esac
done
if [[ "$(uname -s)" != Darwin ]]; then print -u2 'Harmony requires macOS.'; exit 1; fi
if (( ${$(sw_vers -productVersion)%%.*} < 13 )); then print -u2 'Harmony requires macOS 13 or later.'; exit 1; fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 'Install Apple Command Line Tools with: xcode-select --install'; exit 1
fi
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
if (( ${sdk_version%%.*} < 26 )); then
  print -u2 'Install Xcode 26 or newer Command Line Tools (macOS SDK 26+ is required), then run setup again.'
  exit 1
fi
if ! command -v python3 >/dev/null; then print -u2 'Install Python 3, then run setup again.'; exit 1; fi
python3 tools/copy-player-resources.py --check
print 'Requirements ready: macOS, Swift, Python, local video.'
if (( check_only )); then exit 0; fi
HARMONY_BUILD_ONLY=1 ./build.sh
if (( configure )); then open "$HOME/Applications/Harmony.app" --args --configure-only; fi
print 'Installed Harmony. Complete setup, then run ~/.local/bin/harmony when ready.'
print 'To use harmony by name, add ~/.local/bin to your shell PATH.'
