#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

assert_xcode_version
simulator_id=""
if [[ -n "${CI_DESTINATION:-}" ]]; then
    destination="$CI_DESTINATION"
else
    simulator_id="$(create_simulator)"
    destination="platform=iOS Simulator,id=$simulator_id"
    trap 'xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true' EXIT
fi
result_bundle="$RESULTS_DIR/Coverage.xcresult"
rm -rf "$result_bundle"

xcodebuild_base \
    -configuration Debug \
    -testPlan BearObs \
    -destination "$destination" \
    -destination-timeout 120 \
    -maximum-concurrent-test-simulator-destinations 1 \
    -resultBundlePath "$result_bundle" \
    -enableCodeCoverage YES \
    -only-testing:BearObsTests \
    test

xcrun xccov view --report "$result_bundle" | tee "$REPORTS_DIR/coverage.txt"
xcrun xccov view --report --json "$result_bundle" > "$REPORTS_DIR/coverage.json"
