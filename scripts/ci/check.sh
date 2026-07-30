#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/common.sh"

assert_xcode_version

xcrun swift-format lint --strict --recursive \
    "$ROOT_DIR/BearObs" \
    "$ROOT_DIR/BearObsTests" \
    "$ROOT_DIR/BearObsUITests" \
    "$ROOT_DIR/scripts/fixtures/generate-golden-vault-assets.swift" \
    "$ROOT_DIR/scripts/fixtures/verify-golden-vault.swift"

xcrun swift \
    -module-cache-path "$ROOT_DIR/.build/SwiftModuleCache" \
    "$ROOT_DIR/scripts/fixtures/verify-golden-vault.swift"

secret_pattern='(AKIA[0-9A-Z]{16}|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|[Aa]uthorization:[[:space:]]*(Basic|Bearer)[[:space:]]+[A-Za-z0-9._~+/-]{12,})'

if grep -RInE \
    --exclude='Secrets.example.xcconfig' \
    --exclude-dir='.build' \
    --exclude-dir='.git' \
    --exclude='check.sh' \
    "$secret_pattern" \
    "$ROOT_DIR"; then
    echo "Potential hard-coded secret detected." >&2
    exit 1
fi

if find "$ROOT_DIR/BearObs.xcodeproj" -path '*/xcuserdata/*' -print -quit | grep -q .; then
    echo "User-specific Xcode data must not be committed." >&2
    exit 1
fi
