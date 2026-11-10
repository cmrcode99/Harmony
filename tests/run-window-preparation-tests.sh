#!/bin/zsh
set -eu
cd "${0:A:h:h}"
workdir=$(mktemp -d /tmp/harmony-window-tests.XXXXXX)
trap 'rm -rf "$workdir"' EXIT
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macosx13.0" WindowPreparation.swift tests/WindowPreparationTests.swift -o "$workdir/window-tests" -framework Cocoa -framework ApplicationServices
"$workdir/window-tests"
