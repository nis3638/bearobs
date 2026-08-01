.PHONY: build test coverage check ci spike-grdb spike-markdown spike-atomic-write domain-model clean

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

spike-atomic-write:
	./scripts/spikes/verify-atomic-write.sh

domain-model:
	./scripts/domain/verify-domain-model.sh

clean:
	rm -rf .build
