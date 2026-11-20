#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
cc -Wall -Werror internal/maclogin/testdata/clipboard_baseline_test.c -o "$temporary/clipboard-baseline-test"
"$temporary/clipboard-baseline-test"
