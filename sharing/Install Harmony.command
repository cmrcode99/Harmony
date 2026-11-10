#!/bin/zsh
set -eu
cd "${0:A:h}"
/bin/zsh ./manage-install.sh install "$PWD/Harmony.app" "$PWD/harmony"
/usr/bin/open "$HOME/Applications/Harmony.app" --args --configure-only
print 'Installed. Complete the setup window, then use ~/.local/bin/harmony.'
print 'Optional: add ~/.local/bin to your shell PATH to use harmony by name.'
