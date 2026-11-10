#!/bin/zsh
set -eu
cd "${0:A:h}"
DEST="$HOME/Applications/Harmony.app"
stage_only=0
if (( $# == 2 )) && [[ "$1" == --stage-only ]]; then
  stage_only=1
  DEST="${2:A}"
  if [[ -e "$DEST" ]]; then print -u2 'The staging destination already exists; choose a new path.'; exit 1; fi
elif (( $# != 0 )); then
  print -u2 'Usage: ./build.sh [--stage-only /path/to/Harmony.app]'; exit 2
fi
if (( ! stage_only )) && pgrep -u "$(id -u)" -x HarmonyFocus >/dev/null; then
  print -u2 'Exit Harmony before building. An active lock must be unlocked normally.'
  exit 1
fi
if (( stage_only )); then
  STAGE=$(mktemp -d "${TMPDIR:-/tmp}/harmony-build.XXXXXX")
else
  mkdir -p "$HOME/Applications"
  STAGE=$(mktemp -d "$HOME/Applications/.harmony-build.XXXXXX")
fi
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Harmony.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -whole-module-optimization -target "${HARMONY_ARCH:-$(uname -m)}-apple-macosx13.0" *.swift -o "$APP/Contents/MacOS/HarmonyFocus" -framework Cocoa -framework WebKit -framework Vision -framework ScreenCaptureKit -framework ApplicationServices
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
python3 tools/copy-player-resources.py "$APP/Contents/Resources"
if [[ -f assets/Harmony.icns ]]; then
  cp assets/Harmony.icns "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string Harmony' "$APP/Contents/Info.plist"
fi
codesign --force --sign "${HARMONY_SIGN_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
if (( stage_only )); then
  mkdir -p "${DEST:h}"
  ditto "$APP" "$DEST"
  codesign --verify --deep --strict "$DEST"
  print "Staged signed app: $DEST (installed app and active session unchanged)"
  exit 0
fi
./sharing/manage-install.sh install "$APP" "$PWD/bin/harmony"
if [[ "${HARMONY_BUILD_ONLY:-1}" == 0 ]]; then open "$DEST" --args --configure-only; fi
print "Installed Harmony: $DEST"
