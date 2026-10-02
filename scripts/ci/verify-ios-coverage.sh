#!/bin/bash

set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "Usage: $0 <report.json> <archive.json> <changed-files.txt> [threshold]" >&2
    exit 2
fi

report="$1"
archive="$2"
changed_files_list="$3"
threshold="${4:-80}"

for input in "$report" "$archive" "$changed_files_list"; do
    if [[ ! -f "$input" ]]; then
        echo "Coverage input not found: $input" >&2
        exit 2
    fi
done
if ! command -v jq >/dev/null 2>&1; then
    echo "Unable to verify iOS coverage: jq is not installed." >&2
    exit 2
fi
if ! awk -v value="$threshold" 'BEGIN { exit !(value >= 0 && value <= 100) }'; then
    echo "Coverage threshold must be between 0 and 100, found '$threshold'." >&2
    exit 2
fi
if ! jq -e '.targets | type == "array"' "$report" >/dev/null 2>&1; then
    echo "Invalid xccov report JSON: $report" >&2
    exit 2
fi
if ! jq -e 'type == "object"' "$archive" >/dev/null 2>&1; then
    echo "Invalid xccov archive JSON: $archive" >&2
    exit 2
fi

target_count="$(jq '[.targets[] | select(.name == "BearObs.app")] | length' "$report")"
if [[ "$target_count" != "1" ]]; then
    echo "Expected one BearObs.app coverage target, found $target_count." >&2
    exit 1
fi

app_files="$(jq -c '[.targets[] | select(.name == "BearObs.app") | .files[]]' "$report")"
core_files="$(
    jq -c '[.[] | select(.path | test("/BearObs/(Domain|Markdown|Infrastructure|Features)/"))]' \
        <<<"$app_files"
)"
changed_paths="$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$changed_files_list")"

is_explicitly_excluded_from_ios() {
    case "$1" in
        BearObs/App/BearObsApp.swift | \
        BearObs/App/ProjectShellView.swift | \
        BearObs/Features/Library/ReaderInlineEditor.swift | \
        BearObs/Features/Library/SourcePreservingTextView.swift | \
        BearObs/Features/Library/EditorSurfaceLayoutManager.swift)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

missing_ios_sources=()
while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue
    if is_explicitly_excluded_from_ios "$relative_path"; then
        continue
    fi
    if ! jq -e --arg suffix "/$relative_path" '
        any(
            .targets[]
            | select(.name == "BearObs.app")
            | .files[];
            .path | endswith($suffix)
        )
    ' "$report" >/dev/null; then
        missing_ios_sources+=("$relative_path")
    fi
done < "$changed_files_list"
if [[ "${#missing_ios_sources[@]}" -gt 0 ]]; then
    echo "Changed Swift files expected in BearObsIOS are absent from coverage:" >&2
    printf '  %s\n' "${missing_ios_sources[@]}" >&2
    echo "Fix target membership or add a narrowly scoped explicit iOS exclusion." >&2
    exit 1
fi

changed_ios_files="$(
    jq -c --argjson changed "$changed_paths" '
        [
            .[]
            | . as $file
            | select(
                $changed
                | any(. as $relative | $file.path | endswith("/" + $relative))
            )
        ]
    ' <<<"$app_files"
)"

percentage() {
    local covered="$1" total_count="$2"
    awk -v covered_count="$covered" -v total_count="$total_count" \
        'BEGIN { printf "%.2f", (total_count == 0 ? 0 : covered_count * 100 / total_count) }'
}

require_threshold() {
    local label="$1" covered="$2" total="$3"
    local value
    if [[ "$total" -eq 0 ]]; then
        echo "$label coverage is unavailable; refusing to treat 0/0 as passing." >&2
        return 1
    fi
    value="$(percentage "$covered" "$total")"
    echo "$label: $value% ($covered/$total)"
    if ! awk -v value="$value" -v minimum="$threshold" \
        'BEGIN { exit !(value >= minimum) }'; then
        echo "$label $value% is below $threshold%." >&2
        return 1
    fi
}

verify_scope() {
    local label="$1" files="$2"
    local covered_lines executable_lines paths
    local covered_subranges total_subranges

    read -r covered_lines executable_lines < <(
        jq -r '
            reduce .[] as $file (
                {covered: 0, total: 0};
                .covered += $file.coveredLines
                | .total += $file.executableLines
            )
            | "\(.covered) \(.total)"
        ' <<<"$files"
    )
    require_threshold "$label line coverage" "$covered_lines" "$executable_lines"

    paths="$(jq '[.[] | select(.executableLines > 0) | .path]' <<<"$files")"
    read -r covered_subranges total_subranges < <(
        jq -r --argjson paths "$paths" '
            [
                to_entries[]
                | .key as $path
                | select($paths | index($path))
                | .value[]
                | .subranges[]?
                | (.executionCount // 0)
            ]
            | {
                covered: map(select(. > 0)) | length,
                total: length
            }
            | "\(.covered) \(.total)"
        ' "$archive"
    )
    require_threshold "$label subrange proxy" "$covered_subranges" "$total_subranges"
}

echo "iOS coverage threshold: $threshold%"
echo "Branch note: xccov exposes no Swift branch metric; executable subranges are enforced as the reviewable branch/region proxy."
verify_scope "core" "$core_files"

if [[ "$(jq 'length' <<<"$changed_ios_files")" -eq 0 ]]; then
    echo "changed iOS coverage: not applicable (no changed production Swift file appears in BearObs.app coverage)"
else
    verify_scope "changed iOS" "$changed_ios_files"
fi
