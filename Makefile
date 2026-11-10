.PHONY: check test build setup share
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
