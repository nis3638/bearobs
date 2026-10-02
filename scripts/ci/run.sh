#!/bin/bash

set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"

"$script_dir/check.sh"
"$script_dir/../spikes/verify-grdb-fts5.sh"
"$script_dir/../spikes/verify-markdown.sh"
"$script_dir/../spikes/verify-atomic-write.sh"
"$script_dir/../domain/verify-domain-model.sh"
"$script_dir/build.sh"
"$script_dir/test.sh"
"$script_dir/test-ios.sh"
"$script_dir/coverage.sh"
