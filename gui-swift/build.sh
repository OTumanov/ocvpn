#!/usr/bin/env bash
# Сборка нативного OCVPN.app на Mac: swift build → .app-бандл в dist/.
# Запуск на macOS из корня репо: bash gui-swift/build.sh [версия]
set -euo pipefail

VER="${1:-1.4.0}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec bash "$REPO/gui-swift/build-app.sh" "$VER" "$REPO/dist/OCVPN-native.app"
