#!/bin/zsh
# Harmony installation manager. Shared by source and prebuilt installations.
set -eu
zmodload zsh/system
zmodload zsh/datetime

usage() {
  print 'Usage: manage-install.sh install APP LAUNCHER | uninstall [--remove-data]'
  print 'Install never starts focus mode. Uninstall preserves settings unless --remove-data is given.'
}
fail() { print -u2 -- "$*"; exit 1; }
mode="${1:-}"
[[ "$mode" == --help || "$mode" == -h ]] && { usage; exit 0; }
case "$mode" in
  install) (( $# == 3 )) || { usage >&2; exit 2; } ;;
  uninstall)
    if (( $# != 1 )) && { (( $# != 2 )) || [[ "${2-}" != --remove-data ]]; }; then usage >&2; exit 2; fi ;;
  *) usage >&2; exit 2 ;;
esac
[[ "$(uname -s)" == Darwin ]] || fail 'Harmony requires macOS.'
[[ -n "$HOME" && "$HOME" == /* && "$HOME" != / ]] || fail 'A valid home directory is required.'
applications="$HOME/Applications"
app="$applications/Harmony.app"
cli="$HOME/.local/bin/harmony"
manager="$HOME/.local/lib/harmony/manage-install.sh"
agent="$HOME/Library/LaunchAgents/local.harmony.focus.supervisor.plist"
preferences="$HOME/Library/Preferences/local.harmony.focus.plist"
state="$HOME/Library/Application Support/Harmony Focus"
service="gui/$(id -u)/local.harmony.focus.supervisor"
for install_path in "$HOME/.local" "$HOME/.local/bin" "$HOME/.local/lib" "$HOME/.local/lib/harmony" "$applications" "$HOME/Library/LaunchAgents" "$state" "$state/instance.lock" "$app" "$cli" "$manager" "$agent" "$preferences"; do
  [[ ! -L "$install_path" ]] || fail "Refusing to replace a symbolic link: $install_path"
done
if [[ -e "$app" ]]; then
  identifier=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null) || fail 'The existing Harmony.app has no readable bundle identifier.'
  [[ "$identifier" == local.harmony.focus ]] || fail 'The existing Harmony.app belongs to another application.'
fi
if [[ -e "$cli" ]]; then
  /usr/bin/grep -Fq 'Applications/Harmony.app' "$cli" || fail 'The existing harmony command belongs to another application.'
fi
if [[ -e "$manager" ]]; then
  /usr/bin/grep -Fq '# Harmony installation manager.' "$manager" || fail 'The existing installation manager is not owned by Harmony.'
fi
if [[ -e "$agent" ]]; then
  label=$(/usr/bin/plutil -extract Label raw -o - "$agent" 2>/dev/null) || fail 'The existing recovery service is invalid.'
  [[ "$label" == local.harmony.focus.supervisor ]] || fail 'The recovery service belongs to another application.'
fi

# This is the same BSD flock used by the app. Hold it through the entire swap,
# including service replacement, so another launch cannot race the installer.
mkdir -p "$state"
chmod 700 "$state"
[[ -e "$state/instance.lock" ]] || (umask 077; : > "$state/instance.lock")
if ! zsystem flock -t 0 -f lock_fd "$state/instance.lock" 2>/dev/null; then
  fail 'Harmony is running. Exit it normally before installing or uninstalling.'
fi
if [[ -f "$preferences" ]]; then
  /usr/bin/plutil -lint -s "$preferences" || fail 'Harmony preferences could not be read. Existing installation was left untouched.'
  lock_end=$(/usr/bin/plutil -extract lockEnd raw -o - "$preferences" 2>/dev/null) || lock_end=0
  [[ "$lock_end" =~ '^-?[0-9]+([.][0-9]+)?$' ]] || fail 'The saved session deadline is invalid. Existing installation was left untouched.'
  if (( lock_end > EPOCHSECONDS )); then
    fail 'An unfinished timed session exists. Finish it normally before installing or uninstalling.'
  fi
fi

mkdir -p "$applications"
stage=$(mktemp -d "$applications/.harmony-maintenance.XXXXXX")
old_loaded=0
old_stopped=0
new_loaded=0
committed=0
changed=()
destinations=("$app" "$cli" "$manager" "$agent")
TRAPEXIT() {
  local result=$?
  (( ZSH_SUBSHELL == 0 )) || return $result
  local rollback_failed=0
  if (( ! committed && ${#changed} )); then
    (( ! new_loaded )) || launchctl bootout "$service" >/dev/null 2>&1 || rollback_failed=1
    local index
    for index in ${(Oa)changed}; do
      rm -rf -- "${destinations[$index]}" || rollback_failed=1
      if [[ -e "$stage/backup-$index" ]]; then
        mv -- "$stage/backup-$index" "${destinations[$index]}" || rollback_failed=1
      fi
    done
  fi
  if (( ! committed && old_stopped )); then
    launchctl bootstrap "gui/$(id -u)" "$agent" >/dev/null 2>&1 || rollback_failed=1
  fi
  if (( rollback_failed )); then
    print -u2 "Automatic rollback could not finish. Recovery files remain at: $stage"
  else
    rm -rf -- "$stage"
  fi
  return $result
}

if [[ "$mode" == install ]]; then
  source_app="${2:A}"
  source_cli="${3:A}"
  [[ -d "$source_app" && -f "$source_cli" ]] || fail 'A complete Harmony.app and launcher are required.'
  [[ -x "$source_app/Contents/MacOS/HarmonyFocus" ]] || fail 'Harmony.app is missing its executable.'
  identifier=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$source_app/Contents/Info.plist" 2>/dev/null) || fail 'The source app has no readable bundle identifier.'
  [[ "$identifier" == local.harmony.focus ]] || fail 'The source app is not Harmony.'
  /usr/bin/codesign --verify --deep --strict "$source_app" || fail 'The source app signature is invalid.'
  /usr/bin/ditto "$source_app" "$stage/Harmony.app"
  /usr/bin/codesign --verify --deep --strict "$stage/Harmony.app" || fail 'The copied app signature is invalid.'
  cp -- "$source_cli" "$stage/harmony"
  cp -- "${0:A}" "$stage/manage-install.sh"
  chmod 755 "$stage/harmony" "$stage/manage-install.sh"
  plist="$stage/agent.plist"
  /usr/bin/plutil -create xml1 "$plist"
  /usr/bin/plutil -insert Label -string local.harmony.focus.supervisor "$plist"
  /usr/bin/plutil -insert ProgramArguments -xml '<array/>' "$plist"
  /usr/bin/plutil -insert ProgramArguments.0 -string "$app/Contents/MacOS/HarmonyFocus" "$plist"
  /usr/bin/plutil -insert ProgramArguments.1 -xml '<string>--supervised</string>' "$plist"
  /usr/bin/plutil -insert RunAtLoad -bool YES "$plist"
  /usr/bin/plutil -insert KeepAlive -xml '<dict><key>SuccessfulExit</key><false/></dict>' "$plist"
  /usr/bin/plutil -insert ThrottleInterval -integer 3 "$plist"
  /usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$plist"
  chmod 644 "$plist"
  sources=("$stage/Harmony.app" "$stage/harmony" "$stage/manage-install.sh" "$plist")
  mkdir -p "${cli:h}" "${manager:h}" "${agent:h}"
fi
if launchctl print "$service" >/dev/null 2>&1; then
  old_loaded=1
  launchctl bootout "$service" || fail 'Could not stop the recovery service; nothing was replaced.'
  old_stopped=1
fi
for index in {1..4}; do
  destination="${destinations[$index]}"
  if [[ -e "$destination" ]]; then mv -- "$destination" "$stage/backup-$index"; fi
  changed+=("$index")
  if [[ "$mode" == install ]]; then mv -- "${sources[$index]}" "$destination"; fi
done
if [[ "$mode" == install ]]; then
  launchctl bootstrap "gui/$(id -u)" "$agent" || fail 'Could not register recovery. Restoring the previous installation.'
  new_loaded=1
  committed=1
  print 'Installed Harmony and its recovery service. Focus mode was not started.'
else
  committed=1
  if [[ "${2:-}" == --remove-data ]]; then
    rm -rf -- "$state"
    rm -f -- "$preferences"
    print 'Uninstalled Harmony and removed its saved settings and encrypted phone vault.'
  else
    print 'Uninstalled Harmony. Saved settings and the encrypted phone vault were preserved.'
  fi
fi
