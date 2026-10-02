#!/bin/bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
xcconfig="${1:-$root_dir/Config/App-iOS.xcconfig}"
package="${2:-$root_dir/Package.swift}"
expected="26.0"

if [[ ! -f "$xcconfig" ]]; then
    echo "iOS app configuration not found: $xcconfig" >&2
    exit 1
fi
if [[ ! -f "$package" ]]; then
    echo "Swift package manifest not found: $package" >&2
    exit 1
fi

actual="$(
    sed -n 's/^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*$/\1/p' \
        "$xcconfig"
)"
if [[ -z "$actual" ]]; then
    echo "IPHONEOS_DEPLOYMENT_TARGET is missing from $xcconfig." >&2
    exit 1
fi
if [[ "$actual" != "$expected" ]]; then
    echo "iOS deployment target drifted: expected $expected, found $actual." >&2
    exit 1
fi

if ! grep -Fq '.iOS(.v26)' "$package"; then
    echo "Package.swift must declare .iOS(.v26) to match the iOS 26.0 app minimum." >&2
    exit 1
fi

echo "iOS deployment target: $actual (Package.swift: .iOS(.v26))"
