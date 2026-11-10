#!/bin/zsh
set -eu
cd "${0:A:h:h}"
workdir=$(mktemp -d /tmp/harmony-friend-tests.XXXXXX)
trap 'rm -rf "$workdir"' EXIT
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macosx13.0" Setup.swift PhoneBridge.swift LifecycleCore.swift tests/PhoneBridgeCryptoTests.swift -o "$workdir/tests" -framework Cocoa -framework Vision -framework ScreenCaptureKit -framework ApplicationServices
"$workdir/tests"
swiftc -typecheck -target "$(uname -m)-apple-macosx13.0" main.swift Setup.swift PhoneBridge.swift PhonePrompt.swift WindowPreparation.swift WindowRedraw.swift NativeInterface.swift LifecycleCore.swift -framework Cocoa -framework WebKit -framework Vision -framework ScreenCaptureKit -framework ApplicationServices
for script in sharing/*.command; do zsh -n "$script"; done
