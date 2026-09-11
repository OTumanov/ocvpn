#!/usr/bin/env bash
# Юнит-тесты функций приложения (Swift). Только macOS.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../gui-swift/Sources/OCVPNApp"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

command -v swiftc >/dev/null 2>&1 || { echo "нужен swiftc (xcode-select --install)"; exit 1; }

if ! swiftc -O -o "$OUT/app-tests" \
    "$SRC/ContentView.swift" "$SRC/MenuBarView.swift" "$HERE/swift/main.swift" \
    2>"$OUT/err"; then
    echo "КОМПИЛЯЦИЯ FAIL:"
    cat "$OUT/err"
    exit 1
fi
"$OUT/app-tests"
