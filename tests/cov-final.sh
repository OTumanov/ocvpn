#!/usr/bin/env bash
# Финальные ветки: ensure_opencode/install_opencode_command (в т.ч. mac и $HOME),
# ветки main, do_status без маршрутов.
. "$(dirname "$0")/lib.sh"

# --- ensure_opencode: найден ---
check "ensure найден (override)" "0" "$( OCVPN_OPENCODE_BIN=/bin/true ensure_opencode >/dev/null 2>&1; echo $? )"

# --- ensure_opencode auto без tty -> no (ветка выбора режима) ---
( PATH="$WORK/emptybin:/usr/bin:/bin"; HOME="$WORK/cleanhome"; OCVPN_OPENCODE_BIN=""; ensure_opencode auto ) >/dev/null 2>&1
check "ensure auto (нет tty) rc" "0" "$?"

# --- ensure_opencode ask + ввод "y" (установка через мок) ---
rm -rf "$WORK/fb2"; mkdir -p "$WORK/fb2"
printf '#!/bin/bash\nprintf "#!/bin/bash\\nexit 0\\n" > "%s/opencode"; chmod +x "%s/opencode"\n' "$WORK/fb2" "$WORK/fb2" > "$WORK/inst2.sh"
chmod +x "$WORK/inst2.sh"
printf 'y\n' | ( PATH="$WORK/fb2:/usr/bin:/bin"; HOME="$WORK/cleanhome"; OCVPN_OPENCODE_BIN=""; OCVPN_OPENCODE_INSTALL_CMD="bash $WORK/inst2.sh"; ensure_opencode ask ) >/dev/null 2>&1
check "ensure ask=y ставит" "1" "$([[ -x "$WORK/fb2/opencode" ]] && echo 1 || echo 0)"

# --- ensure yes: установка "успешна", но opencode не появился -> warn, rc0 ---
( PATH="$WORK/emptybin:/usr/bin:/bin"; HOME="$WORK/cleanhome"; OCVPN_OPENCODE_BIN=""; OCVPN_OPENCODE_INSTALL_CMD="true"; ensure_opencode yes ) >/dev/null 2>&1
check "ensure не виден в PATH rc" "0" "$?"

# --- install_opencode_command: ветка $HOME (SUDO_USER не задан) ---
d1="$WORK/home-cfg"; mkdir -p "$d1"
( unset SUDO_USER; HOME="$d1"; OCVPN_OPENCODE_CMD_DIR=""; install_opencode_command ) >/dev/null 2>&1
check "install в \$HOME/.config" "1" "$([[ -f "$d1/.config/opencode/commands/ocvpn.md" ]] && echo 1 || echo 0)"

# --- install_opencode_command: macOS-ветка dscl ---
mkdir -p "$WORK/machome"
dscl() { echo "NFSHomeDirectory: $WORK/machome"; return 0; }
( OCVPN_OS=Darwin; SUDO_USER="macuser"; OCVPN_OPENCODE_CMD_DIR=""; install_opencode_command ) >/dev/null 2>&1
check "install mac dscl" "1" "$([[ -f "$WORK/machome/.config/opencode/commands/ocvpn.md" ]] && echo 1 || echo 0)"
OCVPN_OS="Linux"

# --- main: ветки --install-opencode-command / --ensure-opencode ---
d2="$WORK/cli-cfg"
OCVPN_OPENCODE_CMD_DIR="$d2" bash "$OCVPN_SCRIPT" --install-opencode-command >/dev/null 2>&1
check "main --install-opencode-command rc" "0" "$?"
check_true "main создал команду" test -f "$d2/ocvpn.md"
OCVPN_OPENCODE_BIN=/bin/true bash "$OCVPN_SCRIPT" --ensure-opencode no >/dev/null 2>&1
check "main --ensure-opencode rc" "0" "$?"

# --- do_status: маршруты "нет" (linux ports закрыты) ---
( rm -f "$ACTIVE_FILE"; OCVPN_OS=Linux; do_status ) >/dev/null 2>&1
check "do_status без активного" "1" "$?"

finish
