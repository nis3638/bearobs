#!/bin/bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
selector="$root_dir/scripts/verify_ios_app.sh"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

fake_bin="$temporary_dir/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/xcrun" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
case "$*" in
    "simctl list runtimes available --json")
        printf '%s\n' "${TEST_RUNTIMES_JSON:?}"
        ;;
    "simctl list devices available --json")
        printf '%s\n' "${TEST_DEVICES_JSON:?}"
        ;;
    *)
        echo "Unexpected xcrun arguments: $*" >&2
        exit 90
        ;;
esac
SCRIPT
chmod +x "$fake_bin/xcrun"

runtimes_json='{
  "runtimes": [
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
      "version": "26.4",
      "name": "iOS 26.4",
      "platform": "iOS",
      "isAvailable": true
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
      "version": "26.5",
      "name": "iOS 26.5",
      "platform": "iOS",
      "isAvailable": true
    },
    {
      "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-25-0",
      "version": "25.0",
      "name": "iOS 25.0",
      "platform": "iOS",
      "isAvailable": false
    }
  ]
}'

devices_json='{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
      {
        "name": "iPhone Air",
        "udid": "PHONE-BOOTED-264",
        "state": "Booted",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Air"
      },
      {
        "name": "iPad Pro 13-inch",
        "udid": "PAD-SHUTDOWN-264",
        "state": "Shutdown",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch"
      }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
      {
        "name": "iPhone 17 Pro",
        "udid": "PHONE-Z-265",
        "state": "Shutdown",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
      },
      {
        "name": "iPhone 17 Pro",
        "udid": "PHONE-A-265",
        "state": "Shutdown",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
      },
      {
        "name": "iPhone Air",
        "udid": "PHONE-AIR-265",
        "state": "Shutdown",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Air"
      },
      {
        "name": "iPad Pro 13-inch",
        "udid": "PAD-BOOTED-265",
        "state": "Booted",
        "isAvailable": true,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch"
      },
      {
        "name": "iPad Air 13-inch",
        "udid": "PAD-UNAVAILABLE-265",
        "state": "Shutdown",
        "isAvailable": false,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch"
      }
    ]
  }
}'

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equal() {
    local expected="$1" actual="$2" context="$3"
    [[ "$actual" == "$expected" ]] || fail "$context: expected '$expected', got '$actual'"
}

run_selector() {
    env \
        PATH="$fake_bin:$PATH" \
        TEST_RUNTIMES_JSON="$runtimes_json" \
        TEST_DEVICES_JSON="$devices_json" \
        "$@" \
        "$selector"
}

actual="$(run_selector env BEAROBS_IOS_DEVICE_FAMILY=iphone)"
assert_equal "PHONE-BOOTED-264" "$actual" "a booted iPhone must win"

actual="$(run_selector env BEAROBS_IOS_DEVICE_FAMILY=iphone CI_IOS_RUNTIME=26.5)"
assert_equal "PHONE-A-265" "$actual" "shutdown selection must be deterministic"

actual="$({ run_selector env \
    BEAROBS_IOS_DEVICE_FAMILY=iphone \
    CI_IOS_SIMULATOR="iPhone Air"; } 2>"$temporary_dir/legacy-name.err")"
assert_equal "PHONE-BOOTED-264" "$actual" "legacy simulator name must remain supported"

actual="$(run_selector env \
    BEAROBS_IOS_DEVICE_FAMILY=iphone \
    CI_IOS_SIMULATOR="PHONE-Z-265")"
assert_equal "PHONE-Z-265" "$actual" "a simulator UDID override must be supported"

actual="$(run_selector env BEAROBS_IOS_DEVICE_FAMILY=ipad)"
assert_equal "PAD-BOOTED-265" "$actual" "iPad selection must use the same stable policy"

if run_selector env \
    BEAROBS_IOS_DEVICE_FAMILY=ipad \
    CI_IOS_RUNTIME=26.4 \
    CI_IOS_SIMULATOR="Missing iPad" \
    >"$temporary_dir/missing.out" 2>"$temporary_dir/missing.err"; then
    fail "a missing requested simulator must fail"
fi
grep -Fq "No available iPad simulator matched" "$temporary_dir/missing.err" \
    || fail "missing-device error must name the requested family"
grep -Fq "requested simulator: Missing iPad" "$temporary_dir/missing.err" \
    || fail "missing-device error must echo the selector"
grep -Fq "requested runtime: iOS 26.4" "$temporary_dir/missing.err" \
    || fail "missing-device error must echo the runtime"
grep -Fq "Available iOS runtimes: 26.4, 26.5" "$temporary_dir/missing.err" \
    || {
        cat "$temporary_dir/missing.err" >&2
        fail "missing-device error must list available runtimes"
    }
grep -Fq "iOS 26.4 / iPad Pro 13-inch / Shutdown" "$temporary_dir/missing.err" \
    || fail "missing-device error must list available family devices"
if grep -Fq "25.0" "$temporary_dir/missing.err"; then
    fail "unavailable runtimes must not be advertised"
fi
if grep -Fq "iPad Air 13-inch" "$temporary_dir/missing.err"; then
    fail "unavailable devices must not be advertised"
fi

if run_selector env BEAROBS_IOS_DEVICE_FAMILY=watch \
    >"$temporary_dir/family.out" 2>"$temporary_dir/family.err"; then
    fail "an unsupported device family must fail"
fi
grep -Fq "expected 'iphone' or 'ipad'" "$temporary_dir/family.err" \
    || fail "invalid-family error must list accepted values"

echo "verify_ios_app tests passed"
