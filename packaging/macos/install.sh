#!/usr/bin/env bash
# Установка OCVPN на macOS. Запуск: sudo ./install.sh
# Ставит: /usr/local/bin/ocvpn, /usr/local/lib/ocvpn/ocvpn-gui.py,
# /Applications/OCVPN.app, LaunchDaemon (по требованию, НЕ автозапуск).
set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "Только для macOS" >&2; exit 1; }
[[ "$(id -u)" == "0" ]] || { echo "Запустите через sudo: sudo ./install.sh" >&2; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SRC/../.." && pwd)"

install -m 0755 "$REPO/ocvpn.sh" /usr/local/bin/ocvpn
mkdir -p /usr/local/lib/ocvpn
install -m 0644 "$REPO/gui/ocvpn-gui.py" /usr/local/lib/ocvpn/ocvpn-gui.py

# .app в /Applications
rm -rf /Applications/OCVPN.app
cp -R "$SRC/OCVPN.app" /Applications/OCVPN.app
chmod +x /Applications/OCVPN.app/Contents/MacOS/OCVPN

# LaunchDaemon: ставим файл, но НЕ включаем автозапуск (RunAtLoad=false).
# Включить вручную: sudo launchctl bootstrap system /Library/LaunchDaemons/ai.opencode.ocvpn.plist
install -m 0644 "$SRC/ai.opencode.ocvpn.plist" /Library/LaunchDaemons/ai.opencode.ocvpn.plist

# python3 + tkinter
if ! /usr/bin/python3 -c "import tkinter" 2>/dev/null; then
    echo "ВНИМАНИЕ: в /usr/bin/python3 нет tkinter." >&2
    echo "GUI не запустится. Варианты: python.org-инсталлер или 'brew install python-tk'." >&2
fi

# Подписка (пример): положите свой URL в /etc/ocvpn/subs-url (chmod 600)
/usr/local/bin/ocvpn --version
echo "Готово. GUI: /Applications/OCVPN.app. CLI: ocvpn --help"
echo "Подписка: OCVPN_SUBS_URL, ~/.ocvpn-subs-url или /etc/ocvpn/subs-url — иначе публичный fallback."
