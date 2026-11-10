#!/bin/zsh
set -eu
launcher="$HOME/.local/bin/harmony"
if [[ ! -x "$launcher" ]]; then
  print -u2 'Install Harmony first, then ask your agent to run harmony setup phone.'
  exit 1
fi
exec "$launcher" setup phone
