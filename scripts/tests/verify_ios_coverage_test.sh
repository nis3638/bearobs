#!/bin/bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$root_dir/scripts/ci/verify-ios-coverage.sh"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cat > "$temporary_dir/report.json" <<'JSON'
{
  "targets": [
    {
      "name": "BearObs.app",
      "files": [
        {
          "path": "/workspace/BearObs/Domain/Core.swift",
          "coveredLines": 8,
          "executableLines": 10
        },
        {
          "path": "/workspace/BearObs/App/iOS/Shell.swift",
          "coveredLines": 4,
          "executableLines": 5
        }
      ]
    },
    {
      "name": "Dependency",
      "files": [
        {
          "path": "/dependency/Noise.swift",
          "coveredLines": 0,
          "executableLines": 1000
        }
      ]
    }
  ]
}
JSON

cat > "$temporary_dir/archive.json" <<'JSON'
{
  "/workspace/BearObs/Domain/Core.swift": [
    {"line": 1, "isExecutable": true, "executionCount": 1,
      "subranges": [{"column": 1, "executionCount": 1}, {"column": 2, "executionCount": 1}]},
    {"line": 2, "isExecutable": true, "executionCount": 1,
      "subranges": [{"column": 1, "executionCount": 1}, {"column": 2, "executionCount": 1}]},
    {"line": 3, "isExecutable": true, "executionCount": 1,
      "subranges": [{"column": 1, "executionCount": 1}]},
    {"line": 4, "isExecutable": true, "executionCount": 1,
      "subranges": [{"column": 1, "executionCount": 1}]},
    {"line": 5, "isExecutable": true, "executionCount": 1,
      "subranges": [{"column": 1, "executionCount": 1}]},
    {"line": 6, "isExecutable": true, "executionCount": 1,
      "subranges": [{"column": 1, "executionCount": 1}]},
    {"line": 7, "isExecutable": true, "executionCount": 1,
      "subranges": [{"column": 1, "executionCount": 0}]},
    {"line": 8, "isExecutable": true, "executionCount": 1,
      "subranges": [{"column": 1, "executionCount": 0}]}
  ],
  "/workspace/BearObs/App/iOS/Shell.swift": [
    {"line": 1, "isExecutable": true, "executionCount": 1,
      "subranges": [{"column": 1, "executionCount": 1}]},
    {"line": 2, "isExecutable": true, "executionCount": 1,
      "subranges": [{"column": 1, "executionCount": 1}]},
    {"line": 3, "isExecutable": true, "executionCount": 1,
      "subranges": [{"column": 1, "executionCount": 1}]},
    {"line": 4, "isExecutable": true, "executionCount": 1,
      "subranges": [{"column": 1, "executionCount": 1}]},
    {"line": 5, "isExecutable": true, "executionCount": 0,
      "subranges": [{"column": 1, "executionCount": 0}]}
  ]
}
JSON

printf '%s\n' \
    "BearObs/App/iOS/Shell.swift" \
    "BearObs/App/ProjectShellView.swift" \
    > "$temporary_dir/changed-files.txt"

"$verifier" \
    "$temporary_dir/report.json" \
    "$temporary_dir/archive.json" \
    "$temporary_dir/changed-files.txt" \
    80 \
    > "$temporary_dir/pass.out"
grep -Fq "core line coverage: 80.00%" "$temporary_dir/pass.out" \
    || fail "core line coverage must be reported"
grep -Fq "core subrange proxy: 80.00%" "$temporary_dir/pass.out" \
    || fail "core branch proxy must be reported honestly"
grep -Fq "changed iOS line coverage: 80.00%" "$temporary_dir/pass.out" \
    || fail "changed iOS line coverage must use only files in the app target"
grep -Fq "changed iOS subrange proxy: 80.00%" "$temporary_dir/pass.out" \
    || fail "changed iOS branch proxy must be reported"

printf '%s\n' \
    "BearObs/App/iOS/Shell.swift" \
    "BearObs/App/MissingTargetMember.swift" \
    > "$temporary_dir/changed-files-missing-target.txt"
if "$verifier" \
    "$temporary_dir/report.json" \
    "$temporary_dir/archive.json" \
    "$temporary_dir/changed-files-missing-target.txt" \
    80 >"$temporary_dir/missing-target.out" 2>"$temporary_dir/missing-target.err"; then
    fail "a changed production Swift file missing from BearObsIOS must fail"
fi
grep -Fq "BearObs/App/MissingTargetMember.swift" "$temporary_dir/missing-target.err" \
    || fail "missing target membership must identify the omitted file"

jq '(.targets[] | select(.name == "BearObs.app") | .files[] |
    select(.path | endswith("/Domain/Core.swift")) | .coveredLines) = 7' \
    "$temporary_dir/report.json" > "$temporary_dir/report-low.json"
if "$verifier" \
    "$temporary_dir/report-low.json" \
    "$temporary_dir/archive.json" \
    "$temporary_dir/changed-files.txt" \
    80 >"$temporary_dir/low.out" 2>"$temporary_dir/low.err"; then
    fail "coverage below 80% must fail"
fi
grep -Fq "core line coverage 70.00% is below 80%" "$temporary_dir/low.err" \
    || fail "coverage failure must identify the failed scope and threshold"

jq 'del(."/workspace/BearObs/App/iOS/Shell.swift"[].subranges)' \
    "$temporary_dir/archive.json" > "$temporary_dir/archive-no-branches.json"
printf '%s\n' \
    "BearObs/App/iOS/Shell.swift" \
    > "$temporary_dir/changed-files-without-branches.txt"
if "$verifier" \
    "$temporary_dir/report.json" \
    "$temporary_dir/archive-no-branches.json" \
    "$temporary_dir/changed-files-without-branches.txt" \
    80 >"$temporary_dir/branches.out" 2>"$temporary_dir/branches.err"; then
    fail "a scope with no branch proxy data must not pass as 0/0"
fi
grep -Fq "changed iOS subrange proxy coverage is unavailable" "$temporary_dir/branches.err" \
    || {
        cat "$temporary_dir/branches.err" >&2
        fail "missing branch proxy coverage must be explicit"
    }

echo "verify iOS coverage tests passed"
