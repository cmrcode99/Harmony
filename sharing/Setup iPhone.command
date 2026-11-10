#!/bin/zsh
set -eu
if /usr/bin/pgrep -x HarmonyFocus >/dev/null; then
  print 'Exit Harmony first. During a timed lock, use the eye menu and your long password.'
  exit 1
fi
app="$HOME/Applications/Harmony.app"
if [[ ! -x "$app/Contents/MacOS/HarmonyFocus" ]]; then print 'Install Harmony first.'; exit 1; fi
open "$app" --args --configure-phone
