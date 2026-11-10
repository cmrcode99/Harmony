.PHONY: check test build setup share preview-settings
check test:
	python3 -m unittest discover -s tests -p 'test_*.py'
	./tests/run-all-tests.sh
	python3 tools/check-release.py .
build:
	./build.sh
setup:
	./setup.sh
share:
	./tools/package.sh

preview-settings:
	mkdir -p .build
	swiftc -O $(filter-out main.swift,$(wildcard *.swift)) tests/render-settings.swift -o .build/settings-preview -framework Cocoa -framework WebKit -framework Vision -framework ScreenCaptureKit -framework ApplicationServices
	.build/settings-preview .build/settings-preview.png
