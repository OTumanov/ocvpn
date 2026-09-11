#!/usr/bin/env bash
# Сборка нативного OCVPN.app (SwiftUI) в указанный путь. ТОЛЬКО на macOS.
# Использование: bash build-app.sh <версия> <путь-к-OCVPN.app>
set -euo pipefail

VER="${1:?нужна версия}"
OUT="${2:?нужен путь OCVPN.app}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "$(uname -s)" == "Darwin" ]] || { echo "Сборка native-GUI — только на macOS" >&2; exit 1; }
command -v swift >/dev/null || { echo "Нужен Swift: xcode-select --install" >&2; exit 1; }

cd "$SRC"
swift build -c release
BIN="$SRC/.build/release/OCVPNApp"
[[ -x "$BIN" ]] || { echo "сборка не дала бинарник $BIN" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp "$BIN" "$OUT/Contents/MacOS/OCVPN"
# встроенный бэкенд: приложение само ставит/обновляет /usr/local/bin/ocvpn
mkdir -p "$OUT/Contents/Resources"
cp "$SRC/../ocvpn.sh" "$OUT/Contents/Resources/ocvpn.sh" 2>/dev/null || true
cat > "$OUT/Contents/Info.plist" <<PLIST_EOF
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
echo "Готово: $OUT"
