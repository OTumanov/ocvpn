#!/usr/bin/env bash
# Покрытие top-level кода ocvpn.sh: SUBS_URL из системного файла и загрузка
# пользовательского списка хостов (эти строки исполняются только при source).
. "$(dirname "$0")/lib.sh"

# --- строка 49: SUBS_URL из SYS_SUBS_FILE (HOME без ~/.ocvpn-subs-url) ---
printf 'https://sys.example/sub\n' > "$OCVPN_SYS_SUBS_FILE"
mkdir -p "$WORK/nohome"
out="$( ( HOME="$WORK/nohome"; unset OCVPN_SUBS_URL; source "$OCVPN_SCRIPT"; printf '%s' "$SUBS_URL" ) )"
check "SUBS_URL из системного файла" "https://sys.example/sub" "$out"

# --- строка 109: пользовательские хосты подхватываются в OPENCODE_DOMAINS ---
printf '# comment\ncustom.example.org\n' > "$OCVPN_USER_HOSTS_FILE"
dom="$( ( HOME="$WORK/nohome"; source "$OCVPN_SCRIPT"; printf '%s\n' "${OPENCODE_DOMAINS[@]}" ) )"
check "пользовательский хост загружен" "1" "$(printf '%s\n' "$dom" | grep -cx 'custom.example.org')"

finish
