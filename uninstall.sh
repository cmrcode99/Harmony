#!/bin/zsh
set -eu
cd "${0:A:h}"
if [[ "${1-}" == --help || "${1-}" == -h ]]; then
  print 'Usage: ./uninstall.sh [--remove-data]'
  print 'Removes the app, CLI and recovery service. Keeps settings and the phone vault by default.'
  exit 0
fi
exec /bin/zsh ./sharing/manage-install.sh uninstall "$@"
