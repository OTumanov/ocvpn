#!/usr/bin/env bash
# Сборка нативного OCVPN.app на Mac: swift build → .app-бандл в dist/.
# Запуск на macOS из корня репо: bash gui-swift/build.sh
set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "Сборка native-GUI — только на macOS" >&2; exit 1; }
command -v swift >/dev/null || { echo "Нужен Swift (Xcode CLT)" >&2; exit 1; }

VER="${1:-1.3.3}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO/dist"

cd "$REPO/gui-swift"
swift build -c release
BIN="$REPO/gui-swift/.build/release/OCVPNApp"

APP="$DIST/OCVPN-native.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/OCVPN"
cat > "$APP/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>OCVPN</string>
    <key>CFBundleIdentifier</key>
    <string>ai.opencode.ocvpn.native</string>
    <key>CFBundleVersion</key>
    <string>$VER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VER</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>OCVPN</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
PLIST_EOF
echo "Готово: $APP"
