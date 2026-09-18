#!/usr/bin/env bash
# Покрытие/регрессы харденинга: автоподъём прав (--user-home, --subs),
# безопасное убийство процессов (не убить себя/предка), РФ-фильтр, нормализация
# подписок (base64/CRLF/отступы), gating cleanup по ROUTES_APPLIED,
# setup_routes без DNS -> rc1 (а не exit).
. "$(dirname "$0")/lib.sh"

# ===========================================================================
echo "=== [1] _needs_root ==="
check_true "_needs_root: старт (пусто)" _needs_root ""
check_true "_needs_root: --daemon" _needs_root --daemon
check_true "_needs_root: --cleanup" _needs_root --cleanup
check_true "_needs_root: --add-host" _needs_root --add-host
check_true "_needs_root: --rm-host" _needs_root --rm-host
check "_needs_root: --status не root" "1" "$(_needs_root --status; echo $?)"
check "_needs_root: --hosts не root" "1" "$(_needs_root --hosts; echo $?)"

# ===========================================================================
echo "=== [2] _active_get ==="
printf 'HOLDER_PID=42\nACTIVE_LABEL=X Y\nACTIVE_HOST=\n' > "$ACTIVE_FILE"
check "_active_get pid" "42" "$(_active_get HOLDER_PID)"
check "_active_get label с пробелом" "X Y" "$(_active_get ACTIVE_LABEL)"
check "_active_get пустое значение" "" "$(_active_get ACTIVE_HOST)"
check "_active_get нет поля" "" "$(_active_get NOPE)"
rm -f "$ACTIVE_FILE"

# ===========================================================================
echo "=== [3] _elevate_args ==="
unset OCVPN_SUBS_FILE OCVPN_SUBS_URL
# каждый аргумент печатается с новой строки (maybe_elevate читает построчно)
SUBS_URL="$SUBS_FALLBACK_URL"
check "_elevate_args: fallback -> только user-home" \
    "--user-home"$'\n'"$HOME" "$(_elevate_args)"
SUBS_URL="https://custom/sub"
check "_elevate_args: своя подписка -> --subs" \
    "--user-home"$'\n'"$HOME"$'\n'"--subs"$'\n'"https://custom/sub" "$(_elevate_args)"
OCVPN_SUBS_FILE="$WORK/keys.txt"
check "_elevate_args: OCVPN_SUBS_FILE -> --subs" \
    "--user-home"$'\n'"$HOME"$'\n'"--subs"$'\n'"$WORK/keys.txt" "$(_elevate_args)"
unset OCVPN_SUBS_FILE
check "_elevate_args: не дублирует --subs" \
    "--user-home"$'\n'"$HOME" "$(_elevate_args --subs https://x/y)"
SUBS_URL="$SUBS_FALLBACK_URL"
check "_elevate_args: не дублирует --user-home" "" "$(_elevate_args --user-home /h)"

# ===========================================================================
echo "=== [3b] _parse_user_home / _default_home ==="
check "_parse_user_home значение" "/tmp/uh" \
    "$(_parse_user_home --daemon --user-home /tmp/uh)"
check "_parse_user_home нет флага" "" "$(_parse_user_home --daemon || true)"
_exp_home="/root"; [[ "$(uname -s)" == "Darwin" ]] && _exp_home="/var/root"
check "_default_home по ОС" "$_exp_home" "$(_default_home)"

# ===========================================================================
echo "=== [4] _has_watch / _args_without_watch ==="
check_true "_has_watch: есть" _has_watch --daemon --watch
check "_has_watch: нет" "1" "$(_has_watch --daemon; echo $?)"
check "_args_without_watch убирает --watch" \
    "--subs"$'\n'"u" "$(_args_without_watch --watch --subs u)"

# daemon_start: --watch => держатель + отдельный вотчдог
SAVE_SPAWN="$(declare -f _spawn)"
SPAWN_LOG="$WORK/spawn.log"; : > "$SPAWN_LOG"
_spawn() { local logf="$1"; shift; printf '%s\n' "$*" >> "$SPAWN_LOG"; }
daemon_start --watch --subs u >/dev/null 2>&1
check "daemon_start: держатель без --watch" "1" "$(grep -c -- '--subs u$' "$SPAWN_LOG")"
check "daemon_start: вотчдог с --watch" "1" "$(grep -c -- '--watch' "$SPAWN_LOG")"
check "daemon_start: ровно 2 спавна" "2" "$(grep -c . "$SPAWN_LOG")"
eval "$SAVE_SPAWN"

# ===========================================================================
echo "=== [5] maybe_elevate: no-op ветки ==="
check "maybe_elevate: не-TTY -> 0" "0" "$(maybe_elevate --daemon; echo $?)"
check "maybe_elevate: OCVPN_NO_ELEVATE -> 0" \
    "0" "$(OCVPN_NO_ELEVATE=1 maybe_elevate --daemon; echo $?)"
check "maybe_elevate: root -> 0" \
    "0" "$(id() { echo 0; }; maybe_elevate --daemon; echo $?)"

echo "=== [5b] _elevate_active / _elevate_exec dry-run ==="
check "_elevate_active: не-TTY -> 1" "1" "$(_elevate_active; echo $?)"
check "_elevate_active: ASSUME_TTY -> 0" "0" "$(OCVPN_ASSUME_TTY=1 _elevate_active; echo $?)"
check "_elevate_active: root -> 1" "1" "$(id() { echo 0; }; _elevate_active; echo $?)"
check "maybe_elevate dry-run: SUDO-строка" \
    "SUDO $0 --user-home $HOME --daemon" \
    "$(OCVPN_ASSUME_TTY=1 OCVPN_ELEVATE_DRYRUN=1 maybe_elevate --daemon 2>/dev/null)"

# ===========================================================================
echo "=== [6] _self_and_ancestors / _is_own_proc ==="
check "_self_and_ancestors содержит \$\$" "1" "$(_self_and_ancestors | grep -cx "$$")"
check_true "_is_own_proc self" _is_own_proc "$$"
check "_is_own_proc pid 1 -> 1" "1" "$(_is_own_proc 1; echo $?)"

# ===========================================================================
echo "=== [7] _kill_matching: не убивает себя/предка, убивает чужого ==="
UNIQ="ocvpn-h$$-$RANDOM"
VICTIM="$WORK/fake-ocvpn-$UNIQ"
printf '#!/bin/bash\nsleep 30\n' > "$VICTIM"; chmod +x "$VICTIM"
"$VICTIM" & vpid=$!
WRAP="$WORK/fake-ocvpn-$UNIQ-wrap"
printf '#!/bin/bash\nsource %q\nno_cleanup\n_kill_matching %q || true\necho INNER_OK\n' \
    "$OCVPN_SCRIPT" "fake-ocvpn-$UNIQ" > "$WRAP"
chmod +x "$WRAP"
out="$("$WRAP" 2>/dev/null)"
check "_kill_matching: предок под маской выжил" "INNER_OK" "$out"
sleep 0.3
if kill -0 "$vpid" 2>/dev/null; then
    check "_kill_matching: чужой процесс убит" "dead" "alive"
    kill "$vpid" 2>/dev/null || true
else
    check "_kill_matching: чужой процесс убит" "dead" "dead"
fi

# ===========================================================================
echo "=== [8] ru_filter ==="
RU="$WORK/ru_cases.txt"
cat > "$RU" <<'EOF'
vless://u@h:443#%F0%9F%87%B7%F0%9F%87%BA%20Russia
vless://u@h:443#RU
vless://u@h:443#RUS
vless://u@h:443#RUSSIA
vless://u@h:443#RF
vless://u@h:443#Moscow
vless://u@h:443#%D0%A0%D0%A3
vless://u@h:443#%D0%A0%D0%BE%D1%81%D1%81%D0%B8%D1%8F
vless://u@h:443#Belarus
vless://u@h:443#%D0%91%D0%B5%D0%BB%D0%B0%D1%80%D1%83%D1%81%D1%8C
vless://u@h:443#Peru
vless://u@h:443#Brunei
vless://u@h:443#Armenia(Y)
vless://u@h:443#Germany(NS)
EOF
check "ru_filter: 8 РФ отсеяно (осталось 6)" "6" "$(ru_filter < "$RU" | grep -c .)"
check "ru_filter: Belarus не тронут" "1" "$(ru_filter < "$RU" | grep -c '#Belarus$')"
check "ru_filter: Peru не тронут" "1" "$(ru_filter < "$RU" | grep -c '#Peru$')"
check "ru_filter: OCVPN_SKIP_RU=0 -> все 14" "14" \
    "$(OCVPN_SKIP_RU=0 ru_filter < "$RU" | grep -c .)"
check "ru_filter: passthrough при сбое python" "14" \
    "$( python3() { return 1; }; ru_filter < "$RU" | grep -c . )"

# ===========================================================================
echo "=== [9] download_subscription: base64 (pipefail) ==="
B64="$WORK/b64.txt"
printf 'vless://u1@a.example:443?type=tcp#US\nvless://u2@b.example:443?type=tcp#DE\n' \
    | base64 > "$B64"
SAVE_CURL="$(declare -f curl)"
curl() {
    local out="" a
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o) out="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    cat "$B64" > "$out"; return 0
}
OCVPN_SUBS_URL="https://sub.test/x" download_subscription "$WORK/d_b64" >/dev/null 2>&1
check "base64-подписка: 2 ключа" "2" "$(grep -c . "$WORK/d_b64")"
check "base64-подписка: ключ u1 на месте" "1" "$(grep -c 'u1@a.example' "$WORK/d_b64")"
unset OCVPN_SUBS_URL
eval "$SAVE_CURL"

# ===========================================================================
echo "=== [10] нормализация CRLF/отступов ==="
printf '  vless://u1@a.example:443?type=tcp#A\r\nvless://u2@b.example:443?type=tcp#B\r\n' \
    > "$WORK/crlf.txt"
OCVPN_SUBS_FILE="$WORK/crlf.txt" download_subscription "$WORK/d_crlf" >/dev/null 2>&1
check "CRLF+отступ: 2 ключа" "2" "$(grep -c . "$WORK/d_crlf")"
check "CRLF+отступ: нет \\r" "0" "$(grep -c $'\r' "$WORK/d_crlf" || true)"
unset OCVPN_SUBS_FILE

# ===========================================================================
echo "=== [11] cleanup: gating по ROUTES_APPLIED ==="
SAVE_CR="$(declare -f cleanup_routes)"
_called=0
cleanup_routes() { _called=1; }
OCVPN_OWNER=1 TMPDIR="" XRAY_PID="" ROUTES_APPLIED=0 cleanup
check "cleanup без ROUTES_APPLIED не трогает маршруты" "0" "$_called"
_called=0
OCVPN_OWNER=1 TMPDIR="" XRAY_PID="" ROUTES_APPLIED=1 cleanup
check "cleanup с ROUTES_APPLIED снимает маршруты" "1" "$_called"
eval "$SAVE_CR"
unset OCVPN_OWNER

# ===========================================================================
echo "=== [12] setup_routes: пустой DNS -> rc 1 (не exit) ==="
SAVE_RESOLVE="$(declare -f resolve_domains)"
SAVE_HOSTS="$(declare -f hosts_setup)"
resolve_domains() { :; }
hosts_setup() { :; }
OCVPN_OS=Darwin setup_routes_darwin >/dev/null 2>&1
check "setup_routes_darwin без IP -> 1" "1" "$?"
OCVPN_OS=Linux setup_routes_linux >/dev/null 2>&1
check "setup_routes_linux без IP -> 1" "1" "$?"
eval "$SAVE_RESOLVE"
eval "$SAVE_HOSTS"

# ===========================================================================
echo "=== [13] --user-home прокидывается в пути ==="
ENV_CLEAN=(env -u BASH_ENV -u OCVPN_TRACE_FILE -u OCVPN_STATE_DIR \
    -u OCVPN_OPENCODE_LOG -u OCVPN_USER_HOSTS_FILE -u OCVPN_SYS_SUBS_FILE)
out="$( "${ENV_CLEAN[@]}" bash -c \
    'source "$1" --user-home /tmp/uh; printf "%s" "$OCVPN_STATE_DIR"' _ "$OCVPN_SCRIPT" 2>/dev/null )"
check "--user-home -> state" "/tmp/uh/.local/share/ocvpn" "$out"
out="$( "${ENV_CLEAN[@]}" bash -c \
    'source "$1" --user-home /tmp/uh; printf "%s" "$OPENCODE_LOG"' _ "$OCVPN_SCRIPT" 2>/dev/null )"
check "--user-home -> opencode log" \
    "/tmp/uh/.local/share/opencode/log/opencode.log" "$out"

# ===========================================================================
echo "=== [14] нечитаемая системная подписка не роняет source ==="
mkdir -p "$WORK/nohome2"
bad="$WORK/unreadable-subs"
printf 'https://sys/sub\n' > "$bad"; chmod 000 "$bad"
out="$( env -u OCVPN_SUBS_URL -u OCVPN_SUBS_FILE -u BASH_ENV -u OCVPN_TRACE_FILE \
    HOME="$WORK/nohome2" OCVPN_SYS_SUBS_FILE="$bad" \
    bash -c 'source "$1"; printf OK' _ "$OCVPN_SCRIPT" 2>/dev/null )"
check "нечитаемая sys-подписка: source не падает" "OK" "$out"
chmod 644 "$bad"

# ===========================================================================
echo "=== [15] activate_current: успех/провал setup_routes ==="
SAVE_SETUP="$(declare -f setup_routes)"
SAVE_RESET="$(declare -f reset_opencode_conns)"
setup_routes() { return 1; }
reset_opencode_conns() { :; }
activate_current >/dev/null 2>&1
check "activate_current: провал setup_routes -> 1" "1" "$?"
setup_routes() { :; }
ACTIVE_LABEL="L" ACTIVE_HOST="h.example" ACTIVE_PORT="443" \
    ACTIVE_EXIT_IP="1.2.3.4" XRAY_PID="99999" activate_current >/dev/null 2>&1
check "activate_current: успех -> 0" "0" "$?"
check "activate_current: active.env записан" "1" "$(grep -c '^HOLDER_PID=' "$ACTIVE_FILE")"
eval "$SAVE_SETUP"
eval "$SAVE_RESET"

# ===========================================================================
echo "=== [16] reset_opencode_conns: root-ветка ==="
_out="$( id() { echo 0; }; OCVPN_RESET_IPS=$'1.2.3.4\n5.6.7.8' reset_opencode_conns 2>&1 )"
check "reset_opencode_conns root: сброшено 2 IP" "1" \
    "$(printf '%s' "$_out" | grep -c 'сброшены активные соединения opencode (2)')"

# ===========================================================================
echo "=== [17] HOME по умолчанию / Linux-ветка _default_home ==="
check "_default_home Linux" "/root" "$( uname() { echo Linux; }; _default_home )"
_dh="$( unset HOME; source "$OCVPN_SCRIPT" 2>/dev/null; printf '%s' "$HOME" )"
check "HOME задаётся при пустом HOME" "$_exp_home" "$_dh"

# ===========================================================================
echo "=== [18] _elevate_exec: ветка без доп. аргументов ==="
check "maybe_elevate dry-run без extra" "SUDO $0 --user-home /h" \
    "$(OCVPN_ASSUME_TTY=1 OCVPN_ELEVATE_DRYRUN=1 maybe_elevate --user-home /h 2>/dev/null)"

# ===========================================================================
echo "=== [19] opencode_present override / trojan fp / do_status iptables ==="
check "opencode_present: OCVPN_OPENCODE_BIN" "/bin/echo" \
    "$( OCVPN_OPENCODE_BIN=/bin/echo opencode_present )"
_d="$(mktemp -d "$WORK/cfg.XXXXXX")"
trojan_to_xray 'trojan://p@ex.com:443?security=tls&sni=s.ex&type=tcp&fp=chrome#T' "$_d" >/dev/null 2>&1
check "trojan: URL с fp= парсится" "0" "$?"
_out="$( iptables() { printf '%s\n' "-A OUTPUT -p tcp -j $IPTABLES_CHAIN"; }; OCVPN_OS=Linux do_status 2>&1 )"
check "do_status: iptables маршруты есть" "1" \
    "$(printf '%s' "$_out" | grep -c 'маршруты (iptables .*): есть')"

finish
