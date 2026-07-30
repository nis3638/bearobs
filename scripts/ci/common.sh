#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="$ROOT_DIR/BearObs.xcodeproj"
SCHEME="BearObs"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
RESULTS_DIR="$ROOT_DIR/.build/TestResults"
REPORTS_DIR="$ROOT_DIR/.build/reports"
REQUIRED_XCODE_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/.xcode-version")"
REQUIRED_IOS_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-${REQUIRED_XCODE_VERSION//./-}"
IOS_DEVICE_TYPE="${CI_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-16}"

mkdir -p "$DERIVED_DATA" "$RESULTS_DIR" "$REPORTS_DIR"

assert_xcode_version() {
    local actual_xcode actual_device_sdk actual_simulator_sdk
    actual_xcode="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
    actual_device_sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
    actual_simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"

    if [[ "$actual_xcode" != "$REQUIRED_XCODE_VERSION" ]]; then
        echo "Expected Xcode $REQUIRED_XCODE_VERSION, found $actual_xcode." >&2
        return 1
    fi

    if [[ "$actual_device_sdk" != "$REQUIRED_XCODE_VERSION" || \
          "$actual_simulator_sdk" != "$REQUIRED_XCODE_VERSION" ]]; then
        echo "Expected iOS SDKs $REQUIRED_XCODE_VERSION; found device $actual_device_sdk and simulator $actual_simulator_sdk." >&2
        return 1
    fi
}

create_simulator() {
    xcrun simctl create "BearObs-CI-$$" "$IOS_DEVICE_TYPE" "$REQUIRED_IOS_RUNTIME"
}

xcodebuild_base() {
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -derivedDataPath "$DERIVED_DATA" \
        -disableAutomaticPackageResolution \
        "$@"
}
