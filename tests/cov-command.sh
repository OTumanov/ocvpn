#!/usr/bin/env bash
# --install-opencode-command: установка команды /ocvpn в конфиг opencode.
. "$(dirname "$0")/lib.sh"

CANON="$(cd "$(dirname "$0")/.." && pwd)/opencode/ocvpn.md"
CMD_DIR="$WORK/oc-cmds"

# установка в изолированный каталог (override)
OCVPN_OPENCODE_CMD_DIR="$CMD_DIR" install_opencode_command >/dev/null 2>&1
check "install rc" "0" "$?"
check_true "файл команды создан" test -f "$CMD_DIR/ocvpn.md"
check_true "содержимое = opencode/ocvpn.md" diff -q "$CMD_DIR/ocvpn.md" "$CANON"
check "установлено в override-каталог" "1" "$([[ -f "$CMD_DIR/ocvpn.md" ]] && echo 1 || echo 0)"

# идемпотентность
OCVPN_OPENCODE_CMD_DIR="$CMD_DIR" install_opencode_command >/dev/null 2>&1
check "повторный install rc" "0" "$?"
check "файл не задублирован" "1" "$(ls -1 "$CMD_DIR" | grep -c '^ocvpn.md$')"

# содержимое содержит пункт про свой хост
check_true "в команде есть --add-host" grep -q -- '--add-host' "$CMD_DIR/ocvpn.md"
check_true "в команде есть --hosts" grep -q -- '--hosts' "$CMD_DIR/ocvpn.md"

# SUDO_USER: целевой HOME берётся у пользователя (getent), а не $HOME
mkdir -p "$WORK/sudohome"
getent() { echo "sudoer:x:1000:1000::$WORK/sudohome:/bin/bash"; return 0; }
out="$( SUDO_USER="sudoer" HOME="$WORK/root-home"; OCVPN_OPENCODE_CMD_DIR="" install_opencode_command 2>&1 )"
check "SUDO_USER -> домашний каталог пользователя" "1" "$([[ -f "$WORK/sudohome/.config/opencode/commands/ocvpn.md" ]] && echo 1 || echo 0)"

# ветка main --help содержит подкоманду
check_true "help содержит --install-opencode-command" bash -c '
    OCVPN_SUBS_URL=x bash "$0" --help 2>/dev/null | grep -q -- "--install-opencode-command"
' "$OCVPN_SCRIPT"

# --- opencode_present / ensure_opencode ---
mkdir -p "$WORK/emptybin"
check "opencode_present нет" "1" "$( PATH="$WORK/emptybin"; HOME="$WORK/nohome"; OCVPN_OPENCODE_BIN=""; opencode_present >/dev/null 2>&1; echo $? )"
check "opencode_present override" "/bin/true" "$(OCVPN_OPENCODE_BIN=/bin/true opencode_present)"
check "opencode_present по конфигу" "(конфиг найден, бинарь не в PATH)" \
    "$( mkdir -p "$WORK/nohome/.config/opencode"; PATH="$WORK/emptybin"; HOME="$WORK/nohome"; OCVPN_OPENCODE_BIN=""; opencode_present )"

# ensure no: opencode нет, non-interactive -> подсказка, rc 0
mkdir -p "$WORK/cleanhome"
( PATH="$WORK/emptybin"; HOME="$WORK/cleanhome"; OCVPN_OPENCODE_BIN=""; ensure_opencode no ) >/dev/null 2>&1
check "ensure_opencode no rc" "0" "$?"

# ensure yes: установщик создаёт opencode в PATH -> успех
rm -rf "$WORK/fakebin"; mkdir -p "$WORK/fakebin"
printf '#!/bin/bash\nprintf "#!/bin/bash\\nexit 0\\n" > "%s/opencode"; chmod +x "%s/opencode"\n' "$WORK/fakebin" "$WORK/fakebin" > "$WORK/inst.sh"
chmod +x "$WORK/inst.sh"
( PATH="$WORK/fakebin:/usr/bin:/bin"; HOME="$WORK/cleanhome"; OCVPN_OPENCODE_BIN=""; OCVPN_OPENCODE_INSTALL_CMD="bash $WORK/inst.sh"; ensure_opencode yes ) >/dev/null 2>&1
check "ensure_opencode install+detect rc" "0" "$?"

# ensure yes: установка провалилась
( PATH="$WORK/emptybin"; HOME="$WORK/cleanhome"; OCVPN_OPENCODE_BIN=""; OCVPN_OPENCODE_INSTALL_CMD="false"; ensure_opencode yes ) >/dev/null 2>&1
check "ensure_opencode fail rc" "1" "$?"

finish
