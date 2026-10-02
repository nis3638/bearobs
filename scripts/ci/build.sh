#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

assert_xcode_version

xcodebuild_base \
    -configuration Debug \
    -destination "generic/platform=macOS" \
    CODE_SIGNING_ALLOWED=NO \
    build

xcodebuild_base \
    -configuration Release \
    -destination "generic/platform=macOS" \
    CODE_SIGNING_ALLOWED=NO \
    build

# M-iOS (REQ-004 / ADR-010): the iOS read-only app must keep compiling for the
# simulator alongside every macOS change.
SCHEME="BearObsIOS"
xcodebuild_base \
    -configuration Debug \
    -destination "generic/platform=iOS Simulator" \
    CODE_SIGNING_ALLOWED=NO \
    build

xcodebuild_base \
    -configuration Release \
    -destination "generic/platform=iOS Simulator" \
    CODE_SIGNING_ALLOWED=NO \
    build
