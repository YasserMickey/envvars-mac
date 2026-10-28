#!/bin/bash
# Compiles EnvStore.swift (Foundation only) with the tests and runs them. Works on macOS or Linux.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/envstore-tests"
swiftc -o "$OUT" Sources/EnvStore.swift Tests/main.swift
"$OUT"
