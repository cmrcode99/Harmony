#!/bin/zsh
set -eu
cd "${0:A:h}"
if /usr/bin/pgrep -x HarmonyFocus >/dev/null; then
  print 'Quit your existing Harmony session first. Timed sessions must be exited from the eye menu with their password.'; exit 1
fi
source_app="$PWD/Harmony.app"
destination="$HOME/Applications/Harmony.app"
/usr/bin/codesign --verify --deep --strict "$source_app"
mkdir -p "$HOME/Applications" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
"$source_app/Contents/MacOS/HarmonyFocus" --install-app
install -m 755 "$PWD/harmony" "$HOME/.local/bin/harmony"
if ! /usr/bin/grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.zshrc" 2>/dev/null; then
  cat >> "$HOME/.zshrc" <<'PATHSETUP'

# Harmony CLI
export PATH="$HOME/.local/bin:$PATH"
PATHSETUP
fi
agent="$HOME/Library/LaunchAgents/local.harmony.focus.supervisor.plist"
/usr/bin/plutil -create xml1 "$agent.tmp"
/usr/bin/plutil -insert Label -string local.harmony.focus.supervisor "$agent.tmp"
/usr/bin/plutil -insert ProgramArguments -xml '<array/>' "$agent.tmp"
/usr/bin/plutil -insert ProgramArguments.0 -string "$destination/Contents/MacOS/HarmonyFocus" "$agent.tmp"
/usr/bin/plutil -insert ProgramArguments.1 -xml '<string>--supervised</string>' "$agent.tmp"
/usr/bin/plutil -insert RunAtLoad -bool YES "$agent.tmp"
/usr/bin/plutil -insert KeepAlive -xml '<dict><key>SuccessfulExit</key><false/></dict>' "$agent.tmp"
/usr/bin/plutil -insert ThrottleInterval -integer 3 "$agent.tmp"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$agent.tmp"
launchctl bootout "gui/$(id -u)/local.harmony.focus.supervisor" >/dev/null 2>&1 || true
mv "$agent.tmp" "$agent"
launchctl bootstrap "gui/$(id -u)" "$agent"
open "$destination" --args --configure-only
print 'Installed. Complete the setup window, then open a new terminal to use harmony.'
print 'See START HERE.txt for macOS permissions and the optional phone helper.'
