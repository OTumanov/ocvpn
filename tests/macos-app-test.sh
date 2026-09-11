#!/usr/bin/env bash
# Смоук-тест macOS-бандла OCVPN.app (артефакт релиза).
# Проверяет: бинарь Mach-O, встроенный бэкенд и совпадение версий, подпись.
# Использование: bash tests/macos-app-test.sh [путь-к-OCVPN.app]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
APP="${1:-$REPO/packaging/macos/OCVPN.app}"
PASS=0
FAIL=0
check() { if eval "$2"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi; }

ver_of() { grep -m1 -o 'OCVPN_VERSION="[0-9.]*"' "$1" 2>/dev/null | cut -d'"' -f2; }

check "бинарник существует" "[[ -x '$APP/Contents/MacOS/OCVPN' ]]"
check "бинарь Mach-O" "file '$APP/Contents/MacOS/OCVPN' | grep -q 'Mach-O'"
check "встроенный бэкенд" "[[ -f '$APP/Contents/Resources/ocvpn.sh' ]]"
check "бэкенд синтаксически валиден" "bash -n '$APP/Contents/Resources/ocvpn.sh'"
check "версия бэкенда = версии репо" \
    "[[ \"\$(ver_of '$APP/Contents/Resources/ocvpn.sh')\" == \"\$(ver_of '$REPO/ocvpn.sh')\" ]]"
check "Info.plist версия = версии репо" \
    "[[ \"\$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' '$APP/Contents/Info.plist' 2>/dev/null)\" == \"\$(ver_of '$REPO/ocvpn.sh')\" ]]"
check "подпись валидна" "codesign --verify --deep --strict '$APP' 2>/dev/null"

echo "Итог macOS-app: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
