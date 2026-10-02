#!/bin/bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$root_dir/scripts/ci/verify-ios-deployment.sh"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cat > "$temporary_dir/App-iOS.xcconfig" <<'CONFIG'
IPHONEOS_DEPLOYMENT_TARGET = 26.0
TARGETED_DEVICE_FAMILY = 1,2
CONFIG
cat > "$temporary_dir/Package.swift" <<'PACKAGE'
let package = Package(platforms: [.macOS(.v15), .iOS(.v26)])
PACKAGE

"$verifier" "$temporary_dir/App-iOS.xcconfig" "$temporary_dir/Package.swift"

sed 's/26\.0/26.1/' "$temporary_dir/App-iOS.xcconfig" \
    > "$temporary_dir/App-iOS-invalid.xcconfig"
if "$verifier" "$temporary_dir/App-iOS-invalid.xcconfig" "$temporary_dir/Package.swift" \
    >"$temporary_dir/version.out" 2>"$temporary_dir/version.err"; then
    fail "a deployment target above the supported minimum must fail"
fi
grep -Fq "expected 26.0, found 26.1" "$temporary_dir/version.err" \
    || fail "deployment-target error must show expected and actual versions"

sed 's/\.iOS(\.v26)/.iOS(.v25)/' "$temporary_dir/Package.swift" \
    > "$temporary_dir/Package-invalid.swift"
if "$verifier" "$temporary_dir/App-iOS.xcconfig" "$temporary_dir/Package-invalid.swift" \
    >"$temporary_dir/package.out" 2>"$temporary_dir/package.err"; then
    fail "a Swift package platform below iOS 26 must fail"
fi
grep -Fq "Package.swift must declare .iOS(.v26)" "$temporary_dir/package.err" \
    || fail "package-platform error must state the required declaration"

echo "verify iOS deployment tests passed"
