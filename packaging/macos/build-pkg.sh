#!/usr/bin/env bash
# Сборка .pkg на Mac (pkgbuild есть только в Xcode CLT).
# Запуск на macOS из корня репо: bash packaging/macos/build-pkg.sh
# На Linux этот скрипт не работает — используйте make macos-tar.
set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "Сборка .pkg — только на macOS" >&2; exit 1; }
command -v pkgbuild >/dev/null || { echo "Нужен pkgbuild (Xcode Command Line Tools)" >&2; exit 1; }

VER="${1:-1.3.0}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="$(mktemp -d /tmp/ocvpn-pkg-XXXXXX)"
DIST="$REPO/dist"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/usr/local/bin" "$STAGE/usr/local/lib/ocvpn" \
         "$STAGE/Applications" "$STAGE/Library/LaunchDaemons"
install -m 0755 "$REPO/ocvpn.sh" "$STAGE/usr/local/bin/ocvpn"
install -m 0644 "$REPO/gui/ocvpn-gui.py" "$STAGE/usr/local/lib/ocvpn/ocvpn-gui.py"
cp -R "$REPO/packaging/macos/OCVPN.app" "$STAGE/Applications/OCVPN.app"
chmod +x "$STAGE/Applications/OCVPN.app/Contents/MacOS/OCVPN"
install -m 0644 "$REPO/packaging/macos/ai.opencode.ocvpn.plist" \
    "$STAGE/Library/LaunchDaemons/ai.opencode.ocvpn.plist"

mkdir -p "$DIST"
pkgbuild --root "$STAGE" \
         --identifier ai.opencode.ocvpn \
         --version "$VER" \
         --install-location / \
         "$DIST/ocvpn-$VER-macos.pkg"
echo "Готово: $DIST/ocvpn-$VER-macos.pkg"
