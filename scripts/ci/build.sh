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
