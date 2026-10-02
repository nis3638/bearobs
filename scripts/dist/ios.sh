#!/bin/bash

# Package the iOS read-only app as a development .ipa for a paired iPhone.
# Signing cannot be automated from a machine with no Apple ID session:
#   1. Log your Apple ID into Xcode (Settings → Accounts);
#   2. Run: DEVELOPMENT_TEAM=<10-char team id> make dist-ios
# A free personal team sideloads to your own devices; builds expire after
# 7 days. Long-lived distribution (TestFlight/App Store) is out of M-iOS scope.

set -euo pipefail
source "$(dirname "$0")/../ci/common.sh"

assert_xcode_version
team="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your 10-char team id (Xcode → Settings → Accounts)}"
version="$(sed -n 's/^MARKETING_VERSION *= *//p' "$ROOT_DIR/Config/App-iOS.xcconfig")"
dist="$ROOT_DIR/out/dist"
mkdir -p "$dist"
archive="$dist/BearObsIOS.xcarchive"

SCHEME="BearObsIOS"
xcodebuild_base \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$archive" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$team" \
    CODE_SIGN_STYLE=Automatic \
    archive

plist="$dist/export-options.plist"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string>$team</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild \
    -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "$plist" \
    -exportPath "$dist" \
    -allowProvisioningUpdates

mv "$dist/BearObs.ipa" "$dist/BearObs-$version-ios.ipa"
echo "iOS package: $dist/BearObs-$version-ios.ipa"
