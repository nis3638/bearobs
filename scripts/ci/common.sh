#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="$ROOT_DIR/BearObs.xcodeproj"
SCHEME="BearObs"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
RESULTS_DIR="$ROOT_DIR/.build/TestResults"
REPORTS_DIR="$ROOT_DIR/.build/reports"
REQUIRED_XCODE_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/.xcode-version")"

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

xcodebuild_base() {
    # 从 GUI 应用（IDE、Agent 宿主）派生的 shell 会继承 __CFBundleIdentifier，
    # 导致 xcodebuild 链路启动的 App 挂到宿主 bundle 上、不创建任何窗口，
    # UI 测试因此全部失败。必须在启动 xcodebuild 前清除。
    unset __CFBundleIdentifier LaunchInstanceID
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -derivedDataPath "$DERIVED_DATA" \
        -disableAutomaticPackageResolution \
        "$@"
}
