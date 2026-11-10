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
swiftc -O -whole-module-optimization -target "${HARMONY_ARCH:-$(uname -m)}-apple-macosx13.0" main.swift Setup.swift PhoneBridge.swift PhonePrompt.swift WindowPreparation.swift WindowRedraw.swift NativeInterface.swift LifecycleCore.swift -o "$APP/Contents/MacOS/HarmonyFocus" -framework Cocoa -framework WebKit -framework Vision -framework ScreenCaptureKit -framework ApplicationServices
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
if pgrep -u "$(id -u)" -x HarmonyFocus >/dev/null; then
  print -u2 'Harmony started during the build; install cancelled to protect the running app.'
  exit 1
fi
python3 - "$APP" "$DEST" "$STAGE" <<'INSTALL'
import os,sys,fcntl
source,destination,stage=sys.argv[1:]
# Share the app's singleton lock so launch and replacement cannot overlap.
lock_dir=os.path.expanduser('~/Library/Application Support/Harmony Focus')
os.makedirs(lock_dir, mode=0o700, exist_ok=True)
lock_fd=os.open(os.path.join(lock_dir,'instance.lock'), os.O_CREAT | os.O_RDWR, 0o600)
try: fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: raise SystemExit('Harmony started during the build; installation cancelled.')
backup=os.path.join(stage,'previous.app')
if os.path.exists(destination): os.rename(destination,backup)
try: os.rename(source,destination)
except BaseException:
 if os.path.exists(backup): os.rename(backup,destination)
 raise
INSTALL
python3 - "$DEST" <<'AGENT'
import os,pathlib,plistlib,sys
path=pathlib.Path.home()/'Library/LaunchAgents/local.harmony.focus.supervisor.plist'
path.parent.mkdir(parents=True,exist_ok=True)
record={'Label':'local.harmony.focus.supervisor','ProgramArguments':[sys.argv[1]+'/Contents/MacOS/HarmonyFocus','--supervised'],'RunAtLoad':True,'KeepAlive':{'SuccessfulExit':False},'ThrottleInterval':3,'LimitLoadToSessionType':'Aqua'}
data=plistlib.dumps(record)
if not path.exists() or path.read_bytes()!=data:
 temporary=path.with_suffix('.tmp')
 temporary.write_bytes(data)
 os.replace(temporary,path)
AGENT
if ! launchctl print "gui/$(id -u)/local.harmony.focus.supervisor" >/dev/null 2>&1; then
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.harmony.focus.supervisor.plist"
fi
mkdir -p "$HOME/.local/bin"
install -m 755 bin/harmony "$HOME/.local/bin/harmony"
if [[ "${HARMONY_BUILD_ONLY:-1}" == 0 ]]; then open "$DEST" --args --configure-only; fi
print "Installed Harmony: $DEST"
