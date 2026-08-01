#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/../ci/common.sh"

assert_xcode_version

SCRATCH_DIR="$ROOT_DIR/.build/M010Domain"
SWIFTPM_CACHE_DIR="$ROOT_DIR/.build/SwiftPMCache"
SWIFTPM_CONFIG_DIR="$ROOT_DIR/.build/SwiftPMConfig"
SWIFTPM_SECURITY_DIR="$ROOT_DIR/.build/SwiftPMSecurity"
SWIFTPM_MODULE_CACHE_DIR="$ROOT_DIR/.build/SwiftPMModuleCache"
CLANG_MODULE_CACHE_DIR="$ROOT_DIR/.build/ClangModuleCache"

export SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_DIR"

run_swift() {
    local subcommand="$1"
    shift
    if [[ "${BEAROBS_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
        swift "$subcommand" --disable-sandbox "$@"
    else
        swift "$subcommand" "$@"
    fi
}

run_swift test \
    --package-path "$ROOT_DIR" \
    --scratch-path "$SCRATCH_DIR" \
    --cache-path "$SWIFTPM_CACHE_DIR" \
    --config-path "$SWIFTPM_CONFIG_DIR" \
    --security-path "$SWIFTPM_SECURITY_DIR" \
    --configuration release

run_swift test \
    --package-path "$ROOT_DIR" \
    --scratch-path "$SCRATCH_DIR" \
    --cache-path "$SWIFTPM_CACHE_DIR" \
    --config-path "$SWIFTPM_CONFIG_DIR" \
    --security-path "$SWIFTPM_SECURITY_DIR" \
    --enable-code-coverage

TEST_BINARY="$(
    find "$SCRATCH_DIR" \
        -path '*/debug/BearObsDomainPackageTests.xctest/Contents/MacOS/BearObsDomainPackageTests' \
        -type f \
        -print \
        -quit
)"
PROFILE_DATA="$(
    find "$SCRATCH_DIR" \
        -path '*/debug/codecov/default.profdata' \
        -type f \
        -print \
        -quit
)"
SOURCE_FILES=("$ROOT_DIR"/BearObs/Domain/*.swift)
if [[ -z "$TEST_BINARY" || -z "$PROFILE_DATA" ]]; then
    echo "M0-10 coverage artifacts were not generated." >&2
    exit 1
fi

COVERAGE_REPORT="$(
    xcrun llvm-cov report \
        "$TEST_BINARY" \
        -instr-profile="$PROFILE_DATA" \
        "${SOURCE_FILES[@]}"
)"
printf '%s\n' "$COVERAGE_REPORT"

REGION_COVERAGE="$(
    awk '$1 == "TOTAL" { gsub("%", "", $4); print $4 }' <<<"$COVERAGE_REPORT"
)"
LINE_COVERAGE="$(
    awk '$1 == "TOTAL" { gsub("%", "", $10); print $10 }' <<<"$COVERAGE_REPORT"
)"
BRANCH_COUNT="$(
    awk '$1 == "TOTAL" { print $11 }' <<<"$COVERAGE_REPORT"
)"
BRANCH_COVERAGE="$(
    awk '$1 == "TOTAL" { gsub("%", "", $13); print $13 }' <<<"$COVERAGE_REPORT"
)"
if ! awk -v coverage="$REGION_COVERAGE" 'BEGIN { exit !(coverage >= 90) }'; then
    echo "M0-10 region coverage ${REGION_COVERAGE}% is below 90%." >&2
    exit 1
fi
if ! awk -v coverage="$LINE_COVERAGE" 'BEGIN { exit !(coverage >= 90) }'; then
    echo "M0-10 line coverage ${LINE_COVERAGE}% is below 90%." >&2
    exit 1
fi
if [[ "$BRANCH_COUNT" -gt 0 ]] \
    && ! awk -v coverage="$BRANCH_COVERAGE" 'BEGIN { exit !(coverage >= 80) }'; then
    echo "M0-10 branch coverage ${BRANCH_COVERAGE}% is below 80%." >&2
    exit 1
fi
if [[ "$BRANCH_COUNT" -eq 0 ]]; then
    echo "M0-10: llvm-cov emitted no Swift branch records; region/matrix gate applies."
fi

SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/SwiftPMModuleCache-iOS" \
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ClangModuleCache-iOS" \
run_swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$SCRATCH_DIR" \
    --cache-path "$SWIFTPM_CACHE_DIR" \
    --config-path "$SWIFTPM_CONFIG_DIR" \
    --security-path "$SWIFTPM_SECURITY_DIR" \
    --configuration release \
    --triple arm64-apple-ios26.0 \
    --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    --target BearObsDomain
