#!/bin/bash

set -euo pipefail

family="${1:-${BEAROBS_IOS_DEVICE_FAMILY:-iphone}}"
requested_runtime="${CI_IOS_RUNTIME:-}"
requested_simulator="${CI_IOS_SIMULATOR:-}"

case "$family" in
    iphone)
        family_name="iPhone"
        ;;
    ipad)
        family_name="iPad"
        ;;
    *)
        echo "Unsupported iOS simulator family '$family'; expected 'iphone' or 'ipad'." >&2
        exit 2
        ;;
esac

if ! command -v jq >/dev/null 2>&1; then
    echo "Unable to select an iOS simulator: jq is not installed." >&2
    exit 2
fi

if ! runtimes_json="$(xcrun simctl list runtimes available --json 2>/dev/null)"; then
    echo "Unable to list installed iOS simulator runtimes with simctl." >&2
    echo "Run 'xcrun simctl list runtimes available' to inspect CoreSimulator." >&2
    exit 2
fi
if ! devices_json="$(xcrun simctl list devices available --json 2>/dev/null)"; then
    echo "Unable to list available iOS simulators with simctl." >&2
    echo "Run 'xcrun simctl list devices available' to inspect CoreSimulator." >&2
    exit 2
fi

if ! jq -e '.runtimes | type == "array"' >/dev/null 2>&1 <<<"$runtimes_json"; then
    echo "Unable to select an iOS simulator: simctl returned invalid runtime data." >&2
    exit 2
fi
if ! jq -e '.devices | type == "object"' >/dev/null 2>&1 <<<"$devices_json"; then
    echo "Unable to select an iOS simulator: simctl returned invalid device data." >&2
    exit 2
fi

candidates="$({
    jq -n \
        --arg family "$family" \
        --arg requestedRuntime "$requested_runtime" \
        --arg requestedSimulator "$requested_simulator" \
        --argjson runtimes "$runtimes_json" \
        --argjson devices "$devices_json" '
        def is_ios_runtime:
            ((.platform // "") == "iOS")
            or ((.identifier // "") | contains(".SimRuntime.iOS-"));
        def is_family($family):
            if $family == "iphone" then
                ((.deviceTypeIdentifier // "") | contains(".SimDeviceType.iPhone-"))
                or ((.name // "") | startswith("iPhone"))
            else
                ((.deviceTypeIdentifier // "") | contains(".SimDeviceType.iPad-"))
                or ((.name // "") | startswith("iPad"))
            end;
        def version_number($index):
            ((.runtimeVersion | split(".") | .[$index] // "0") | tonumber);

        [
            $runtimes.runtimes[]
            | select(.isAvailable != false)
            | select(is_ios_runtime)
            | . as $runtime
            | ($devices.devices[$runtime.identifier] // [])[]
            | select(.isAvailable != false)
            | select(is_family($family))
            | {
                runtimeVersion: ($runtime.version // "unknown"),
                name: (.name // "unknown"),
                udid: (.udid // ""),
                state: (.state // "unknown"),
                deviceType: (.deviceTypeIdentifier // .name // "unknown")
            }
            | select(.udid != "")
            | select(
                $requestedRuntime == ""
                or .runtimeVersion == $requestedRuntime
            )
            | select(
                $requestedSimulator == ""
                or .name == $requestedSimulator
                or .udid == $requestedSimulator
            )
        ]
        | sort_by(
            (if .state == "Booted" then 0 else 1 end),
            -version_number(0),
            -version_number(1),
            -version_number(2),
            .deviceType,
            .name,
            .udid
        )
        '
} 2>/dev/null)" || {
    echo "Unable to select an iOS simulator: simctl data could not be parsed." >&2
    exit 2
}

selected_udid="$(jq -r '.[0].udid // empty' <<<"$candidates")"
if [[ -n "$selected_udid" ]]; then
    selected_description="$(
        jq -r '.[0] | "iOS \(.runtimeVersion) / \(.name) / \(.state)"' <<<"$candidates"
    )"
    echo "Selected $selected_description ($selected_udid)." >&2
    printf '%s\n' "$selected_udid"
    exit 0
fi

available_runtimes="$(
    jq -r '
        [
            .runtimes[]
            | select(.isAvailable != false)
            | select(
                ((.platform // "") == "iOS")
                or ((.identifier // "") | contains(".SimRuntime.iOS-"))
            )
            | .version
        ]
        | unique
        | sort_by(split(".") | map(tonumber))
        | if length == 0 then "(none)" else join(", ") end
    ' <<<"$runtimes_json"
)"

available_devices="$(
    jq -nr \
        --arg family "$family" \
        --argjson runtimes "$runtimes_json" \
        --argjson devices "$devices_json" '
        def is_ios_runtime:
            ((.platform // "") == "iOS")
            or ((.identifier // "") | contains(".SimRuntime.iOS-"));
        def is_family($family):
            if $family == "iphone" then
                ((.deviceTypeIdentifier // "") | contains(".SimDeviceType.iPhone-"))
                or ((.name // "") | startswith("iPhone"))
            else
                ((.deviceTypeIdentifier // "") | contains(".SimDeviceType.iPad-"))
                or ((.name // "") | startswith("iPad"))
            end;
        [
            $runtimes.runtimes[]
            | select(.isAvailable != false)
            | select(is_ios_runtime)
            | . as $runtime
            | ($devices.devices[$runtime.identifier] // [])[]
            | select(.isAvailable != false)
            | select(is_family($family))
            | "iOS \($runtime.version) / \(.name) / \(.state // "unknown")"
        ]
        | unique
        | sort
        | if length == 0 then "  (none)" else map("  " + .) | join("\n") end
        '
)"

echo "No available $family_name simulator matched the requested constraints." >&2
if [[ -n "$requested_simulator" ]]; then
    echo "  requested simulator: $requested_simulator" >&2
fi
if [[ -n "$requested_runtime" ]]; then
    echo "  requested runtime: iOS $requested_runtime" >&2
fi
echo "Available iOS runtimes: $available_runtimes" >&2
echo "Available $family_name simulators:" >&2
echo "$available_devices" >&2
exit 1
