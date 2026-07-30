.PHONY: build test coverage check ci clean

build:
	./scripts/ci/build.sh

test:
	./scripts/ci/test.sh

coverage:
	./scripts/ci/coverage.sh

check:
	./scripts/ci/check.sh

ci:
	./scripts/ci/run.sh

clean:
	rm -rf .build
