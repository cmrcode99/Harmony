#!/bin/zsh
set -eu
cd "${0:A:h}"
exec /bin/zsh ./manage-install.sh uninstall "$@"
