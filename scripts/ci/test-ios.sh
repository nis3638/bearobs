#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

assert_xcode_version

# M-iOS (REQ-004 / ADR-010): the BearObsIOS scheme runs the shared core on an
# iOS simulator through BearObsIOSTests (hosted in the read-only app) and the
# read-only smoke UI flow through BearObsIOSUITests. CI_IOS_SIMULATOR
# overrides the concrete simulator device name.
device="${CI_IOS_SIMULATOR:-}"
if [[ -z "$device" ]]; then
    device="$(xcrun simctl list devices available | sed -n 's/^ *\(iPhone[^()]*\) ([^)]*) ([^)]*) *$/\1/p' | head -1 | sed 's/ *$//')"
fi
if [[ -z "$device" ]]; then
    echo "No available iPhone simulator found. Install the iOS simulator runtime." >&2
    exit 1
fi
destination="platform=iOS Simulator,name=$device"
echo "iOS test destination: $device"

SCHEME="BearObsIOS"
bundle="$RESULTS_DIR/iOS-All.xcresult"
rm -rf "$bundle"
xcodebuild_base \
    -configuration Debug \
    -destination "$destination" \
    -destination-timeout 120 \
    -resultBundlePath "$bundle" \
    test
