#!/bin/bash

# Package the macOS app for local distribution (ad-hoc signed).
# For distribution to other Macs, Developer ID signing and notarization are
# required — that gate belongs to M4 (PRD 发布判定), not to local packages.

set -euo pipefail
source "$(dirname "$0")/../ci/common.sh"

assert_xcode_version
version="$(sed -n 's/^MARKETING_VERSION *= *//p' "$ROOT_DIR/Config/App.xcconfig")"
dist="$ROOT_DIR/out/dist"
mkdir -p "$dist"
# Only clear this platform's own products; out/dist may also hold iOS packages.
rm -rf "$dist/BearObs.app" "$dist/BearObs-$version-macOS.zip" "$dist/BearObs-$version-macOS.dmg"

xcodebuild_base \
    -configuration Release \
    -destination "generic/platform=macOS" \
    build

app="$DERIVED_DATA/Build/Products/Release/BearObs.app"
cp -R "$app" "$dist/"
codesign --force --deep --sign - "$dist/BearObs.app"
codesign --verify --deep --strict "$dist/BearObs.app"

(
    cd "$dist" \
        && zip -qry "BearObs-$version-macOS.zip" BearObs.app \
        && hdiutil create -volname BearObs -srcfolder BearObs.app -ov -quiet \
            -format UDZO "BearObs-$version-macOS.dmg"
)

echo "macOS package: $dist/BearObs-$version-macOS.dmg (and .zip / .app)"
