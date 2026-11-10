.PHONY: check test build setup share
check test:
	python3 tests/test_resources.py
	./tests/run-all-tests.sh
	./tests/run-setup-tests.sh
	python3 tools/check-release.py .
build:
	./build.sh
setup:
	./setup.sh
share:
	./tools/package.sh
