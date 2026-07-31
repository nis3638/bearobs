.PHONY: build test coverage check ci spike-grdb spike-markdown clean

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

spike-grdb:
	./scripts/spikes/verify-grdb-fts5.sh

spike-markdown:
	./scripts/spikes/verify-markdown.sh

clean:
	rm -rf .build
