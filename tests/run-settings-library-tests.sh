#!/bin/zsh
set -eu
cd "${0:A:h:h}"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macosx13.0" SettingsWindow.swift VideoLibrary.swift Setup.swift LifecycleCore.swift PhoneBridge.swift tests/SettingsLibraryRegressionTests.swift -o "$test_dir/settings-library-tests" -framework Cocoa -framework Vision -framework ScreenCaptureKit -framework ApplicationServices
"$test_dir/settings-library-tests"
