#!/usr/bin/env bash
# Покрытийные тесты OCVPN: сорсят реальный ocvpn.sh (не копию), мокают
# внешние команды и прогоняют функции/ветки. Запускается под bashcov/kcov.
# Портативно: без mapfile/shuf/declare -A (работает и на bash 3.2 macOS).
set -uo pipefail

SCRIPT="${OCVPN_SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/ocvpn.sh}"
WORK="$(mktemp -d /tmp/ocvpn-cov-XXXXXX)"
# Аварийная уборка: не оставляем фоновые процессы и временные файлы.
cleanup_test() {
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
    done < <(jobs -p 2>/dev/null || true)
    pkill -f 'sleep 12' 2>/dev/null || true
    pkill -f 'sleep 30' 2>/dev/null || true
    pkill -f 'fake-xray' 2>/dev/null || true
    pkill -f 'tail -n0 -F' 2>/dev/null || true
    pkill -f 'threading.Event().wait' 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup_test EXIT

# Изолируем HOME: иначе тесты читают реальный ~/.ocvpn-subs-url.
mkdir -p "$WORK/home"
echo "https://fake.example/sub" > "$WORK/home/.ocvpn-subs-url"
export HOME="$WORK/home"

PASS=0
FAIL=0
check() { # name want got
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $1 (want=[$2] got=[$3])"
    fi
}
check_true() { # name cmd...
    local name="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $name"; fi
}

# --- source реального скрипта (guard не даёт main запуститься) ---
# shellcheck disable=SC1090
source "$SCRIPT"
set +e
no_cleanup

# --- изолированные пути/состояние ---
TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
TMPDIR_BASE="$WORK/tmpbase"; mkdir -p "$TMPDIR_BASE"
OCVPN_STATE_DIR="$WORK/state"; mkdir -p "$OCVPN_STATE_DIR"
QUARANTINE_FILE="$OCVPN_STATE_DIR/quarantine.tsv"
ACTIVE_FILE="$OCVPN_STATE_DIR/active.env"
WATCH_PIDFILE="$OCVPN_STATE_DIR/watch.pid"
LAST_ROTATE_FILE="$OCVPN_STATE_DIR/last_rotate"
REASON_FILE="$OCVPN_STATE_DIR/rotate.reason"
ROTATE_HOUR_FILE="$OCVPN_STATE_DIR/rotate_hour"
ROTATIONS_LOG="$OCVPN_STATE_DIR/rotations.tsv"
OPENCODE_LOG="$WORK/opencode.log"; : > "$OPENCODE_LOG"
OCVPN_LOG="$WORK/ocvpn.log"
PF_CONF="$WORK/pf.conf"; : > "$PF_CONF"
PF_ANCHOR_FILE="$WORK/pf.anchor"
export OCVPN_STATE_DIR

# Повторно сорсим реальный скрипт (guard не даёт main) и заново изолируем пути —
# это восстанавливает все реальные функции после моков.
restore_env() {
    source "$SCRIPT"
    no_cleanup
    TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
    TMPDIR_BASE="$WORK/tmpbase"; mkdir -p "$TMPDIR_BASE"
    OCVPN_STATE_DIR="$WORK/state"; mkdir -p "$OCVPN_STATE_DIR"
    QUARANTINE_FILE="$OCVPN_STATE_DIR/quarantine.tsv"
    ACTIVE_FILE="$OCVPN_STATE_DIR/active.env"
    WATCH_PIDFILE="$OCVPN_STATE_DIR/watch.pid"
    LAST_ROTATE_FILE="$OCVPN_STATE_DIR/last_rotate"
    REASON_FILE="$OCVPN_STATE_DIR/rotate.reason"
    ROTATE_HOUR_FILE="$OCVPN_STATE_DIR/rotate_hour"
    ROTATIONS_LOG="$OCVPN_STATE_DIR/rotations.tsv"
    OPENCODE_LOG="$WORK/opencode.log"
    OCVPN_LOG="$WORK/ocvpn.log"
    PF_CONF="$WORK/pf.conf"
    PF_ANCHOR_FILE="$WORK/pf.anchor"
    set +e
}

echo "=== [A] базовое: log/is_macos/no_cleanup/_spawn ==="
log "x" >/dev/null 2>&1
warn "x" >/dev/null 2>&1
err "x" >/dev/null 2>&1
OCVPN_OS="Darwin"; is_macos; check "is_macos Darwin" 0 $?
OCVPN_OS="Linux"; is_macos; check "is_macos Linux" 1 $?
OCVPN_OS="Darwin"
no_cleanup
_spawn "$WORK/spawn.log" /bin/true
sleep 0.3
check_true "_spawn создал лог" test -f "$WORK/spawn.log"

echo "=== [B] _kill_matching/stop_all ==="
printf '#!/bin/bash\nsleep 12\n' > "$WORK/fake-ocvpn"; chmod +x "$WORK/fake-ocvpn"
bash "$WORK/fake-ocvpn" & FH=$!
printf '#!/bin/bash\nexec -a "xray run -c /tmp/opencode-vpn/T/config.json" /bin/sleep 12\n' > "$WORK/fake-xray"
chmod +x "$WORK/fake-xray"
"$WORK/fake-xray" & FX=$!
sleep 0.3
printf 'HOLDER_PID=%s\nXRAY_PID=%s\n' "$FH" "$FX" > "$ACTIVE_FILE"
stop_all
sleep 0.3
check_true "stop_all убил holder" bash -c "! kill -0 $FH 2>/dev/null"
check_true "stop_all убил xray" bash -c "! kill -0 $FX 2>/dev/null"
check_true "stop_all удалил active.env" test ! -f "$ACTIVE_FILE"

echo "=== [C] resolve_ipv4 (darwin/linux, fallback) ==="
dscacheutil() { printf 'name: x\nip_address: 93.184.216.34\n'; }
dig() { echo "1.2.3.4"; }
getent() { printf '5.6.7.8  STREAM stub\n'; }
OCVPN_OS="Darwin"
check "resolve darwin" "93.184.216.34" "$(resolve_ipv4 stub)"
dscacheutil() { :; }
check "resolve darwin->dig" "1.2.3.4" "$(resolve_ipv4 stub)"
OCVPN_OS="Linux"
check "resolve linux" "5.6.7.8" "$(resolve_ipv4 stub)"
OCVPN_OS="Darwin"

echo "=== [E2] исключения хостов (deepseek/ollama — DIRECT) ==="
# проверяем РЕАЛЬНЫЙ список (до тестов, которые его перезаписывают)
check "нет deepseek" "0" "$(printf '%s\n' "${OPENCODE_DOMAINS[@]}" | grep -c 'deepseek' || true)"
check "нет ollama" "0" "$(printf '%s\n' "${OPENCODE_DOMAINS[@]}" | grep -c 'ollama' || true)"
check "есть opencode.ai" "1" "$(printf '%s\n' "${OPENCODE_DOMAINS[@]}" | grep -cx 'opencode.ai' || true)"
check "есть openrouter.ai" "1" "$(printf '%s\n' "${OPENCODE_DOMAINS[@]}" | grep -cx 'openrouter.ai' || true)"

echo "=== [D] resolve_domains ==="
resolve_ipv4() { case "$1" in a) echo 1.1.1.1; echo 2.2.2.2;; b) echo 2.2.2.2;; esac; }
OPENCODE_DOMAINS=("a" "b")
check "resolve_domains dedup" "$(printf '1.1.1.1\n2.2.2.2')" "$(resolve_domains)"

echo "=== [E] hosts_setup/hosts_cleanup (только если /etc/hosts писаем) ==="
if [[ -w /etc/hosts ]]; then
    cp /etc/hosts "$WORK/hosts.bak"
    OPENCODE_DOMAINS=("stub.example")
    resolve_ipv4() { echo 93.184.216.34; }
    hosts_setup >/dev/null 2>&1
    check_true "hosts_setup добавил" bash -c "grep -q 'opencode-vpn' /etc/hosts"
    hosts_setup >/dev/null 2>&1
    check "hosts_setup идемпотентен" 1 "$(grep -c 'stub.example' /etc/hosts)"
    hosts_cleanup >/dev/null 2>&1
    check "hosts_cleanup убрал" 0 "$(grep -c 'opencode-vpn' /etc/hosts || true)"
    cp "$WORK/hosts.bak" /etc/hosts
else
    echo "  (пропуск: /etc/hosts не писаем)"
fi

echo "=== [F] pf: anchor/refs/remove/dispatch ==="
resolve_domains() { printf '1.1.1.1\n2.2.2.2\n'; }
pf_anchor_content > "$PF_ANCHOR_FILE"
check "pf table одна строка" 1 "$(grep -c 'table <ocvpn_targets> persist { 1.1.1.1, 2.2.2.2 }' "$PF_ANCHOR_FILE")"
check "pf rdr" 1 "$(grep -c 'rdr pass on lo0' "$PF_ANCHOR_FILE")"
check "pf route-to" 1 "$(grep -c 'route-to' "$PF_ANCHOR_FILE")"
pf_ensure_refs
pf_ensure_refs
check "pf refs идемпотентны" 3 "$(grep -c -- "$PF_MARK" "$PF_CONF")"
check "pf rdr-anchor до anchor" 1 "$(awk '/rdr-anchor .*ocvpn/{r=NR} /^anchor .*ocvpn/{a=NR} END{print (r<a)?1:0}' "$PF_CONF")"
pf_remove_refs
check "pf remove" 0 "$(grep -c -- "$PF_MARK" "$PF_CONF" || true)"

pfctl() { return 0; }
hosts_setup() { :; }
hosts_cleanup() { :; }
setup_routes_darwin >/dev/null 2>&1
check "setup_routes_darwin ok" 0 $?
cleanup_routes_darwin >/dev/null 2>&1
check "cleanup_routes_darwin ok" 0 $?
pfctl() { [[ "$1" == "-f" ]] && return 1; return 0; }
( setup_routes_darwin >/dev/null 2>&1 ); check "setup_routes_darwin pfctl-fail" 1 $?
pfctl() { return 0; }
check "dispatch darwin setup" "D" "$(OCVPN_OS=Darwin; setup_routes_darwin() { echo D; }; setup_routes)"
check "dispatch darwin cleanup" "C" "$(OCVPN_OS=Darwin; cleanup_routes_darwin() { echo C; }; cleanup_routes)"

echo "=== [G] linux routes ==="
check "dispatch linux setup" "L" "$(OCVPN_OS=Linux; setup_routes_linux() { echo L; }; setup_routes)"
check "dispatch linux cleanup" "L" "$(OCVPN_OS=Linux; cleanup_routes_linux() { echo L; }; cleanup_routes)"
# реальные linux-функции с моками
OCVPN_OS="Linux"
IPT_CALLS="$WORK/ipt"
: > "$IPT_CALLS"
iptables() {
    echo "$@" >> "$IPT_CALLS"
    [[ "$*" == *"-S OUTPUT"* ]] && echo "-A OUTPUT -p tcp -j $IPTABLES_CHAIN"
    [[ "$*" == *"--pid-owner"* ]] && return 1
    return 0
}
hosts_setup() { :; }
hosts_cleanup() { :; }
resolve_domains() { printf '1.1.1.1\n'; }
XRAY_PID=$$
setup_routes_linux >/dev/null 2>&1
check "setup_routes_linux ok" 0 $?
check_true "iptables вызывался" bash -c "test -s '$IPT_CALLS'"
cleanup_routes_linux >/dev/null 2>&1
check "cleanup_routes_linux ok" 0 $?
resolve_domains() { :; }
( setup_routes_linux >/dev/null 2>&1 ); check "setup_routes_linux нет IP" 1 $?
OCVPN_OS="Darwin"

echo "=== [H] find_xray: найден и установка ==="
mkdir -p "$WORK/binpath"
printf '#!/bin/bash\necho xray\n' > "$WORK/binpath/xray"; chmod +x "$WORK/binpath/xray"
XRAY_BIN=""
PATH="$WORK/binpath:$PATH" find_xray >/dev/null 2>&1
check "find_xray найден" "xray" "$XRAY_BIN"
# установка: xray нет в PATH, curl/unzip — функции-заглушки
curl() {
    local out=""
    while [[ $# -gt 0 ]]; do
        case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
    done
    if [[ -n "$out" ]]; then : > "$out"; else echo '{"tag_name":"v9.9.9"}'; fi
    return 0
}
unzip() {
    local d=""
    while [[ $# -gt 0 ]]; do
        case "$1" in -d) d="$2"; shift 2 ;; *) shift ;; esac
    done
    [[ -n "$d" ]] && printf '#!/bin/bash\n' > "$d/xray" && chmod +x "$d/xray"
    return 0
}
mkdir -p "$WORK/fakehome/bin"
HOME="$WORK/fakehome" PATH="/usr/bin:/bin" find_xray >/dev/null 2>&1
check "find_xray установил" "$WORK/fakehome/bin/xray" "$XRAY_BIN"

echo "=== [I] stream settings + vless_to_xray ==="
check "ws не тот тип" "" "$(ws_stream_settings tcp /p h)"
check "ws settings" "1" "$(ws_stream_settings ws /p h | grep -c wsSettings)"
check "grpc settings" "1" "$(grpc_stream_settings grpc svc | grep -c grpcSettings)"
check "xhttp settings" "1" "$(xhttp_stream_settings xhttp /p h auto | grep -c xhttpSettings)"
check "xhttp не тот тип" "" "$(xhttp_stream_settings ws /p h auto)"
cfg() { local d="$WORK/cfg_$2"; mkdir -p "$d"; vless_to_xray "$1" "$d"; python3 -m json.tool "$d/config.json" >/dev/null 2>&1 && echo VALID || echo INVALID; }
check "vless reality" "VALID" "$(cfg 'vless://u@h:443?encryption=none&flow=xtls-rprx-vision&fp=chrome&pbk=P&sid=S&security=reality&sni=s&type=raw#R' r)"
check "vless tls alpn" "VALID" "$(cfg 'vless://u@h:443?encryption=none&security=tls&sni=s&alpn=h2%2Chttp%2F1.1&type=ws&path=%2Fws&host=s#T' t)"
check "vless none" "VALID" "$(cfg 'vless://u@h:443?encryption=none&security=none&type=tcp#N' n)"
check "vless grpc" "VALID" "$(cfg 'vless://u@h:443?encryption=none&security=reality&sni=s&pbk=P&type=grpc&serviceName=svc#G' g)"
check "vless xhttp" "VALID" "$(cfg 'vless://u@h:443?encryption=none&security=reality&sni=s&pbk=P&type=xhttp&path=%2Fx&mode=auto#X' x)"

echo "=== [J] ping_host ==="
python3 -c "import socket,threading; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',34567)); s.listen(1); threading.Event().wait(3)" &
LP=$!
sleep 0.4
check "ping_host живой" "1" "$(ping_host 127.0.0.1 34567 | awk '{print ($1<99999)}')"
check "ping_host мёртвый" "99999 10.255.255.1 443" "$(ping_host 10.255.255.1 443)"
kill $LP 2>/dev/null

echo "=== [K] select_candidates ==="
SUBS="$WORK/subs.txt"
printf 'vless://u1@1.1.1.1:443?security=none&type=tcp#A\nvless://u2@2.2.2.2:443?security=none&type=ws#B\nnot-a-key\n' > "$SUBS"
ping_host() { echo "5 $1 $2"; }
BATCH_SIZE=2
check_true "select_candidates" test "$(select_candidates "$SUBS" | grep -c .)" -ge 1

echo "=== [L] download_subscription ==="
printf 'vless://u@h:443?security=none&type=tcp#F\n' > "$WORK/keys.txt"
OCVPN_SUBS_FILE="$WORK/keys.txt" download_subscription "$WORK/dl1" >/dev/null 2>&1
check "download из файла" 0 $?
printf 'not a key\n' > "$WORK/nokeys.txt"
OCVPN_SUBS_FILE="$WORK/nokeys.txt" download_subscription "$WORK/dl2" >/dev/null 2>&1
check "download без vless" 1 $?
OCVPN_SUBS_FILE="$WORK/nope.txt" download_subscription "$WORK/dl3" >/dev/null 2>&1
check "download нет файла" 1 $?
unset OCVPN_SUBS_FILE
# base64 и plain через curl-заглушку
printf 'vless://u@h:443?security=none&type=tcp#B\n' | base64 > "$WORK/raw_b64"
printf 'vless://u@h:443?security=none&type=tcp#P\n' > "$WORK/raw_plain"
printf 'garbage not base64 no vless\n' > "$WORK/raw_garbage"
curl() {
    local out=""
    while [[ $# -gt 0 ]]; do
        case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
    done
    if [[ -n "$out" ]]; then cp "$FAKE_RAW" "$out"; else cat "$FAKE_RAW"; fi
}
( export FAKE_RAW="$WORK/raw_b64"; download_subscription "$WORK/dl_b64" ) >/dev/null 2>&1
check_true "download base64" bash -c "grep -q '^vless://' '$WORK/dl_b64'"
( export FAKE_RAW="$WORK/raw_plain"; download_subscription "$WORK/dl_plain" ) >/dev/null 2>&1
check_true "download plain" bash -c "grep -q '^vless://' '$WORK/dl_plain'"
( export FAKE_RAW="$WORK/raw_garbage"; download_subscription "$WORK/dl_g" ) >/dev/null 2>&1
check_true "download garbage" test -f "$WORK/dl_g"

echo "=== [M] is_supported_key ==="
for t in tcp raw ws grpc xhttp; do
    is_supported_key "vless://u@h:443?type=$t#x"; check "supported $t" 0 $?
done
is_supported_key "vless://u@h:443?type=kcp#x"; check "unsupported kcp" 1 $?
is_supported_key "vless://u@h:443?type=xhttp&extra=%7B%7D#x"; check "unsupported extra" 1 $?
is_supported_key "vless://u@h:443#x"; check "supported default tcp" 0 $?

echo "=== [N] лимиты/карантин/сброс ==="
is_rotatable_limit "Rate limit exceeded"; check "limit rate" 0 $?
is_rotatable_limit "ollama weekly usage limit"; check "limit ollama" 1 $?
parse_reset_hours "It will reset in 25 minutes."; check "reset минуты" 1 "$(parse_reset_hours "It will reset in 25 minutes.")"
parse_reset_hours "It will reset in 2 days."; check "reset дни" 48 "$(parse_reset_hours "It will reset in 2 days.")"
parse_reset_hours "Rate limit exceeded"; check "reset дефолт" "$QUARANTINE_HOURS" "$(parse_reset_hours "Rate limit exceeded")"
quarantine_add 1.2.3.4 8443 5.6.7.8 test 6 >/dev/null 2>&1
quarantine_blocked 1.2.3.4 8443 ""; check "quarantine host" 0 $?
quarantine_blocked "" "" 5.6.7.8; check "quarantine ip" 0 $?
quarantine_blocked 9.9.9.9 443 ""; check "quarantine чужой" 1 $?
check_true "quarantine_count" test "$(quarantine_count)" -ge 1

echo "=== [O] check_model_available ==="
mkdir -p "$WORK/geo/.local/share/opencode"
echo '{}' > "$WORK/geo/.local/share/opencode/auth.json"
HOME="$WORK/geo" check_model_available >/dev/null 2>&1
check "geo нет ключа -> skip" 0 $?
echo '{"opencode":{"key":"k"}}' > "$WORK/geo/.local/share/opencode/auth.json"
curl() { printf 'ok\n200'; }
HOME="$WORK/geo" check_model_available >/dev/null 2>&1
check "geo 200 -> ok" 0 $?
curl() { printf 'not available in your country\n403'; }
HOME="$WORK/geo" check_model_available >/dev/null 2>&1
check "geo block -> fail" 1 $?
curl() { printf 'server error\n500'; }
HOME="$WORK/geo" check_model_available >/dev/null 2>&1
check "geo 500 -> ok" 0 $?

echo "=== [P] exit IP ==="
curl() { echo 8.8.8.8; }
check "current_exit_ip" "8.8.8.8" "$(current_exit_ip)"
check "exit_ip_fast" "8.8.8.8" "$(exit_ip_fast)"
curl() { echo "not-ip"; }
check "current_exit_ip мусор" "" "$(current_exit_ip)"

echo "=== [Q] fetch_subscription ==="
download_subscription() { printf 'vless://u@h:443?type=tcp#A\nvless://u@h:443?type=ws#B\n' > "$1"; }
fetch_subscription >/dev/null 2>&1
check "fetch ok" 0 $?
download_subscription() { : > "$1"; }
fetch_subscription >/dev/null 2>&1
check "fetch пусто" 1 $?

echo "=== [R] pick_working_key (успех/провал) ==="
SUBS_FILE="$WORK/pick_subs.txt"
printf 'vless://u1@10.0.0.1:443?security=none&type=tcp#One\n' > "$SUBS_FILE"
select_candidates() { local tf="${2:-}"; [[ -s "$tf" ]] && return 0; printf '5\t%s\n' "vless://u1@10.0.0.1:443?security=none&type=tcp#One"; }
printf '#!/bin/bash\nexec /bin/sleep 12\n' > "$WORK/fake-xray2"; chmod +x "$WORK/fake-xray2"
XRAY_BIN="$WORK/fake-xray2"
curl() { echo 204; }
current_exit_ip() { echo 10.0.0.1; }
check_model_available() { return 0; }
quarantine_blocked() { return 1; }
pick_working_key "" >/dev/null 2>&1
check "pick success" 0 $?
check "pick выставил host" "10.0.0.1" "$ACTIVE_HOST"
kill "$XRAY_PID" 2>/dev/null
curl() { echo 000; }
fetch_subscription() { return 1; }  # пул исчерпан — не уходим в сеть
pick_working_key "" >/dev/null 2>&1
check "pick fail" 1 $?

echo "=== [S] activate_current ==="
setup_routes() { :; }
ACTIVE_LABEL="L"; ACTIVE_HOST="1.1.1.1"; ACTIVE_PORT="443"; ACTIVE_EXIT_IP="9.9.9.9"
XRAY_PID=12345
rm -f "$ACTIVE_FILE"
activate_current >/dev/null 2>&1
check_true "activate пишет active.env" bash -c "grep -q '^ACTIVE_HOST=1.1.1.1' '$ACTIVE_FILE'"

echo "=== [T] rotate_now ==="
fetch_subscription() { return 0; }
pick_working_key() { ACTIVE_EXIT_IP="8.8.8.8"; ACTIVE_LABEL="NEW"; return 0; }
activate_current() { :; }
quarantine_add() { :; }
ACTIVE_HOST="1.1.1.1"; ACTIVE_PORT="443"; ACTIVE_EXIT_IP="9.9.9.9"; XRAY_PID=99999
printf 'limit\n' > "$REASON_FILE"
rotate_now >/dev/null 2>&1
check "rotate_now ok" 0 $?
ACTIVE_HOST=""
rotate_now >/dev/null 2>&1
check "rotate_now нечего" 0 $?

echo "=== [U] do_watch (ветки) ==="
( OPENCODE_LOG="$WORK/nolog.log" do_watch >/dev/null 2>&1 ); check "watch нет лога" 1 $?
echo $$ > "$WATCH_PIDFILE"
( do_watch >/dev/null 2>&1 ); check "watch дубль" 1 $?
rm -f "$WATCH_PIDFILE"

echo "=== [V] do_rotate (ветки ошибок) ==="
rm -f "$ACTIVE_FILE"
( do_rotate "x" >/dev/null 2>&1 ); check "rotate нет active" 1 $?
printf 'HOLDER_PID=999999\nSTARTED=1\n' > "$ACTIVE_FILE"
( do_rotate "x" >/dev/null 2>&1 ); check "rotate мёртвый holder" 1 $?

echo "=== [W] supervise/cleanup ==="
# supervise в ТОМ ЖЕ subshell, где рождён XRAY_PID: wait видит его как ребёнка,
# убитый sleep реапится, kill -0 падает — без вечного цикла на зомби.
(
    /bin/sleep 12 & XP=$!
    XRAY_PID=$XP
    (sleep 0.5; kill "$XP" 2>/dev/null) &
    supervise >/dev/null 2>&1
)
check "supervise завершился" "1" "$?"
/bin/sleep 12 & CP=$!
XRAY_PID=$CP
KEEP_ROUTES=1 cleanup >/dev/null 2>&1
wait "$CP" 2>/dev/null
check_true "cleanup убил xray" bash -c "! kill -0 $CP 2>/dev/null"

echo "=== [Y] дополнительные ветки ==="
# восстанавливаем реальные функции после моков
restore_env

# cleanup: ранний выход без владения
( unset TMPDIR XRAY_PID OCVPN_OWNER; cleanup ); check "cleanup early-return" 0 $?
# _spawn без setsid (принудительно)
( command() { [[ "$1" == "-v" && "$2" == "setsid" ]] && return 1; builtin command "$@"; }
  _spawn "$WORK/spawn2.log" /bin/echo hi; sleep 0.3 )
check_true "_spawn без setsid" bash -c "grep -q hi '$WORK/spawn2.log'"
# shuffle fallback
( sort() { [[ "${1:-}" == "-R" ]] && return 1; command sort "$@"; }
  printf 'a\nb\nc\n' | shuffle | wc -l | tr -d ' ' > "$WORK/shuf_out" )
check "shuffle fallback" "3" "$(cat "$WORK/shuf_out")"
# SUBS_URL из ~/.ocvpn-subs-url
mkdir -p "$WORK/h1"; echo "https://h1/sub" > "$WORK/h1/.ocvpn-subs-url"
check "SUBS_URL из файла" "https://h1/sub" "$(HOME="$WORK/h1" bash -c 'source "$1"; echo "$SUBS_URL"' _ "$SCRIPT")"
# SUBS_URL из /etc/ocvpn/subs-url
if mkdir -p /etc/ocvpn 2>/dev/null && printf 'https://sys/sub' > /etc/ocvpn/subs-url 2>/dev/null; then
    mkdir -p "$WORK/h2"
    check "SUBS_URL из /etc" "https://sys/sub" "$(HOME="$WORK/h2" bash -c 'source "$1"; echo "$SUBS_URL"' _ "$SCRIPT")"
fi

# find_xray: установка для разных арх + ошибки
curl() {
    local out=""
    while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
    if [[ -n "$out" ]]; then : > "$out"; else echo '{"tag_name":"v9.9.9"}'; fi
}
unzip() {
    local d=""
    while [[ $# -gt 0 ]]; do case "$1" in -d) d="$2"; shift 2 ;; *) shift ;; esac; done
    [[ -n "$d" ]] && printf '#!/bin/bash\n' > "$d/xray" && chmod +x "$d/xray"
}
( OCVPN_OS=Darwin; uname() { echo mips; }; PATH="/usr/bin:/bin" HOME="$WORK/fx1" find_xray ) >/dev/null 2>&1
check "find_xray unsupported darwin" 1 $?
( OCVPN_OS=Linux; uname() { echo mips; }; PATH="/usr/bin:/bin" HOME="$WORK/fx2" find_xray ) >/dev/null 2>&1
check "find_xray unsupported linux" 1 $?
( OCVPN_OS=Darwin; uname() { echo x86_64; }; PATH="/usr/bin:/bin" HOME="$WORK/fx3" find_xray ) >/dev/null 2>&1
check "find_xray darwin x86_64" 0 $?
( OCVPN_OS=Linux; uname() { echo x86_64; }; PATH="/usr/bin:/bin" HOME="$WORK/fx4" find_xray ) >/dev/null 2>&1
check "find_xray linux x86_64" 0 $?
( OCVPN_OS=Linux; uname() { echo aarch64; }; PATH="/usr/bin:/bin" HOME="$WORK/fx5" find_xray ) >/dev/null 2>&1
check "find_xray linux aarch64" 0 $?
curl() { return 1; }
( OCVPN_OS=Darwin; uname() { echo arm64; }; PATH="/usr/bin:/bin" HOME="$WORK/fx6" find_xray ) >/dev/null 2>&1
check "find_xray curl fail" 1 $?
curl() { echo '{"tag_name":"v9.9.9"}'; }
( OCVPN_OS=Darwin; uname() { echo arm64; }
  command() { [[ "$1" == "-v" && "$2" == "unzip" ]] && return 1; builtin command "$@"; }
  PATH="/usr/bin:/bin" HOME="$WORK/fx7" find_xray ) >/dev/null 2>&1
check "find_xray нет unzip" 1 $?

# current_exit_ip fallback на ipinfo
curl() { case "$*" in *ipify*) return 1 ;; *ipinfo*) echo 7.7.7.7 ;; *) return 1 ;; esac; }
check "current_exit_ip fallback" "7.7.7.7" "$(current_exit_ip)"
# check_model_available: geo-паттерн в теле (451)
( HOME="$WORK/geo2"; export HOME
  mkdir -p "$WORK/geo2/.local/share/opencode"
  echo '{"opencode":{"key":"k"}}' > "$WORK/geo2/.local/share/opencode/auth.json"
  curl() { printf 'Geo restricted\n451'; }
  check_model_available ) >/dev/null 2>&1
check "geo pattern 451" 1 $?

# pick_working_key: ветки
SUBS_FILE="$WORK/pick2.txt"
printf 'vless://u@10.0.0.2:443?security=none&type=tcp#T\n' > "$SUBS_FILE"
printf '#!/bin/bash\nexec /bin/sleep 12\n' > "$WORK/fake-xray2"; chmod +x "$WORK/fake-xray2"
XRAY_BIN="$WORK/fake-xray2"
fetch_subscription() { return 1; }   # при исчерпании пула — не уходим в сеть
pick_cand() { local tf="${2:-}"; [[ -s "$tf" ]] && return 0; printf '5\t%s\n' "vless://u@10.0.0.2:443?security=none&type=tcp#T"; }
select_candidates() { :; }
curl() { echo 204; }
current_exit_ip() { echo 10.0.0.2; }
check_model_available() { return 0; }
quarantine_blocked() { return 1; }
quarantine_add() { :; }
# fallback: пинг не ответил — берём из пула
pick_working_key "" >/dev/null 2>&1; check "pick fallback" 0 $?
kill "$XRAY_PID" 2>/dev/null
SUBS_FILE="$WORK/pick3.txt"; printf 'not vless\n' > "$SUBS_FILE"
pick_working_key "" >/dev/null 2>&1; check "pick нет кандидатов" 1 $?
SUBS_FILE="$WORK/pick2.txt"
select_candidates() { pick_cand "$@"; }
quarantine_blocked() { return 0; }
pick_working_key "" >/dev/null 2>&1; check "pick карантин host" 1 $?
quarantine_blocked() { return 1; }
XRAY_BIN=/bin/false
pick_working_key "" >/dev/null 2>&1; check "pick xray не стартовал" 1 $?
XRAY_BIN="$WORK/fake-xray2"
pick_working_key "10.0.0.2" >/dev/null 2>&1; check "pick тот же IP" 1 $?
kill "$XRAY_PID" 2>/dev/null
quarantine_blocked() { case "$3" in 10.0.0.2) return 0 ;; *) return 1 ;; esac; }
pick_working_key "" >/dev/null 2>&1; check "pick IP в карантине" 1 $?
kill "$XRAY_PID" 2>/dev/null
quarantine_blocked() { return 1; }
check_model_available() { return 1; }
pick_working_key "" >/dev/null 2>&1; check "pick geo-block" 1 $?
kill "$XRAY_PID" 2>/dev/null

# цикл: первый кандидат провалился — берёт следующий (исключая забракованный) и подключается
SAVE_TRYK="$(declare -f try_key)"
select_candidates() {
    local tf="${2:-}"
    if ! grep -q 'A' "$tf" 2>/dev/null; then printf '5\t%s\n' "vless://a@10.0.0.1:443?security=none&type=tcp#A"; return 0; fi
    if ! grep -q 'B' "$tf" 2>/dev/null; then printf '5\t%s\n' "vless://b@10.0.0.2:443?security=none&type=tcp#B"; return 0; fi
    return 0
}
try_key() { case "$1" in *b@*) ACTIVE_HOST=10.0.0.2; ACTIVE_LABEL=B; return 0 ;; *) return 1 ;; esac; }
SUBS_FILE="$WORK/pick_loop.txt"
printf 'vless://a@10.0.0.1:443?security=none&type=tcp#A\nvless://b@10.0.0.2:443?security=none&type=tcp#B\n' > "$SUBS_FILE"
pick_working_key "" >/dev/null 2>&1
check "pick перебирает батчи до успеха" 0 $?
check "pick выбрал следующий ключ" "10.0.0.2" "$ACTIVE_HOST"
eval "$SAVE_TRYK"

# do_restart
_spawn() { /bin/sleep 6 & printf 'HOLDER_PID=%s\nSTARTED=200\nACTIVE_EXIT_IP=2.2.2.2\n' "$!" > "$ACTIVE_FILE"; }
sleep() { :; }
/bin/sleep 12 & HP=$!
printf 'HOLDER_PID=%s\nSTARTED=100\nACTIVE_EXIT_IP=1.1.1.1\n' "$HP" > "$ACTIVE_FILE"
( do_restart ) >/dev/null 2>&1; check "do_restart успех" 0 $?
kill $HP 2>/dev/null
/bin/sleep 12 & HP2=$!
printf 'HOLDER_PID=%s\nSTARTED=100\nACTIVE_EXIT_IP=1.1.1.1\n' "$HP2" > "$ACTIVE_FILE"
_spawn() { /bin/sleep 6 & printf 'HOLDER_PID=%s\nSTARTED=200\nACTIVE_EXIT_IP=1.1.1.1\n' "$!" > "$ACTIVE_FILE"; }
bash() { return 0; }
( do_restart ) >/dev/null 2>&1; check "do_restart тот же IP" 0 $?
unset -f bash
kill $HP2 2>/dev/null
_spawn() { /bin/sleep 6 & :; }
( do_restart ) >/dev/null 2>&1; check "do_restart идёт в фоне" 0 $?
_spawn() { :; }
( do_restart ) >/dev/null 2>&1; check "do_restart упал" 1 $?

# do_rotate success / timeout
/bin/sleep 12 & HP3=$!
printf 'HOLDER_PID=%s\nSTARTED=100\nACTIVE_EXIT_IP=1.1.1.1\nACTIVE_LABEL=L\n' "$HP3" > "$ACTIVE_FILE"
kill() { if [[ "${1:-}" == "-USR1" ]]; then printf 'HOLDER_PID=%s\nSTARTED=200\nACTIVE_EXIT_IP=2.2.2.2\nACTIVE_LABEL=NEW\n' "$HP3" > "$ACTIVE_FILE"; return 0; fi; builtin kill "$@"; }
( do_rotate "r" ) >/dev/null 2>&1; check "do_rotate успех" 0 $?
unset -f kill
kill $HP3 2>/dev/null
/bin/sleep 12 & HP4=$!
printf 'HOLDER_PID=%s\nSTARTED=100\nACTIVE_EXIT_IP=1.1.1.1\n' "$HP4" > "$ACTIVE_FILE"
kill() { [[ "${1:-}" == "-USR1" ]] && return 0; builtin kill "$@"; }
( do_rotate "r" ) >/dev/null 2>&1; check "do_rotate таймаут" 1 $?
unset -f kill
kill $HP4 2>/dev/null

# do_watch: полный цикл
: > "$OPENCODE_LOG"
rm -f "$WATCH_PIDFILE" "$LAST_ROTATE_FILE" "$ROTATE_HOUR_FILE"
bash() { return 0; }
( do_watch >/dev/null 2>&1 ) & WP=$!
sleep 0.6
echo "Rate limit exceeded" >> "$OPENCODE_LOG"; sleep 0.6
echo "$(date +%s)" > "$LAST_ROTATE_FILE"
echo "Too many requests" >> "$OPENCODE_LOG"; sleep 0.6
rm -f "$LAST_ROTATE_FILE"; echo "$(date +%Y%m%d%H) 999" > "$ROTATE_HOUR_FILE"
echo "status 429" >> "$OPENCODE_LOG"; sleep 0.6
kill $WP 2>/dev/null
unset -f bash
check_true "do_watch отработал" bash -c "[[ -s '$LAST_ROTATE_FILE' || -s '$ROTATE_HOUR_FILE' ]]"

# parse_subs_flag
printf 'vless://u@h:443?type=tcp#x\n' > "$WORK/k.txt"
subs_case() { local name="$1" want="$2"; shift 2; local rc=0; ( parse_subs_flag "$@" ) >/dev/null 2>&1 || rc=$?; check "subs $name" "$want" "$rc"; }
subs_case файл 0 --subs "$WORK/k.txt"
subs_case url 0 --subs https://e/x
subs_case мусор 2 --subs 'nope'
subs_case пусто 2 --subs

# do_status с "включёнными" состояниями
STATUS_OUT="$(
  OCVPN_OS=Darwin
  pgrep() { echo 123; }
  ss() { printf 'LISTEN 0 0 127.0.0.1:10808 \nLISTEN 0 0 127.0.0.1:10809 \nLISTEN 0 0 127.0.0.1:12345 \n'; }
  command() { [[ "$1" == "-v" && "$2" == "ss" ]] && return 0; builtin command "$@"; }
  pfctl() { echo "rdr pass on lo0 ... ocvpn_targets"; }
  curl() { echo 8.8.8.8; }
  printf 'HOLDER_PID=1\nACTIVE_LABEL=L\nACTIVE_HOST=1.1.1.1\nACTIVE_PORT=443\n' > "$ACTIVE_FILE"
  echo $$ > "$WATCH_PIDFILE"
  do_status 2>/dev/null
)"
check "do_status xray" "1" "$(echo "$STATUS_OUT" | grep -c 'xray: запущен')"
check "do_status порт" "1" "$(echo "$STATUS_OUT" | grep -c 'порт 10808: слушается')"
check "do_status маршруты" "1" "$(echo "$STATUS_OUT" | grep -c 'маршруты (pf .*): есть')"
check "do_status вотчдог" "1" "$(echo "$STATUS_OUT" | grep -c 'вотчдог: запущен')"
check "do_status exit IP" "1" "$(echo "$STATUS_OUT" | grep -c 'exit IP: 8.8.8.8')"
rm -f "$WATCH_PIDFILE"

echo "=== [Z] протоколы и источники ==="
# normalize_subs_url: GitHub blob/raw -> raw
check "normalize blob" "https://raw.githubusercontent.com/u/r/main/f.txt" \
    "$(normalize_subs_url 'https://github.com/u/r/blob/main/f.txt')"
check "normalize raw" "https://raw.githubusercontent.com/u/r/main/f.txt" \
    "$(normalize_subs_url 'https://github.com/u/r/raw/main/f.txt')"
check "normalize обычный" "https://example.com/x" "$(normalize_subs_url 'https://example.com/x')"
# url_host_port
check "hp vless" "h 443" "$(url_host_port 'vless://u@h:443?x=1#y')"
check "hp trojan" "h 443" "$(url_host_port 'trojan://p@h:443?x=1#y')"
check "hp http" "h 8080" "$(url_host_port 'http://u:p@h:8080#x')"
check "hp socks" "h 1080" "$(url_host_port 'socks5://u:p@h:1080#x')"
check "hp ss sip002" "h 8388" "$(url_host_port "ss://$(printf 'aes-256-gcm:p' | base64)@h:8388#x")"
check "hp vmess" "h 443" "$(url_host_port "vmess://$(printf '{"add":"h","port":"443"}' | base64)#x")"
# конвертеры -> protocol в config.json
pc() { local d="$WORK/proto_$2"; mkdir -p "$d"; uri_to_xray "$1" "$d" >/dev/null 2>&1 \
    && python3 -c "import json;print(json.load(open('$d/config.json'))['outbounds'][0]['protocol'])" || echo FAIL; }
check "proto vless" "vless" "$(pc 'vless://u@h:443?security=none&type=tcp#V' v)"
check "proto vmess" "vmess" "$(pc "vmess://$(printf '{"add":"h","port":"443","id":"x","net":"ws","path":"/","tls":"tls","host":"h"}' | base64)#M" m)"
check "proto trojan" "trojan" "$(pc 'trojan://p@h:443?security=tls&type=tcp#T' t)"
check "proto ss" "shadowsocks" "$(pc "ss://$(printf 'aes-256-gcm:p' | base64)@h:8388#S" s)"
check "proto http" "http" "$(pc 'http://u:p@h:8080#H' h)"
check "proto https" "http" "$(pc 'https://u:p@h:8443#H' hs)"
check "proto socks" "socks" "$(pc 'socks5://u:p@h:1080#K' k)"
# is_supported_key по схемам
for s in vless vmess trojan ss http https socks socks5; do
    is_supported_key "$s://u@h:443?type=tcp#x" 2>/dev/null
    check "supported $s" 0 $?
done
is_supported_key 'socks4://u@h:1080#x'; check "unsupported socks4" 1 $?
is_supported_key 'hysteria2://u@h:443#x'; check "unsupported hysteria2" 1 $?
# несколько источников в одном файле (ключ + вложенный файл)
printf 'vless://u1@a:443?security=none&type=tcp#A\n' > "$WORK/m_a.txt"
printf 'vless://u2@c:443?security=none&type=tcp#C\n%s\n' "$WORK/m_a.txt" > "$WORK/m_list.txt"
OCVPN_SUBS_FILE="$WORK/m_list.txt" download_subscription "$WORK/m_out.txt" >/dev/null 2>&1
check "multi-source count" "2" "$(grep -c . "$WORK/m_out.txt")"

echo "=== [X] main-ветки (subshell, со стабами) ==="
restore_env
dig() { echo 1.2.3.4; }
( main --help >/dev/null 2>&1 ); check "main --help" 0 $?
( main --version >/dev/null 2>&1 ); check "main --version" 0 $?
( OCVPN_SUBS_URL=https://x main --version >/dev/null 2>&1 ); check "main SUBS_URL env" 0 $?
( main --status >/dev/null 2>&1 ); rc_st=$?
check_true "main --status ran" bash -c "[[ $rc_st -eq 0 || $rc_st -eq 1 ]]"
( main --new-ip >/dev/null 2>&1 ); check "main --new-ip" 1 $?
stop_all() { :; }
cleanup_routes() { :; }
( main --cleanup >/dev/null 2>&1 ); check "main --cleanup" 0 $?
do_restart() { return 0; }
( main --restart >/dev/null 2>&1 ); check "main --restart" 0 $?
( OPENCODE_LOG="$WORK/nolog.log" main --watch >/dev/null 2>&1 ); check "main --watch" 1 $?
_spawn() { :; }
( main --daemon >/dev/null 2>&1 ); check "main --daemon" 0 $?
find_xray() { XRAY_BIN="$WORK/fake-xray2"; }
fetch_subscription() { SUBS_FILE="$WORK/pick_subs.txt"; return 0; }
pick_working_key() { return 1; }
( main >/dev/null 2>&1 ); check "main connect fail" 1 $?
pick_working_key() { return 0; }
activate_current() { :; }
supervise() { :; }
( main >/dev/null 2>&1 ); check "main connect" 0 $?

echo ""
echo "Итог: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
