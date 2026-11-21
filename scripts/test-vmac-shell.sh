#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
swiftc -O -parse-as-library -framework Cocoa desktop/VMacShell.swift desktop/VMacShellTests.swift -o "$temporary/vmac-shell-tests"
"$temporary/vmac-shell-tests" "$@"
