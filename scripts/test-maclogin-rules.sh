#!/usr/bin/env bash
# Runs the checks of the small rules that the Objective-C bridge keeps in
# plain C headers, so they can be tested without the app.
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
for rule in clipboard_baseline drag_out_summary; do
  cc -Wall -Werror "internal/maclogin/testdata/${rule}_test.c" -o "$temporary/$rule"
  "$temporary/$rule"
done
