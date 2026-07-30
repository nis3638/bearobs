#!/bin/bash

set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"

"$script_dir/check.sh"
"$script_dir/build.sh"
"$script_dir/test.sh"
"$script_dir/coverage.sh"
