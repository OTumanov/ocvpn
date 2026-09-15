#!/usr/bin/env bash
# Покрытийные тесты ocvpn: подписки/источники, резолв IPv4, карантин/лимиты,
# маршруты Linux (iptables) и macOS (pf), hosts, --subs.
# Хост не трогаем: изоляция и моки — из tests/lib.sh (iptables/pfctl/ss/ip/
# route/pkill/curl заглушены, HOME/HOSTS_FILE/PF_CONF/state изолированы).
. "$(dirname "$0")/lib.sh"

# lib.sh снимает свой EXIT-trap через no_cleanup(ocvpn) — вернём уборку только
# для своих временных файлов, чужие процессы не трогаем.
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

# --- сохранённые оригиналы функций, которые будем локально мокать ---
SAVE_RESOLVE_IPV4="$(declare -f resolve_ipv4)"
SAVE_RESOLVE_DOMAINS="$(declare -f resolve_domains)"
SAVE_HOSTS_SETUP="$(declare -f hosts_setup)"
SAVE_HOSTS_CLEANUP="$(declare -f hosts_cleanup)"
SAVE_FETCH_ONE="$(declare -f _fetch_one_source)"
SAVE_CURL="$(declare -f curl)"

echo "=== [1] normalize_subs_url ==="
check "blob https" "https://raw.githubusercontent.com/u/r/main/f.txt" \
    "$(normalize_subs_url 'https://github.com/u/r/blob/main/f.txt')"
check "blob http" "https://raw.githubusercontent.com/u/r/main/f.txt" \
    "$(normalize_subs_url 'http://github.com/u/r/blob/main/f.txt')"
check "raw" "https://raw.githubusercontent.com/u/r/br/f.txt" \
    "$(normalize_subs_url 'https://github.com/u/r/raw/br/f.txt')"
check "обычный URL" "https://example.com/x" "$(normalize_subs_url 'https://example.com/x')"
check "не github" "vless://u@h:443#x" "$(normalize_subs_url 'vless://u@h:443#x')"
check "пусто" "" "$(normalize_subs_url '')"

echo "=== [2] resolve_ipv4 / resolve_domains ==="
dscacheutil() { printf 'name: x\nip_address: 93.184.216.34\nip_address: 93.184.216.34\n'; }
dig() { echo 1.2.3.4; }
getent() { printf '5.6.7.8  STREAM stub\n5.6.7.8  DGRAM stub\n1.1.1.1 STREAM stub\n'; }
OCVPN_OS="Darwin"
check "mac dscacheutil" "93.184.216.34" "$(resolve_ipv4 x)"
dscacheutil() { :; }
check "mac dig fallback" "1.2.3.4" "$(resolve_ipv4 x)"
dig() { printf '1.2.3.4\nnot-an-ip\n::1\n'; }
check "mac dig фильтр IPv4" "1.2.3.4" "$(resolve_ipv4 x)"
dig() { :; }
check "mac пусто" "" "$(resolve_ipv4 x)"
OCVPN_OS="Linux"
check "linux getent" "$(printf '1.1.1.1\n5.6.7.8')" "$(resolve_ipv4 stub)"
unset -f dscacheutil dig getent
OCVPN_OS="Linux"

resolve_ipv4() { case "$1" in a) printf '1.1.1.1\n2.2.2.2\n';; b) printf '2.2.2.2\n3.3.3.3\n';; esac; }
OPENCODE_DOMAINS=("a" "b")
check "resolve_domains dedup+sort" "$(printf '1.1.1.1\n2.2.2.2\n3.3.3.3')" "$(resolve_domains)"
resolve_ipv4() { :; }
OPENCODE_DOMAINS=("a")
check "resolve_domains пусто" "" "$(resolve_domains)"
eval "$SAVE_RESOLVE_IPV4"
OPENCODE_DOMAINS=("stub.example")

echo "=== [3] карантин / лимиты / reset ==="
rm -f "$QUARANTINE_FILE"
check "blocked пусто" "1" "$(quarantine_blocked h 1 ''; echo $?)"
quarantine_add h 1 1.2.3.4 reason 6 >/dev/null 2>&1
check "add строка" "1" "$(grep -c . "$QUARANTINE_FILE")"
check "add host" "h" "$(cut -f1 "$QUARANTINE_FILE")"
check "add port" "1" "$(cut -f2 "$QUARANTINE_FILE")"
check "add ip" "1.2.3.4" "$(cut -f3 "$QUARANTINE_FILE")"
check "add reason" "reason" "$(cut -f5 "$QUARANTINE_FILE")"
check "blocked host:port" "0" "$(quarantine_blocked h 1 ''; echo $?)"
check "blocked по IP" "0" "$(quarantine_blocked '' '' 1.2.3.4; echo $?)"
check "blocked чужой" "1" "$(quarantine_blocked z 9 ''; echo $?)"
check "count непусто" "1" "$(quarantine_count)"
check "count пусто -> 0" "0" \
    "$(rm -f "$QUARANTINE_FILE"; quarantine_count)"

# санитизация reason: табы -> пробелы, обрезка до 160
quarantine_add h 2 2.2.2.2 "$(printf 'x\ty\tz')" 6 >/dev/null 2>&1
check "reason санитизация" "x y z" "$(tail -n1 "$QUARANTINE_FILE" | cut -f5)"

# prune выкидывает истёкшие
now="$(date +%s)"
printf 'old\t1\t9.9.9.9\t%s\tx\nfut\t2\t8.8.8.8\t%s\ty\n' \
    "$((now - 100))" "$((now + 100))" > "$QUARANTINE_FILE"
quarantine_prune
check "prune оставил истёкшие?" "1" "$(grep -c . "$QUARANTINE_FILE")"
check "prune оставил будущий" "fut" "$(cut -f1 "$QUARANTINE_FILE")"

check "rot rate" "0" "$(is_rotatable_limit 'Rate limit exceeded'; echo $?)"
check "rot 429" "0" "$(is_rotatable_limit 'HTTP 429 Too Many'; echo $?)"
check "rot usage reset" "0" "$(is_rotatable_limit 'usage limit will reset in 5 minutes'; echo $?)"
check "rot account_rate" "0" "$(is_rotatable_limit 'account_rate_limit'; echo $?)"
check "rot ollama исключён" "1" "$(is_rotatable_limit 'ollama usage limit reset in 2 hours'; echo $?)"
check "rot balance исключён" "1" "$(is_rotatable_limit 'Insufficient balance 429'; echo $?)"
check "rot Forbidden приоритет" "1" "$(is_rotatable_limit '429 Forbidden'; echo $?)"
check "rot random" "1" "$(is_rotatable_limit 'all good'; echo $?)"

check "reset 25m->1" "1" "$(parse_reset_hours 'It will reset in 25 minutes.')"
check "reset 90m->2" "2" "$(parse_reset_hours 'reset in 90 minute')"
check "reset 1m->1" "1" "$(parse_reset_hours 'reset in 1 minute')"
check "reset 3h" "3" "$(parse_reset_hours 'It will reset in 3 hours.')"
check "reset 2d" "48" "$(parse_reset_hours 'It will reset in 2 days.')"
check "reset cap 168" "168" "$(parse_reset_hours 'It will reset in 200 days.')"
check "reset default" "$QUARANTINE_HOURS" "$(parse_reset_hours 'nope')"

echo "=== [4] _fetch_one_source ==="
out="$(_fetch_one_source '')"; rc=$?
check "fetch empty rc" "0" "$rc"
check "fetch empty out" "" "$out"
out="$(_fetch_one_source '#comment')"; rc=$?
check "fetch comment rc" "0" "$rc"
check "fetch comment out" "" "$out"
out="$(_fetch_one_source 'vless://u@h:443#x')"; rc=$?
check "fetch key rc" "0" "$rc"
check "fetch key out" "vless://u@h:443#x" "$out"
out="$(_fetch_one_source 'http://u:p@h:8080#x')"; rc=$?
check "fetch http-прокси rc" "0" "$rc"
check "fetch http-прокси out" "http://u:p@h:8080#x" "$out"
out="$(_fetch_one_source 'garbage' 2>/dev/null)"; rc=$?
check "fetch unknown rc" "1" "$rc"
check "fetch unknown out" "" "$out"

printf '#c\nvless://u1@a:443?type=tcp#A\n' > "$WORK/f_src"
out="$(_fetch_one_source "$WORK/f_src")"; rc=$?
check "fetch файл rc" "0" "$rc"
check "fetch файл out" "vless://u1@a:443?type=tcp#A" "$out"
printf 'vless://u2@b:443?type=tcp#B\n%s\n' "$WORK/f_src" > "$WORK/f_list"
check "fetch вложенный файл" "2" "$(_fetch_one_source "$WORK/f_list" | grep -c '^vless://')"

CURL_CALLS="$WORK/curl_calls"
curl() {
    printf '%s\n' "$*" >> "$CURL_CALLS"
    local o=""
    while [[ $# -gt 0 ]]; do case "$1" in -o) o="$2"; shift 2 ;; *) shift ;; esac; done
    if [[ -n "$o" ]]; then cp "$FAKE_RAW" "$o"; else cat "$FAKE_RAW"; fi
    return 0
}
printf 'vless://u@h:443?type=tcp#PLAIN\n' > "$WORK/raw_plain"
printf 'vless://u@h:443?type=tcp#B64\n' | base64 > "$WORK/raw_b64"
printf 'no keys here\n' > "$WORK/raw_garb"
FAKE_RAW="$WORK/raw_plain"
check "fetch url plain" "vless://u@h:443?type=tcp#PLAIN" "$(_fetch_one_source https://ex/sub)"
FAKE_RAW="$WORK/raw_b64"
check "fetch url base64" "vless://u@h:443?type=tcp#B64" "$(_fetch_one_source https://ex/sub)"
FAKE_RAW="$WORK/raw_garb"
out="$(_fetch_one_source https://ex/sub)"; rc=$?
check "fetch url garbage rc" "0" "$rc"
check "fetch url garbage out" "" "$out"
# Наблюдаемый баг: список https-ссылок подписок не рекурсируется, а отдаётся
# как есть (SUPPORTED_RE матчит ^https?:// раньше ветки «список ссылок»).
printf 'https://sub-a\nhttps://sub-b\n' > "$WORK/raw_list"
FAKE_RAW="$WORK/raw_list"
check "fetch список ссылок (баг: не рекурсия)" "$(printf 'https://sub-a\nhttps://sub-b')" \
    "$(_fetch_one_source https://ex/list)"
curl() { return 1; }
out="$(_fetch_one_source https://ex/sub 2>/dev/null)"; rc=$?
check "fetch url curl-fail rc" "1" "$rc"
check "fetch url curl-fail out" "" "$out"

: > "$CURL_CALLS"
curl() {
    printf '%s\n' "$*" >> "$CURL_CALLS"
    local o=""
    while [[ $# -gt 0 ]]; do case "$1" in -o) o="$2"; shift 2 ;; *) shift ;; esac; done
    cp "$WORK/raw_plain" "$o"
    return 0
}
out="$(_fetch_one_source 'https://github.com/u/r/blob/main/f.txt')"
check_true "fetch blob -> raw URL" grep -q 'raw.githubusercontent.com/u/r/main/f.txt' "$CURL_CALLS"
check_true "fetch blob out ключ" bash -c 'grep -q "^vless://" <<<"$1"' _ "$out"
eval "$SAVE_CURL"

echo "=== [4b] download_subscription ==="
SRC_LOG="$WORK/src_log"
_fetch_one_source() { printf 'SRC:%s\n' "$1" >> "$SRC_LOG"; printf 'vless://mock@h:443?type=tcp#M\n'; }
mkdir -p "$HOME"
printf 'https://home/sub\n' > "$HOME/.ocvpn-subs-url"
printf 'https://sys/sub\n' > "$OCVPN_SYS_SUBS_FILE"
: > "$SRC_LOG"
OCVPN_SUBS_URL="https://env/sub" download_subscription "$WORK/d_env" >/dev/null 2>&1
check "subs env > home/sys" "SRC:https://env/sub" "$(cat "$SRC_LOG")"
unset OCVPN_SUBS_URL
: > "$SRC_LOG"; download_subscription "$WORK/d_home" >/dev/null 2>&1
check "subs home > sys" "SRC:https://home/sub" "$(cat "$SRC_LOG")"
rm -f "$HOME/.ocvpn-subs-url"
: > "$SRC_LOG"; download_subscription "$WORK/d_sys" >/dev/null 2>&1
check "subs sys" "SRC:https://sys/sub" "$(cat "$SRC_LOG")"
rm -f "$OCVPN_SYS_SUBS_FILE"
: > "$SRC_LOG"; download_subscription "$WORK/d_fb" >/dev/null 2>&1
check "subs fallback" "SRC:$SUBS_FALLBACK_URL" "$(cat "$SRC_LOG")"
printf 'https://a\n#c\nhttps://b\n' > "$HOME/.ocvpn-subs-url"
: > "$SRC_LOG"; download_subscription "$WORK/d_multi" >/dev/null 2>&1
check "subs несколько строк" "$(printf 'SRC:https://a\nSRC:https://b')" "$(cat "$SRC_LOG")"
rm -f "$HOME/.ocvpn-subs-url"

eval "$SAVE_FETCH_ONE"
printf 'vless://k@h:443?type=tcp#K\njunk\nvless://k@h:443?type=tcp#K\n' > "$WORK/keys.txt"
OCVPN_SUBS_FILE="$WORK/keys.txt" download_subscription "$WORK/d_file" >/dev/null 2>&1; rc=$?
check "download файл rc" "0" "$rc"
check "download uniq" "1" "$(grep -c '^vless' "$WORK/d_file")"
OCVPN_SUBS_FILE="$WORK/nope.txt" download_subscription "$WORK/d_miss" >/dev/null 2>&1; rc=$?
check "download нет файла rc" "1" "$rc"
printf 'no vless here\n' > "$WORK/nokeys.txt"
OCVPN_SUBS_FILE="$WORK/nokeys.txt" download_subscription "$WORK/d_none" >/dev/null 2>&1; rc=$?
check "download нет ключей rc" "1" "$rc"
unset OCVPN_SUBS_FILE
printf 'vless://u1@a:443?type=tcp#A\n' > "$WORK/m_a"
printf 'vless://u2@c:443?type=tcp#C\n%s\n' "$WORK/m_a" > "$WORK/m_list"
OCVPN_SUBS_FILE="$WORK/m_list" download_subscription "$WORK/m_out" >/dev/null 2>&1
check "download несколько источников" "2" "$(grep -c . "$WORK/m_out")"
unset OCVPN_SUBS_FILE
_fetch_one_source() { :; }
download_subscription "$WORK/d_mockempty" >/dev/null 2>&1; rc=$?
check "download пустой источник rc" "1" "$rc"
eval "$SAVE_FETCH_ONE"

echo "=== [5] hosts_setup / hosts_cleanup ==="
printf '# test hosts\n' > "$HOSTS_FILE"
resolve_ipv4() { echo 93.184.216.34; }
OPENCODE_DOMAINS=("stub.example")
hosts_setup >/dev/null 2>&1; rc=$?
check "hosts_setup rc" "0" "$rc"
check "hosts маркер" "1" "$(grep -c "$HOSTS_MARK" "$HOSTS_FILE")"
check "hosts запись" "1" "$(grep -c '^93.184.216.34 *stub.example # opencode-vpn$' "$HOSTS_FILE")"
hosts_setup >/dev/null 2>&1
check "hosts_setup идемпотентен" "1" "$(grep -c 'stub.example' "$HOSTS_FILE")"
printf '1.2.3.4 keepme # other\n9.9.9.9 x # opencode-vpn\n' >> "$HOSTS_FILE"
hosts_cleanup >/dev/null 2>&1
check "hosts_cleanup оставил чужие" "1" "$(grep -c 'keepme' "$HOSTS_FILE")"
check "hosts_cleanup убрал маркер" "0" "$(grep -c "$HOSTS_MARK" "$HOSTS_FILE" || true)"
printf '# untouched\n' > "$HOSTS_FILE"
touch -t 200001010000 "$HOSTS_FILE"
mt1="$(stat -c %Y "$HOSTS_FILE")"
hosts_cleanup >/dev/null 2>&1
mt2="$(stat -c %Y "$HOSTS_FILE")"
check "hosts_cleanup не трогает без записей" "$mt1" "$mt2"
rm -f "$HOSTS_FILE"
hosts_cleanup >/dev/null 2>&1; rc=$?
check "hosts_cleanup нет файла rc" "0" "$rc"
printf '# test hosts\n' > "$HOSTS_FILE"
resolve_ipv4() { :; }
OPENCODE_DOMAINS=("nope.example")
hosts_setup >/dev/null 2>&1
check "hosts_setup без IP не пишет" "0" "$(grep -c "$HOSTS_MARK" "$HOSTS_FILE" || true)"
eval "$SAVE_RESOLVE_IPV4"
OPENCODE_DOMAINS=("stub.example")

echo "=== [6] маршруты Linux (iptables) ==="
IPT_CALLS="$WORK/ipt"; : > "$IPT_CALLS"
iptables() {
    printf 'ipt %s\n' "$*" >> "$IPT_CALLS"
    [[ "$*" == *"-S OUTPUT"* ]] && printf -- '-A OUTPUT -p tcp -j %s\n' "$IPTABLES_CHAIN"
    [[ "$*" == *"--pid-owner"* ]] && return 1
    return 0
}
hosts_setup() { printf 'hosts_setup\n' >> "$IPT_CALLS"; }
hosts_cleanup() { printf 'hosts_cleanup\n' >> "$IPT_CALLS"; }
resolve_domains() { printf '1.1.1.1\n2.2.2.2\n'; }
XRAY_PID=$$
( setup_routes_linux >/dev/null 2>&1 ); rc=$?
check "setup_routes_linux rc" "0" "$rc"
check "цепь создана" "1" "$(grep -c -- '-N OPENCODE_VPN' "$IPT_CALLS")"
check "RETURN 0.0.0.0/8" "1" "$(grep -c -- '-d 0.0.0.0/8 -j RETURN' "$IPT_CALLS")"
check "RETURN 10.0.0.0/8" "1" "$(grep -c -- '-d 10.0.0.0/8 -j RETURN' "$IPT_CALLS")"
check "RETURN 100.64.0.0/10" "1" "$(grep -c -- '-d 100.64.0.0/10 -j RETURN' "$IPT_CALLS")"
check "RETURN 169.254.0.0/16" "1" "$(grep -c -- '-d 169.254.0.0/16 -j RETURN' "$IPT_CALLS")"
check "RETURN 192.168.0.0/16" "1" "$(grep -c -- '-d 192.168.0.0/16 -j RETURN' "$IPT_CALLS")"
check "RETURN мультикаст" "1" "$(grep -c -- '-d 224.0.0.0/4 -j RETURN' "$IPT_CALLS")"
check "REDIRECT на REDIRECT_PORT" "2" "$(grep -c -- "--dport 443 -j REDIRECT --to-ports $REDIRECT_PORT" "$IPT_CALLS")"
check "OUTPUT подключён" "1" "$(grep -c -- '-A OUTPUT -p tcp -j OPENCODE_VPN' "$IPT_CALLS")"
check "xray pid-owner правило" "1" "$(grep -c -- "--pid-owner $XRAY_PID -j RETURN" "$IPT_CALLS")"
check "hosts_setup вызван" "1" "$(grep -c '^hosts_setup$' "$IPT_CALLS")"
( setup_routes_linux >/dev/null 2>"$WORK/err_pidowner" )
check_true "warn: pid-owner не поддержан" grep -q 'не поддержан' "$WORK/err_pidowner"

iptables() {
    printf 'ipt %s\n' "$*" >> "$IPT_CALLS"
    [[ "$*" == *"-S OUTPUT"* ]] && printf -- '-A OUTPUT -p tcp -j %s\n' "$IPTABLES_CHAIN"
    return 0
}
out="$(setup_routes_linux 2>/dev/null)"
check_true "pid-owner поддержан: залогирован" bash -c 'grep -q "исключён трафик самого xray" <<<"$1"' _ "$out"
iptables() {
    printf 'ipt %s\n' "$*" >> "$IPT_CALLS"
    [[ "$*" == *"-S OUTPUT"* ]] && printf -- '-A OUTPUT -p tcp -j %s\n' "$IPTABLES_CHAIN"
    [[ "$*" == *"--pid-owner"* ]] && return 1
    return 0
}

: > "$IPT_CALLS"
cleanup_routes_linux >/dev/null 2>&1; rc=$?
check "cleanup_routes_linux rc" "0" "$rc"
check "cleanup -F" "1" "$(grep -c -- '-F OPENCODE_VPN' "$IPT_CALLS")"
check "cleanup -D OUTPUT" "1" "$(grep -c -- '-D OUTPUT -p tcp -j OPENCODE_VPN' "$IPT_CALLS")"
check "cleanup -X" "1" "$(grep -c -- '-X OPENCODE_VPN' "$IPT_CALLS")"
check "cleanup hosts_cleanup" "1" "$(grep -c '^hosts_cleanup$' "$IPT_CALLS")"

: > "$IPT_CALLS"
( resolve_domains() { :; }; setup_routes_linux >/dev/null 2>&1 ); rc=$?
check "setup_routes_linux нет IP -> exit 1" "1" "$rc"
check_true "нет IP: цепь откатывается" bash -c "grep -q -- '-X OPENCODE_VPN' '$IPT_CALLS'"
eval "$SAVE_HOSTS_SETUP"; eval "$SAVE_HOSTS_CLEANUP"; eval "$SAVE_RESOLVE_DOMAINS"

echo "=== [7] маршруты macOS (pf) ==="
PF_CALLS="$WORK/pfcalls"; : > "$PF_CALLS"
pfctl() { printf 'pfctl %s\n' "$*" >> "$PF_CALLS"; return 0; }
hosts_setup() { printf 'hosts_setup\n' >> "$PF_CALLS"; }
hosts_cleanup() { printf 'hosts_cleanup\n' >> "$PF_CALLS"; }
resolve_domains() { printf '2.2.2.2\n1.1.1.1\n2.2.2.2\n'; }
OCVPN_OS="Darwin"
content="$(pf_anchor_content)"
check "pf table одной строкой" "table <ocvpn_targets> persist { 1.1.1.1, 2.2.2.2 }" \
    "$(printf '%s\n' "$content" | sed -n 1p)"
check "pf rdr на REDIRECT_PORT" "1" \
    "$(printf '%s\n' "$content" | grep -c "rdr pass on lo0 proto tcp from any to <ocvpn_targets> port 443 -> 127.0.0.1 port $REDIRECT_PORT")"
check "pf route-to" "1" "$(printf '%s\n' "$content" | grep -c 'route-to (lo0 127.0.0.1)')"

printf 'scrub-anchor "x"\nrdr-anchor "a" 1\nanchor "b"\n' > "$PF_CONF"
pf_ensure_refs
pf_ensure_refs
check "pf refs идемпотентны" "3" "$(grep -c -- "$PF_MARK" "$PF_CONF")"
check "pf rdr-anchor до anchor" "1" \
    "$(awk '/rdr-anchor .*com.otumanov.ocvpn/{r=NR} /^anchor .*com.otumanov.ocvpn/{a=NR} END{print (r>0 && a>0 && r<a)?1:0}' "$PF_CONF")"
check_true "pf бэкап создан" test -f "${PF_CONF}.ocvpn-bak"
pf_remove_refs
check "pf_remove_refs" "0" "$(grep -c -- "$PF_MARK" "$PF_CONF" || true)"
rm -f "$PF_CONF"
pf_remove_refs >/dev/null 2>&1; rc=$?
check "pf_remove_refs нет файла rc" "0" "$rc"
: > "$PF_CONF"
pf_ensure_refs
check "pf_ensure_refs пустой conf" "3" "$(grep -c -- "$PF_MARK" "$PF_CONF")"

: > "$PF_CONF"; : > "$PF_CALLS"; : > "$PF_ANCHOR_FILE"
( setup_routes_darwin >/dev/null 2>&1 ); rc=$?
check "setup_routes_darwin rc" "0" "$rc"
check_true "pf anchor file создан" test -s "$PF_ANCHOR_FILE"
check "setup pf refs" "3" "$(grep -c -- "$PF_MARK" "$PF_CONF")"
check "setup hosts_setup" "1" "$(grep -c '^hosts_setup$' "$PF_CALLS")"
check_true "pfctl -e вызван" grep -q -- '-e' "$PF_CALLS"
check_true "pfctl -f вызван" grep -q -- "-f $PF_CONF" "$PF_CALLS"

pfctl() { printf 'pfctl %s\n' "$*" >> "$PF_CALLS"; [[ "${1:-}" == "-f" ]] && return 1; return 0; }
: > "$PF_CONF"
( setup_routes_darwin >/dev/null 2>&1 ); rc=$?
check "setup_routes_darwin pfctl -f fail -> exit 1" "1" "$rc"
pfctl() { printf 'pfctl %s\n' "$*" >> "$PF_CALLS"; return 0; }
( resolve_domains() { :; }; setup_routes_darwin >/dev/null 2>&1 ); rc=$?
check "setup_routes_darwin нет IP -> exit 1" "1" "$rc"

: > "$PF_CALLS"; : > "$PF_CONF"; : > "$PF_ANCHOR_FILE"
printf 'anchor "com.otumanov.ocvpn" # ocvpn anchor\n' > "$PF_CONF"
( cleanup_routes_darwin >/dev/null 2>&1 ); rc=$?
check "cleanup_routes_darwin rc" "0" "$rc"
check "cleanup удалил anchor file" "0" "$([[ -f "$PF_ANCHOR_FILE" ]] && echo 1 || echo 0)"
check "cleanup удалил refs" "0" "$(grep -c -- "$PF_MARK" "$PF_CONF" || true)"
check "cleanup hosts_cleanup" "1" "$(grep -c '^hosts_cleanup$' "$PF_CALLS")"
check_true "cleanup pfctl -f" grep -q -- "-f $PF_CONF" "$PF_CALLS"
eval "$SAVE_HOSTS_SETUP"; eval "$SAVE_HOSTS_CLEANUP"; eval "$SAVE_RESOLVE_DOMAINS"
OCVPN_OS="Linux"

echo "=== [8] диспетчеры setup_routes / cleanup_routes ==="
check "dispatch darwin setup" "D" \
    "$( OCVPN_OS=Darwin; setup_routes_darwin() { echo D; }; setup_routes )"
check "dispatch darwin cleanup" "DC" \
    "$( OCVPN_OS=Darwin; cleanup_routes_darwin() { echo DC; }; cleanup_routes )"
check "dispatch linux setup" "L" \
    "$( OCVPN_OS=Linux; setup_routes_linux() { echo L; }; setup_routes )"
check "dispatch linux cleanup" "LC" \
    "$( OCVPN_OS=Linux; cleanup_routes_linux() { echo LC; }; cleanup_routes )"

echo "=== [9] parse_subs_flag ==="
K="$WORK/k.txt"; printf 'vless://u@h:443#x\n' > "$K"
subs_probe() {
    ( parse_subs_flag "$@" >/dev/null 2>&1
      printf 'rc=%s FILE=%s URL=%s FLAG=%s' "$?" "${OCVPN_SUBS_FILE:-}" "${OCVPN_SUBS_URL:-}" "${OCVPN_SUBS_FROM_FLAG:-}" )
}
check "subs файл" "rc=0 FILE=$K URL= FLAG=" "$(subs_probe --subs "$K")"
check "subs url" "rc=0 FILE= URL=https://e/x FLAG=1" "$(subs_probe --subs https://e/x)"
check "subs url в середине" "rc=0 FILE= URL=https://e/y FLAG=1" \
    "$(subs_probe --daemon --subs https://e/y --cleanup)"
check "subs файл в конце" "rc=0 FILE=$K URL= FLAG=" "$(subs_probe --daemon --subs "$K")"
check "subs нет флага" "rc=0 FILE= URL= FLAG=" "$(subs_probe --daemon --status)"
check "subs мусор -> 2" "2" "$( ( parse_subs_flag --subs nope ) >/dev/null 2>&1; echo $? )"
check "subs без значения -> 2" "2" "$( ( parse_subs_flag --subs ) >/dev/null 2>&1; echo $? )"

finish
