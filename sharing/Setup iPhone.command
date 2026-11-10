#!/bin/zsh
set -eu
app="$HOME/Applications/Harmony.app"
if [[ ! -x "$app/Contents/MacOS/HarmonyFocus" ]]; then print -u2 'Install Harmony first.'; exit 1; fi
running=0
"$app/Contents/MacOS/HarmonyFocus" --is-running || running=$?
if (( running == 0 )); then
  print -u2 'Exit Harmony first. During a timed lock, use the eye menu and your long password.'
  exit 1
elif (( running != 1 )); then
  print -u2 'Could not inspect Harmony session state. Nothing was changed.'
  exit 1
fi
/usr/bin/open "$app" --args --configure-phone
