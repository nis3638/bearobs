.PHONY: build test coverage check ci verify-jianguoyun-offline verify-jianguoyun-manual spike-grdb spike-markdown spike-atomic-write domain-model clean

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

verify-jianguoyun-offline:
	swift test --package-path Tools/JianguoyunWebDAVVerifier --disable-automatic-resolution

verify-jianguoyun-manual:
	@echo "MANUAL ONLY: accesses real Jianguoyun WebDAV and has remote side effects."
	@echo "The verifier creates, updates, and deletes synthetic resources in the dedicated remote directory."
	swift run --package-path Tools/JianguoyunWebDAVVerifier JianguoyunWebDAVVerifier verify

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
