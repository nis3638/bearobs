#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/../ci/common.sh"

assert_xcode_version

PACKAGE_DIR="$ROOT_DIR/Spikes/M007GRDBFTS5"
SCRATCH_DIR="$ROOT_DIR/.build/M007GRDBFTS5"
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
    --package-path "$PACKAGE_DIR" \
    --scratch-path "$SCRATCH_DIR" \
    --cache-path "$SWIFTPM_CACHE_DIR" \
    --config-path "$SWIFTPM_CONFIG_DIR" \
    --security-path "$SWIFTPM_SECURITY_DIR" \
    --configuration release

run_swift test \
    --package-path "$PACKAGE_DIR" \
    --scratch-path "$SCRATCH_DIR" \
    --cache-path "$SWIFTPM_CACHE_DIR" \
    --config-path "$SWIFTPM_CONFIG_DIR" \
    --security-path "$SWIFTPM_SECURITY_DIR" \
    --enable-code-coverage

TEST_BINARY="$(
    find "$SCRATCH_DIR" \
        -path '*/debug/M007GRDBFTS5PackageTests.xctest/Contents/MacOS/M007GRDBFTS5PackageTests' \
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
SOURCE_FILE="$PACKAGE_DIR/Sources/GRDBFTS5Spike/GRDBFTS5Spike.swift"
if [[ -z "$TEST_BINARY" || -z "$PROFILE_DATA" ]]; then
    echo "M0-07 coverage artifacts were not generated." >&2
    exit 1
fi

COVERAGE_REPORT="$(
    xcrun llvm-cov report \
        "$TEST_BINARY" \
        -instr-profile="$PROFILE_DATA" \
        "$SOURCE_FILE"
)"
printf '%s\n' "$COVERAGE_REPORT"

LINE_COVERAGE="$(
    awk '$1 == "TOTAL" { gsub("%", "", $10); print $10 }' <<<"$COVERAGE_REPORT"
)"
if ! awk -v coverage="$LINE_COVERAGE" 'BEGIN { exit !(coverage >= 80) }'; then
    echo "M0-07 line coverage ${LINE_COVERAGE}% is below 80%." >&2
    exit 1
fi

SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/SwiftPMModuleCache-iOS" \
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ClangModuleCache-iOS" \
run_swift build \
    --package-path "$PACKAGE_DIR" \
    --scratch-path "$SCRATCH_DIR" \
    --cache-path "$SWIFTPM_CACHE_DIR" \
    --config-path "$SWIFTPM_CONFIG_DIR" \
    --security-path "$SWIFTPM_SECURITY_DIR" \
    --configuration release \
    --triple arm64-apple-ios26.0 \
    --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    --target GRDBFTS5Spike
