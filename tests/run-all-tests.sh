#!/bin/zsh
set -eu
cd "${0:A:h:h}"
./tests/run-lifecycle-tests.sh
./tests/run-window-preparation-tests.sh
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macosx13.0" Setup.swift LifecycleCore.swift PhoneBridge.swift tests/PhoneBridgeCryptoTests.swift -o "$TEST_DIR/phone-tests" -framework Cocoa -framework Vision -framework ScreenCaptureKit -framework ApplicationServices
"$TEST_DIR/phone-tests"
swiftc -O tests/PlayerTests.swift -parse-as-library -o "$TEST_DIR/player-tests" -framework JavaScriptCore
"$TEST_DIR/player-tests"
swiftc -O -parse-as-library NativeInterface.swift tests/NativeInterfaceTests.swift -o "$TEST_DIR/native-tests" -framework Cocoa
"$TEST_DIR/native-tests"

swiftc -typecheck -target "$(uname -m)-apple-macosx13.0" main.swift Setup.swift PhoneBridge.swift PhonePrompt.swift WindowPreparation.swift WindowRedraw.swift NativeInterface.swift LifecycleCore.swift -framework Cocoa -framework WebKit -framework Vision -framework ScreenCaptureKit -framework ApplicationServices
print 'PASS whole-app typecheck'
swiftc -O -whole-module-optimization -D HARMONY_TESTING -target "$(uname -m)-apple-macosx13.0" main.swift Setup.swift PhoneBridge.swift PhonePrompt.swift WindowPreparation.swift WindowRedraw.swift NativeInterface.swift LifecycleCore.swift tests/AppIntegrationTests.swift -o "$TEST_DIR/app-tests" -framework Cocoa -framework WebKit -framework Vision -framework ScreenCaptureKit -framework ApplicationServices
"$TEST_DIR/app-tests" --supervised
