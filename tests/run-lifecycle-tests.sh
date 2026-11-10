#!/bin/zsh
set -eu
cd "${0:A:h:h}"
workdir=$(mktemp -d /tmp/harmony-lifecycle.XXXXXX)
trap 'rm -rf "$workdir"' EXIT
python3 tests/lifecycle/test_cli.py
swiftc -O -whole-module-optimization LifecycleCore.swift tests/lifecycle/main.swift -o "$workdir/lifecycle-tests"
"$workdir/lifecycle-tests"
