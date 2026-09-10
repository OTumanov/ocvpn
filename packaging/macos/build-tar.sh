#!/usr/bin/env bash
# Сборка macOS-архива с установщиком (работает везде, включая Linux).
# Внутри: ocvpn.sh, исходники Swift-GUI (собирается в install.sh на маке),
# tkinter-GUI (запасной), LaunchDaemon, install/uninstall.
# На Mac распаковать и: sudo ./install.sh
set -euo pipefail

VER="${1:-1.4.0}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGE="$(mktemp -d /tmp/ocvpn-mac-XXXXXX)"
DIST="$REPO/dist"
trap 'rm -rf "$STAGE"' EXIT

PKG="ocvpn-$VER-macos"
mkdir -p "$STAGE/$PKG"
cp "$REPO/ocvpn.sh" "$STAGE/$PKG/ocvpn.sh"
cp "$REPO/README.md" "$STAGE/$PKG/"
cp "$REPO/LICENSE" "$STAGE/$PKG/" 2>/dev/null || true
mkdir -p "$STAGE/$PKG/gui"
cp "$REPO/gui/ocvpn-gui.py" "$STAGE/$PKG/gui/"
cp -R "$REPO/gui-swift" "$STAGE/$PKG/"
rm -rf "$STAGE/$PKG/gui-swift/.build"
cp -R "$REPO/packaging/macos/OCVPN.app" "$STAGE/$PKG/"
cp "$REPO/packaging/macos/ai.opencode.ocvpn.plist" "$STAGE/$PKG/"
cp "$REPO/packaging/macos/install.sh" "$STAGE/$PKG/"
cp "$REPO/packaging/macos/uninstall.sh" "$STAGE/$PKG/"
cp "$REPO/packaging/macos/build-pkg.sh" "$STAGE/$PKG/"
chmod +x "$STAGE/$PKG/OCVPN.app/Contents/MacOS/OCVPN" \
         "$STAGE/$PKG/install.sh" "$STAGE/$PKG/uninstall.sh" "$STAGE/$PKG/build-pkg.sh" \
         "$STAGE/$PKG/gui-swift/build.sh" "$STAGE/$PKG/gui-swift/build-app.sh"

mkdir -p "$DIST"
tar -czf "$DIST/$PKG.tar.gz" -C "$STAGE" "$PKG"
echo "Готово: $DIST/$PKG.tar.gz"
tar -tzf "$DIST/$PKG.tar.gz"
