#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

assert_xcode_version
if [[ -n "${CI_DESTINATION:-}" ]]; then
    destination="$CI_DESTINATION"
else
    destination="platform=macOS"
fi
result_bundle="$RESULTS_DIR/Tests.xcresult"
rm -rf "$result_bundle"

xcodebuild_base \
    -configuration Debug \
    -testPlan BearObs \
    -destination "$destination" \
    -destination-timeout 120 \
    -resultBundlePath "$result_bundle" \
    test
