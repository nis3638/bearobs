#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

assert_xcode_version

# M-iOS (REQ-004 / ADR-010): the BearObsIOS scheme runs the shared core on an
# iOS simulator through BearObsIOSTests (hosted in the read-only app) and the
# read-only smoke UI flow through BearObsIOSUITests. CI_IOS_SIMULATOR keeps
# accepting the historical iPhone override. The family-specific overrides
# accept either an exact device name or a UDID. CI_IOS_RUNTIME optionally pins
# both destinations to an installed runtime, for example 26.0.
phone_selector="${CI_IOS_PHONE_SIMULATOR:-${CI_IOS_SIMULATOR:-}}"
phone_id="$(
    CI_IOS_SIMULATOR="$phone_selector" \
        "$ROOT_DIR/scripts/verify_ios_app.sh" iphone
)"
ipad_id="$(
    CI_IOS_SIMULATOR="${CI_IOS_IPAD_SIMULATOR:-}" \
        "$ROOT_DIR/scripts/verify_ios_app.sh" ipad
)"
phone_destination="platform=iOS Simulator,id=$phone_id"
ipad_destination="platform=iOS Simulator,id=$ipad_id"
echo "iPhone test destination: $phone_id"
echo "iPad test destination: $ipad_id"
{
    echo "runtime constraint: ${CI_IOS_RUNTIME:-any installed iOS runtime}"
    echo "iPhone destination: $phone_destination"
    echo "iPad destination: $ipad_destination"
} | tee "$REPORTS_DIR/ios-destinations.txt"

SCHEME="BearObsIOS"
phone_bundle="$RESULTS_DIR/iOS-All.xcresult"
rm -rf "$phone_bundle"
phone_test_status=0
xcodebuild_base \
    -configuration Debug \
    -destination "$phone_destination" \
    -destination-timeout 120 \
    -resultBundlePath "$phone_bundle" \
    -enableCodeCoverage YES \
    test || phone_test_status=$?

coverage_text="$REPORTS_DIR/coverage-ios.txt"
coverage_json="$REPORTS_DIR/coverage-ios.json"
coverage_archive_json="$REPORTS_DIR/coverage-ios-archive.json"
changed_files="$REPORTS_DIR/coverage-ios-changed-files.txt"
coverage_base="${COVERAGE_BASE_REF:-}"
if [[ -n "$coverage_base" && ! "$coverage_base" =~ ^0+$ ]]; then
    if ! git -C "$ROOT_DIR" cat-file -e "$coverage_base^{commit}"; then
        echo "Coverage base commit is unavailable: $coverage_base" >&2
        echo "Use a full checkout or unset COVERAGE_BASE_REF for a local working-tree run." >&2
        exit 1
    fi
    git -C "$ROOT_DIR" diff --name-only --diff-filter=AM \
        "$coverage_base...HEAD" -- BearObs \
        | awk '/\.swift$/' \
        | LC_ALL=C sort -u \
        > "$changed_files"
else
    {
        git -C "$ROOT_DIR" diff --name-only --diff-filter=AM HEAD -- BearObs
        git -C "$ROOT_DIR" ls-files --others --exclude-standard -- BearObs
    } \
        | awk '/\.swift$/' \
        | LC_ALL=C sort -u \
        > "$changed_files"
fi

coverage_status=0
coverage_ready=true
if ! xcrun xccov view --report "$phone_bundle" | tee "$coverage_text"; then
    coverage_status=1
    coverage_ready=false
fi
if ! xcrun xccov view --report --json "$phone_bundle" > "$coverage_json"; then
    coverage_status=1
    coverage_ready=false
fi
if ! xcrun xccov view --archive --json "$phone_bundle" > "$coverage_archive_json"; then
    coverage_status=1
    coverage_ready=false
fi
if [[ "$coverage_ready" == true ]]; then
    if ! "$ROOT_DIR/scripts/ci/verify-ios-coverage.sh" \
        "$coverage_json" \
        "$coverage_archive_json" \
        "$changed_files" \
        80 \
        | tee "$REPORTS_DIR/coverage-ios-gate.txt"; then
        coverage_status=1
    fi
else
    echo "iOS coverage could not be exported from $phone_bundle." >&2
fi

# A full-screen iPad provides the regular-width launch gate. Existing compact
# tab-bar UI tests are intentionally not replayed here: they assert the iPhone
# shell and would be a false iPad test. XCTest/xcodebuild/simctl expose no stable
# API for fixing an app to Split View compact width, so that width remains an
# explicit manual release check until the app gains a test-only size-class seam.
ipad_bundle="$RESULTS_DIR/iOS-iPad-Regular.xcresult"
rm -rf "$ipad_bundle"
ipad_test_status=0
xcodebuild_base \
    -configuration Debug \
    -destination "$ipad_destination" \
    -destination-timeout 120 \
    -resultBundlePath "$ipad_bundle" \
    -only-testing:BearObsIOSUITests/BearObsIOSUITests/testLibraryEmptyStateLaunches \
    test || ipad_test_status=$?

ipad_app="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/BearObs.app"
ipad_launch_status=0
launch_output="not attempted"
if [[ ! -d "$ipad_app" ]]; then
    echo "Built iPad app not found: $ipad_app" >&2
    ipad_launch_status=1
else
    xcrun simctl boot "$ipad_id" >/dev/null 2>&1 || true
    if ! xcrun simctl bootstatus "$ipad_id" -b; then
        ipad_launch_status=1
    elif ! xcrun simctl install "$ipad_id" "$ipad_app"; then
        ipad_launch_status=1
    elif ! launch_output="$(xcrun simctl launch "$ipad_id" com.ivows.bearobs.ios)"; then
        ipad_launch_status=1
    fi
    xcrun simctl terminate "$ipad_id" com.ivows.bearobs.ios >/dev/null 2>&1 || true
fi

if [[ "$ipad_test_status" -eq 0 && "$ipad_launch_status" -eq 0 ]]; then
    ipad_gate_result="passed"
else
    ipad_gate_result="failed (test=$ipad_test_status, launch=$ipad_launch_status)"
fi
{
    echo "iPad regular-width build/test/launch gate: $ipad_gate_result"
    echo "destination: $ipad_destination"
    echo "launch: $launch_output"
    echo "LIMITATION: Split View compact width is not fixed by XCTest/xcodebuild/simctl; manual release evidence is still required."
} | tee "$REPORTS_DIR/ios-ipad-layout-gate.txt"

overall_status=0
if [[ "$phone_test_status" -ne 0 ]]; then
    echo "iPhone test gate failed with status $phone_test_status." >&2
    overall_status=1
fi
if [[ "$coverage_status" -ne 0 ]]; then
    echo "iOS coverage gate failed." >&2
    overall_status=1
fi
if [[ "$ipad_test_status" -ne 0 || "$ipad_launch_status" -ne 0 ]]; then
    echo "iPad regular-width build/test/launch gate failed." >&2
    overall_status=1
fi
exit "$overall_status"
