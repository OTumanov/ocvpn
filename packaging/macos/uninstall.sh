#!/usr/bin/env bash
# Удаление OCVPN на macOS. Запуск: sudo ./uninstall.sh
set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "Только для macOS" >&2; exit 1; }
[[ "$(id -u)" == "0" ]] || { echo "Запустите через sudo: sudo ./uninstall.sh" >&2; exit 1; }

# Остановить демон и снять pf-маршруты (не валимся, если уже чисто)
/usr/local/bin/ocvpn --cleanup 2>/dev/null || true
launchctl bootout system/ai.opencode.ocvpn 2>/dev/null || true

rm -rf /Applications/OCVPN.app \
       /usr/local/bin/ocvpn \
       /usr/local/lib/ocvpn \
       /Library/LaunchDaemons/ai.opencode.ocvpn.plist

echo "OCVPN удалён. Бэкап pf.conf (если создавался): /etc/pf.conf.ocvpn-bak"
