#!/usr/bin/env bash
# Покрытийные тесты ocvpn.sh: do_status, do_restart, find_xray, ping_host,
# parse_subs_flag, is_supported_key, normalize_subs_url, resolve_ipv4,
# download_subscription, _fetch_one_source, stop_all, cleanup, pf_ensure_refs
# и РЕАЛЬНЫЕ тела _kill_matching/_kill_matching9.
# Хост не трогаем: изоляция/моки из tests/lib.sh. Ветки main — в subshell со
# стабами; реальные _kill_matching* вызываются только с замоканными pgrep/kill.
. "$(dirname "$0")/lib.sh"

# --- хелперы САМОГО теста (никаких bash -c для функций ocvpn) ---
proc_alive() { kill -0 "$1" 2>/dev/null; }
proc_dead()  { ! kill -0 "$1" 2>/dev/null; }

# --- хелперы для _fetch_one_source: локальный мок curl в subshell ---
fetch_url() { # raw_file url
    local F="$1" u="$2"
    (
        curl() {
            local o=""
            while [[ $# -gt 0 ]]; do case "$1" in -o) o="$2"; shift 2 ;; *) shift ;; esac; done
            if [[ -n "$o" ]]; then cp "$F" "$o"; else cat "$F"; fi
            return 0
        }
        _fetch_one_source "$u"
    )
}
fetch_url_rc() { # raw_file url -> rc
    local F="$1" u="$2"
    (
        curl() {
            local o=""
            while [[ $# -gt 0 ]]; do case "$1" in -o) o="$2"; shift 2 ;; *) shift ;; esac; done
            cp "$F" "$o"
            return 0
        }
        _fetch_one_source "$u" >/dev/null 2>&1
    )
}
fetch_url_curlfail_rc() {
    ( curl() { return 1; }; _fetch_one_source https://ex/sub >/dev/null 2>&1 )
}
fetch_url_log() { # raw_file url logfile
    local F="$1" u="$2" L="$3"
    (
        curl() {
            printf '%s\n' "$*" >> "$L"
            local o=""
            while [[ $# -gt 0 ]]; do case "$1" in -o) o="$2"; shift 2 ;; *) shift ;; esac; done
            cp "$F" "$o"
            return 0
        }
        _fetch_one_source "$u"
    )
}

# --- хелперы для find_xray ---
find_xray_probe() { # arch home log -> $XRAY_BIN
    # имена с префиксом __fx_, иначе find_xray (local arch) зашэдоуит их в
    # динамической области видимости bash, и мок uname упадёт на set -u.
    local __fx_arch="$1" __fx_home="$2" __fx_log="$3"
    (
        HOME="$__fx_home"; PATH="/usr/bin:/bin"; XRAY_BIN=""; OCVPN_OS="Darwin"
        uname() { echo "$__fx_arch"; }
        curl() {
            printf '%s\n' "$*" >> "$__fx_log"
            local o=""
            while [[ $# -gt 0 ]]; do case "$1" in -o) o="$2"; shift 2 ;; *) shift ;; esac; done
            if [[ -n "$o" ]]; then : > "$o"; else echo '{"tag_name":"v1.2.3"}'; fi
            return 0
        }
        unzip() {
            local d=""
            while [[ $# -gt 0 ]]; do case "$1" in -d) d="$2"; shift 2 ;; *) shift ;; esac; done
            [[ -n "$d" ]] && printf '#!/bin/bash\n' > "$d/xray" && chmod +x "$d/xray"
            return 0
        }
        find_xray >/dev/null 2>&1
        echo "$XRAY_BIN"
    )
}

# --- хелперы для РЕАЛЬНЫХ тел _kill_matching / _kill_matching9 ---
_km_real() { # mode pat out
    local mode="$1" pat="$2" out="$3"
    (
        source "$OCVPN_SCRIPT" >/dev/null 2>&1
        trap - EXIT
        pgrep() { printf '11111\n22222\n'; }
        kill() { printf '%s\n' "$*" >> "$out"; return 0; }
        if [[ "$mode" == "9" ]]; then _kill_matching9 "$pat"; else _kill_matching "$pat"; fi
        exit 0
    ) 2>/dev/null || true
}
_km_self_real() { # out: pgrep печатает $$ (должен быть исключён) + 33333
    local out="$1"
    (
        source "$OCVPN_SCRIPT" >/dev/null 2>&1
        trap - EXIT
        pgrep() { printf '%s\n33333\n' "$$"; }
        kill() { printf '%s\n' "$*" >> "$out"; return 0; }
        _kill_matching pat
        exit 0
    ) 2>/dev/null || true
}
_km_empty_real() { # out: pgrep печатает пустую строку + 44444
    local out="$1"
    (
        source "$OCVPN_SCRIPT" >/dev/null 2>&1
        trap - EXIT
        pgrep() { printf '\n44444\n'; }
        kill() { printf '[%s]\n' "$*" >> "$out"; return 0; }
        _kill_matching pat
        exit 0
    ) 2>/dev/null || true
}

# ===========================================================================
echo "=== [S-a] normalize_subs_url ==="
check "blob https" "https://raw.githubusercontent.com/u/r/main/f.txt" \
    "$(normalize_subs_url 'https://github.com/u/r/blob/main/f.txt')"
check "blob http" "https://raw.githubusercontent.com/u/r/main/f.txt" \
    "$(normalize_subs_url 'http://github.com/u/r/blob/main/f.txt')"
check "raw" "https://raw.githubusercontent.com/u/r/br/f.txt" \
    "$(normalize_subs_url 'https://github.com/u/r/raw/br/f.txt')"
check "обычный URL" "https://example.com/x" "$(normalize_subs_url 'https://example.com/x')"
check "не github" "vless://u@h:443#x" "$(normalize_subs_url 'vless://u@h:443#x')"
check "пусто" "" "$(normalize_subs_url '')"

echo "=== [S-b] is_supported_key ==="
check "vmess"  "0" "$(is_supported_key 'vmess://x'; echo $?)"
check "ss"     "0" "$(is_supported_key 'ss://x'; echo $?)"
check "http"   "0" "$(is_supported_key 'http://u:p@h:8080'; echo $?)"
check "https"  "0" "$(is_supported_key 'https://u:p@h:8080'; echo $?)"
check "socks"  "0" "$(is_supported_key 'socks://h:1080'; echo $?)"
check "socks5" "0" "$(is_supported_key 'socks5://h:1080'; echo $?)"
check "socks5h" "0" "$(is_supported_key 'socks5h://h:1080'; echo $?)"
check "vless tcp"     "0" "$(is_supported_key 'vless://u@h:443?type=tcp#x'; echo $?)"
check "vless default tcp" "0" "$(is_supported_key 'vless://u@h:443#x'; echo $?)"
check "vless raw"     "0" "$(is_supported_key 'vless://u@h:443?type=raw#x'; echo $?)"
check "vless ws"      "0" "$(is_supported_key 'vless://u@h:443?type=ws#x'; echo $?)"
check "vless grpc"    "0" "$(is_supported_key 'vless://u@h:443?type=grpc#x'; echo $?)"
check "vless xhttp"   "0" "$(is_supported_key 'vless://u@h:443?type=xhttp#x'; echo $?)"
check "vless bad type" "1" "$(is_supported_key 'vless://u@h:443?type=quic#x'; echo $?)"
check "vless extra="   "1" "$(is_supported_key 'vless://u@h:443?type=xhttp&extra=packet-up#x'; echo $?)"
check "trojan ws"      "0" "$(is_supported_key 'trojan://p@h:443?type=ws#x'; echo $?)"
check "unknown scheme" "1" "$(is_supported_key 'hysteria2://u@h:443#x'; echo $?)"
check "empty"          "1" "$(is_supported_key ''; echo $?)"

echo "=== [S-c] parse_subs_flag ==="
K="$WORK/k.txt"; printf 'vless://u@h:443#x\n' > "$K"
subs_probe() {
    ( parse_subs_flag "$@" >/dev/null 2>&1
      printf 'rc=%s FILE=%s URL=%s FLAG=%s' "$?" \
        "${OCVPN_SUBS_FILE:-}" "${OCVPN_SUBS_URL:-}" "${OCVPN_SUBS_FROM_FLAG:-}" )
}
check "subs файл"      "rc=0 FILE=$K URL= FLAG=" "$(subs_probe --subs "$K")"
check "subs url"       "rc=0 FILE= URL=https://e/x FLAG=1" "$(subs_probe --subs https://e/x)"
check "subs url в середине" "rc=0 FILE= URL=https://e/y FLAG=1" \
    "$(subs_probe --daemon --subs https://e/y --cleanup)"
check "subs нет флага" "rc=0 FILE= URL= FLAG=" "$(subs_probe --daemon --status)"
check "subs мусор -> 2" "2" "$( ( parse_subs_flag --subs nope ) >/dev/null 2>&1; echo $? )"
check "subs без значения -> 2" "2" "$( ( parse_subs_flag --subs ) >/dev/null 2>&1; echo $? )"

echo "=== [S-d] resolve_ipv4 ==="
check "mac dscacheutil" "93.184.216.34" \
    "$( OCVPN_OS=Darwin; dscacheutil() { printf 'name: x\nip_address: 93.184.216.34\nip_address: 93.184.216.34\n'; }; dig() { :; }; resolve_ipv4 x )"
check "mac dig fallback" "1.2.3.4" \
    "$( OCVPN_OS=Darwin; dscacheutil() { :; }; dig() { printf '1.2.3.4\n::1\n'; }; resolve_ipv4 x )"
check "mac пусто" "" \
    "$( OCVPN_OS=Darwin; dscacheutil() { :; }; dig() { :; }; resolve_ipv4 x )"
check "linux getent" "$(printf '1.1.1.1\n5.6.7.8')" \
    "$( OCVPN_OS=Linux; getent() { printf '5.6.7.8  STREAM\n5.6.7.8  DGRAM\n1.1.1.1 STREAM\n'; }; resolve_ipv4 stub )"

echo "=== [S-e] ping_host ==="
python3 -c "import socket,threading; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',34567)); s.listen(1); threading.Event().wait(3)" &
LP=$!
sleep 0.4
PING_TIMEOUT=1
check "live"  "1" "$(ping_host 127.0.0.1 34567 | awk '{print ($1<99999)}')"
check "dead"  "99999 10.255.255.1 443" "$(ping_host 10.255.255.1 443)"
kill "$LP" 2>/dev/null || true
wait "$LP" 2>/dev/null || true
PING_TIMEOUT=3

echo "=== [S-f] find_xray ==="
mkdir -p "$WORK/fxbin"
printf '#!/bin/bash\n' > "$WORK/fxbin/xray"; chmod +x "$WORK/fxbin/xray"
check "найден в PATH" "xray" \
    "$( XRAY_BIN=""; PATH="$WORK/fxbin:$PATH"; find_xray >/dev/null 2>&1; echo "$XRAY_BIN" )"

# mac arm64 -> asset macos-arm64-v8a
: > "$WORK/mac_arm.log"
out="$(find_xray_probe arm64 "$WORK/fxmac" "$WORK/mac_arm.log")"
check "mac arm64 установил" "$WORK/fxmac/bin/xray" "$out"
check_true "mac arm64 URL" grep -q 'Xray-macos-arm64-v8a.zip' "$WORK/mac_arm.log"

# mac x86_64 -> asset macos-64
: > "$WORK/mac_x64.log"
out="$(find_xray_probe x86_64 "$WORK/fxmac64" "$WORK/mac_x64.log")"
check "mac x86_64 установил" "$WORK/fxmac64/bin/xray" "$out"
check_true "mac x86_64 URL" grep -q 'Xray-macos-64.zip' "$WORK/mac_x64.log"

# неподдерживаемая архитектура (linux / macos)
check "linux bad arch rc" "1" \
    "$( ( HOME="$WORK/fxlbad"; PATH="/usr/bin:/bin"; OCVPN_OS=Linux; uname() { echo sparc; }; find_xray ) >/dev/null 2>&1; echo $? )"

check "mac bad arch rc" "1" \
    "$( ( HOME="$WORK/fxmbad"; PATH="/usr/bin:/bin"; OCVPN_OS=Darwin; uname() { echo i386; }; find_xray ) >/dev/null 2>&1; echo $? )"

# не удалось определить версию
check "version fail rc" "1" \
    "$( ( HOME="$WORK/fxver"; PATH="/usr/bin:/bin"; OCVPN_OS=Linux; uname() { echo x86_64; }; curl() { return 1; }; find_xray ) >/dev/null 2>&1; echo $? )"

# не удалось скачать
check "download fail rc" "1" \
    "$( ( HOME="$WORK/fxdl"; PATH="/usr/bin:/bin"; OCVPN_OS=Linux; uname() { echo x86_64; }
         curl() { local o=""; while [[ $# -gt 0 ]]; do case "$1" in -o) o="$2"; shift 2 ;; *) shift ;; esac; done; if [[ -n "$o" ]]; then return 1; else echo '{"tag_name":"v1.2.3"}'; fi; }
         find_xray ) >/dev/null 2>&1; echo $? )"

# нет unzip (PATH с python3, но без unzip)
mkdir -p "$WORK/fxpybin"; ln -sf "$(command -v python3)" "$WORK/fxpybin/python3"
check "no unzip rc" "1" \
    "$( ( HOME="$WORK/fxnounzip"; PATH="$WORK/fxpybin"; OCVPN_OS=Linux; uname() { echo x86_64; }
         curl() { echo '{"tag_name":"v1.2.3"}'; }
         find_xray ) >/dev/null 2>&1; echo $? )"

# сообщение про неподдерживаемую архитектуру
( HOME="$WORK/fxlbad2"; PATH="/usr/bin:/bin"; OCVPN_OS=Linux; uname() { echo sparc; }; find_xray ) \
    > "$WORK/fxlbad2.out" 2>&1
check_true "linux bad arch msg" grep -q "Неподдерживаемая архитектура" "$WORK/fxlbad2.out"

echo "=== [S-g] _kill_matching / _kill_matching9 (РЕАЛЬНЫЕ тела) ==="
: > "$WORK/km.log"
_km_real "" "SOME_PAT" "$WORK/km.log"
check "kill_matching pid1" "1" "$(grep -c '^11111$' "$WORK/km.log")"
check "kill_matching pid2" "1" "$(grep -c '^22222$' "$WORK/km.log")"

: > "$WORK/km9.log"
_km_real "9" "SOME_PAT" "$WORK/km9.log"
check "kill_matching9 -9 pid1" "1" "$(grep -c '^-9 11111$' "$WORK/km9.log")"
check "kill_matching9 -9 pid2" "1" "$(grep -c '^-9 22222$' "$WORK/km9.log")"

: > "$WORK/km_self.log"
_km_self_real "$WORK/km_self.log"
check "kill_matching исключил себя" "0" "$(grep -c "^$(printf '%s' "$$")$" "$WORK/km_self.log")"
check "kill_matching убил остальных" "1" "$(grep -c '^33333$' "$WORK/km_self.log")"

: > "$WORK/km_empty.log"
_km_empty_real "$WORK/km_empty.log"
check "kill_matching пустой pid пропущен" "0" "$(grep -c '^\[\]$' "$WORK/km_empty.log")"
check "kill_matching непустой pid убит" "1" "$(grep -c '^\[44444\]$' "$WORK/km_empty.log")"

echo "=== [S-h] pf_ensure_refs ==="
# уже есть маркер -> no-op rc 0
printf 'rdr-anchor "x" %s\n' "$PF_MARK" > "$PF_CONF"
before="$(cat "$PF_CONF")"
pf_ensure_refs; rc=$?
check "already refs rc" "0" "$rc"
check "already refs unchanged" "$before" "$(cat "$PF_CONF")"

# нет ни rdr-anchor, ни anchor -> вставляем 3 строки
printf 'scrub-anchor "x"\n' > "$PF_CONF"
rm -f "${PF_CONF}.ocvpn-bak"
pf_ensure_refs; rc=$?
check "empty conf rc" "0" "$rc"
check "empty conf 3 marks" "3" "$(grep -c -- "$PF_MARK" "$PF_CONF")"
check_true "backup создан" test -f "${PF_CONF}.ocvpn-bak"

# есть rdr-anchor без filter anchor -> наш rdr-anchor сразу после него, anchor в конце
printf 'rdr-anchor "a"\nother\n' > "$PF_CONF"
pf_ensure_refs
check "rdr до anchor" "1" \
    "$(awk '/rdr-anchor .*com.otumanov.ocvpn/{r=NR} /^anchor .*com.otumanov.ocvpn/{a=NR} END{print (r>0 && a>0 && r<a)?1:0}' "$PF_CONF")"
check "refs count после вставки" "3" "$(grep -c -- "$PF_MARK" "$PF_CONF")"

# идемпотентность
pf_ensure_refs
check "идемпотентно 3 marks" "3" "$(grep -c -- "$PF_MARK" "$PF_CONF")"

echo "=== [S-i] stop_all ==="
exec -a 'fake-xray run -c /tmp/opencode-vpn/STOP/config.json' /bin/sleep 30 & SP=$!
exec -a 'fake-ocvpn-watchdog' /bin/sleep 30 & SW=$!
sleep 0.3
printf 'HOLDER_PID=999999\nXRAY_PID=%s\n' "$SP" > "$ACTIVE_FILE"
printf '%s\n' "$SW" > "$WATCH_PIDFILE"
printf 'x\n' > "$LAST_ROTATE_FILE"
printf 'x\n' > "$REASON_FILE"
printf 'x\n' > "$ROTATE_HOUR_FILE"
stop_all
sleep 0.4
check_true "stop_all fake-xray мёртв" proc_dead "$SP"
check_true "stop_all watchdog мёртв" proc_dead "$SW"
check_true "stop_all удалил active.env" test ! -f "$ACTIVE_FILE"
check_true "stop_all удалил watch.pid" test ! -f "$WATCH_PIDFILE"
check_true "stop_all удалил last_rotate" test ! -f "$LAST_ROTATE_FILE"
check_true "stop_all удалил reason" test ! -f "$REASON_FILE"
check_true "stop_all удалил rotate_hour" test ! -f "$ROTATE_HOUR_FILE"
kill -9 "$SP" "$SW" 2>/dev/null || true
wait "$SP" "$SW" 2>/dev/null || true

echo "=== [S-j] cleanup ==="
check "no-op rc" "0" "$( ( unset TMPDIR XRAY_PID OCVPN_OWNER; cleanup ); echo $? )"

exec -a 'fake-xray cleanup' /bin/sleep 30 & CP=$!
sleep 0.3
( TMPDIR="$WORK/cleanme"; mkdir -p "$TMPDIR"; XRAY_PID=$CP; OCVPN_OWNER=1; cleanup ) >/dev/null 2>&1
sleep 0.3
check_true "cleanup убил XRAY_PID" proc_dead "$CP"
check_true "cleanup снёс TMPDIR" test ! -d "$WORK/cleanme"
wait "$CP" 2>/dev/null || true

: > "$WORK/cr_keep.log"
( TMPDIR="$WORK/keepme"; mkdir -p "$TMPDIR"; XRAY_PID=""; OCVPN_OWNER=1; KEEP_ROUTES=1; \
  cleanup_routes() { echo cr >> "$WORK/cr_keep.log"; }; cleanup ) >/dev/null 2>&1
check "cleanup KEEP_ROUTES не зовёт маршруты" "0" "$(grep -c cr "$WORK/cr_keep.log")"
check_true "cleanup KEEP_ROUTES всё равно снёс TMPDIR" test ! -d "$WORK/keepme"

echo "=== [S-k] do_status ==="
# (1) всё хорошо: xray жив, active.env, hosts-маркер, карантин, вотчдог, маршруты, exit IP
printf '# opencode-vpn\n' >> "$HOSTS_FILE"
printf 'ACTIVE_LABEL=Node-7\nACTIVE_HOST=h7.example\nACTIVE_PORT=8443\nXRAY_PID=%s\n' "$$" > "$ACTIVE_FILE"
printf '%s\n' "$$" > "$WATCH_PIDFILE"
printf 'h\t443\t1.2.3.4\t9999999999\treason\n' > "$QUARANTINE_FILE"
out="$(
    pgrep() { case "$*" in *xray*) printf '1\n2\n3\n'; return 0 ;; *) return 1 ;; esac; }
    ss() { printf 'LISTEN 0 128 127.0.0.1:10808 0.0.0.0:*\nLISTEN 0 128 127.0.0.1:10809 0.0.0.0:*\nLISTEN 0 128 127.0.0.1:12345 0.0.0.0:*\n'; }
    iptables() { [[ "$*" == *"-S OUTPUT"* ]] && printf -- '-A OUTPUT -p tcp -j %s\n' "$IPTABLES_CHAIN"; return 0; }
    curl() { echo 5.6.7.8; }
    OCVPN_OS=Linux do_status
)"; rc=$?
check_true "st1 version"   grep -q "ocvpn $OCVPN_VERSION" <<<"$out"
check_true "st1 xray жив"  grep -q "xray: запущен (3 проц.)" <<<"$out"
check_true "st1 label"     grep -q "ключ: Node-7 (h7.example:8443)" <<<"$out"
check_true "st1 routes"    grep -q "маршруты (iptables $IPTABLES_CHAIN): есть" <<<"$out"
check_true "st1 hosts"     grep -q "IPv4-записи есть" <<<"$out"
check_true "st1 exit IP"   grep -q "exit IP: 5.6.7.8" <<<"$out"
check_true "st1 карантин"  grep -q "карантин: 1 записей" <<<"$out"
check_true "st1 вотчдог"   grep -q "вотчдог: запущен (pid $$)" <<<"$out"
check "st1 rc" "0" "$rc"

# (2) всё выключено / пусто
rm -f "$ACTIVE_FILE" "$WATCH_PIDFILE" "$QUARANTINE_FILE"
grep -v 'opencode-vpn' "$HOSTS_FILE" > "$WORK/h.nomark" 2>/dev/null || true
mv "$WORK/h.nomark" "$HOSTS_FILE"
out="$(
    pgrep() { return 1; }
    ss() { :; }
    iptables() { :; }
    OCVPN_OS=Linux do_status
)"; rc=$?
check_true "st2 xray мёртв" grep -q "xray: НЕ запущен" <<<"$out"
check_true "st2 нет ключа"  grep -q "ключ: нет активного" <<<"$out"
check_true "st2 routes нет" grep -q "маршруты (iptables $IPTABLES_CHAIN): нет" <<<"$out"
check_true "st2 hosts нет"  grep -q "IPv4-записей нет" <<<"$out"
check_true "st2 exit IP недоступен" grep -q "exit IP: недоступен" <<<"$out"
check_true "st2 вотчдог выкл" grep -q "вотчдог: выключен" <<<"$out"
check "st2 rc" "1" "$rc"

# (3) active.env без label/host/port -> подстановки "?"
printf 'ACTIVE_HOST=\nACTIVE_PORT=\n' > "$ACTIVE_FILE"
out="$( pgrep() { return 1; }; do_status 2>&1 )"
check_true "st3 label-заглушки" grep -qF "ключ: ? (?:?)" <<<"$out"
rm -f "$ACTIVE_FILE"

# (4) macOS: маршруты pf (pfctl) и fallback по файлу якоря
out="$( OCVPN_OS=Darwin; pgrep() { return 1; }; pfctl() { echo 'rdr pass on lo0 proto tcp to <ocvpn_targets>'; }; do_status 2>&1 )"
check_true "st4 mac pf есть" grep -q "маршруты (pf $PF_ANCHOR): есть" <<<"$out"
: > "$PF_ANCHOR_FILE"; printf 'x ocvpn_targets\n' > "$PF_ANCHOR_FILE"
out="$( OCVPN_OS=Darwin; pgrep() { return 1; }; pfctl() { :; }; do_status 2>&1 )"
check_true "st4 mac anchor file fallback" grep -q "маршруты (pf $PF_ANCHOR): есть" <<<"$out"
rm -f "$PF_ANCHOR_FILE"

echo "=== [S-l] do_restart ==="
# (1) успех: фоновый _spawn пишет свежий active.env, процесс жив
# SOCKS_PORT=1 (заведомо закрыт) — иначе do_restart 15с ждёт «освобождения»
# живого хостового SOCKS-порта, а также из-за бага 1730 теряет stderr.
rm -f "$ACTIVE_FILE"
( SOCKS_PORT=1; _spawn() { sleep 5 & echo $! > "$WORK/dr_bg"; printf 'HOLDER_PID=1\nXRAY_PID=1\nACTIVE_LABEL=New\nACTIVE_EXIT_IP=9.9.9.9\nSTARTED=999\n' > "$ACTIVE_FILE"; }
  do_restart > "$WORK/dr1.out" 2>&1; echo "rc=$?" > "$WORK/dr1.rc" )
check "restart успех rc" "rc=0" "$(cat "$WORK/dr1.rc")"
check_true "restart успех msg" grep -q "Готово в фоне: exit IP 9.9.9.9" "$WORK/dr1.out"
kill "$(cat "$WORK/dr_bg" 2>/dev/null)" 2>/dev/null || true
wait "$(cat "$WORK/dr_bg" 2>/dev/null)" 2>/dev/null || true

# (2) провал: фоновый процесс быстро умирает, active.env не появляется.
# ВАЖНО: _spawn обязан реально стартовать фоновое задание — иначе $! не
# выставлен и `local bgpid=$!` под set -u фатально валит шелл.
rm -f "$ACTIVE_FILE"
( SOCKS_PORT=1; _spawn() { sleep 0.1 & }; do_restart > "$WORK/dr2.out" 2>&1; echo "rc=$?" > "$WORK/dr2.rc" )
check "restart провал rc" "rc=1" "$(cat "$WORK/dr2.rc")"
check_true "restart провал msg" grep -q "Фоновый подбор упал" "$WORK/dr2.out"

# (3) живой holder: do_restart его глушит
rm -f "$ACTIVE_FILE"
exec -a 'fake-holder-restart' /bin/sleep 30 & HP=$!
sleep 0.3
printf 'HOLDER_PID=%s\nACTIVE_EXIT_IP=1.1.1.1\nSTARTED=111\n' "$HP" > "$ACTIVE_FILE"
( SOCKS_PORT=1; _spawn() { sleep 0.1 & }; do_restart > "$WORK/dr3.out" 2>&1; echo "rc=$?" > "$WORK/dr3.rc" )
check_true "restart убил holder" proc_dead "$HP"
check_true "restart holder msg" grep -q "Глушу держателя" "$WORK/dr3.out"
kill -9 "$HP" 2>/dev/null || true
wait "$HP" 2>/dev/null || true
rm -f "$ACTIVE_FILE"

echo "=== [S-m] _fetch_one_source ==="
check "key"        "vless://u@h:443#x" "$(_fetch_one_source 'vless://u@h:443#x')"
check "empty"      "" "$(_fetch_one_source '')"
check "comment"    "" "$(_fetch_one_source '#c')"
check "http-прокси" "http://u:p@h:8080#x" "$(_fetch_one_source 'http://u:p@h:8080#x')"
check "unknown rc" "1" "$( { _fetch_one_source 'garbage' >/dev/null 2>&1; echo $?; } )"
printf '# c\nvless://u1@a:443?type=tcp#A\n' > "$WORK/f1"
check "local file" "vless://u1@a:443?type=tcp#A" "$(_fetch_one_source "$WORK/f1")"
printf 'vless://u2@b:443?type=tcp#B\n%s\n' "$WORK/f1" > "$WORK/f2"
check "nested file" "2" "$(_fetch_one_source "$WORK/f2" | grep -c '^vless://')"

printf 'vless://u@h:443?type=tcp#PLAIN\n' > "$WORK/raw_plain"
printf 'vless://u@h:443?type=tcp#B64\n' | base64 > "$WORK/raw_b64"
printf 'nope\n' > "$WORK/raw_garbage"
check "url plain" "vless://u@h:443?type=tcp#PLAIN" "$(fetch_url "$WORK/raw_plain" https://ex/sub)"
check "url base64" "vless://u@h:443?type=tcp#B64" "$(fetch_url "$WORK/raw_b64" https://ex/sub)"
check "url garbage rc" "0" "$(fetch_url_rc "$WORK/raw_garbage" https://ex/sub; echo $?)"
check "url curl-fail rc" "1" "$(fetch_url_curlfail_rc; echo $?)"
: > "$WORK/curl_log"
out="$(fetch_url_log "$WORK/raw_plain" 'https://github.com/u/r/blob/main/f.txt' "$WORK/curl_log")"
check_true "blob -> raw URL" grep -q 'raw.githubusercontent.com/u/r/main/f.txt' "$WORK/curl_log"
check_true "blob content" grep -q '^vless://u@h:443?type=tcp#PLAIN$' <<<"$out"

echo "=== [S-n] download_subscription ==="
SUB_SRC="$WORK/sub_src"; : > "$SUB_SRC"
dl_probe() { # env_url out
    ( _fetch_one_source() { printf 'SRC:%s\n' "$1" >> "$SUB_SRC"; printf 'vless://m@h:443?type=tcp#M\n'; }
      OCVPN_SUBS_URL="$1" download_subscription "$2" >/dev/null 2>&1 )
}
dl_probe_home() { # out
    ( _fetch_one_source() { printf 'SRC:%s\n' "$1" >> "$SUB_SRC"; printf 'vless://m@h:443?type=tcp#M\n'; }
      unset OCVPN_SUBS_URL
      download_subscription "$1" >/dev/null 2>&1 )
}
rm -f "$HOME/.ocvpn-subs-url" "$OCVPN_SYS_SUBS_FILE"
: > "$SUB_SRC"; dl_probe "https://env/sub" "$WORK/d_env"
check "env > home > sys" "SRC:https://env/sub" "$(cat "$SUB_SRC")"
printf 'https://home/sub\n' > "$HOME/.ocvpn-subs-url"
: > "$SUB_SRC"; dl_probe_home "$WORK/d_home"
check "home > sys" "SRC:https://home/sub" "$(cat "$SUB_SRC")"
rm -f "$HOME/.ocvpn-subs-url"
printf 'https://sys/sub\n' > "$OCVPN_SYS_SUBS_FILE"
: > "$SUB_SRC"; dl_probe_home "$WORK/d_sys"
check "sys" "SRC:https://sys/sub" "$(cat "$SUB_SRC")"
rm -f "$OCVPN_SYS_SUBS_FILE"
: > "$SUB_SRC"; dl_probe_home "$WORK/d_fb"
check "fallback" "SRC:$SUBS_FALLBACK_URL" "$(cat "$SUB_SRC")"
printf 'https://a\n#c\nhttps://b\n' > "$HOME/.ocvpn-subs-url"
: > "$SUB_SRC"; dl_probe_home "$WORK/d_multi"
check "несколько строк" "$(printf 'SRC:https://a\nSRC:https://b')" "$(cat "$SUB_SRC")"
rm -f "$HOME/.ocvpn-subs-url"

# файл-источник: dedup поддерживаемых, отсутствие файла, отсутствие ключей
printf 'vless://k@h:443?type=tcp#K\njunk\nvless://k@h:443?type=tcp#K\n' > "$WORK/keys.txt"
( OCVPN_SUBS_FILE="$WORK/keys.txt" download_subscription "$WORK/d_file" >/dev/null 2>&1 ); rc=$?
check "файл rc" "0" "$rc"
check "файл dedup" "1" "$(grep -c '^vless' "$WORK/d_file")"
( OCVPN_SUBS_FILE="$WORK/nope.txt" download_subscription "$WORK/d_miss" >/dev/null 2>&1 ); rc=$?
check "нет файла rc" "1" "$rc"
printf 'no keys here\n' > "$WORK/nokeys.txt"
( OCVPN_SUBS_FILE="$WORK/nokeys.txt" download_subscription "$WORK/d_none" >/dev/null 2>&1 ); rc=$?
check "нет ключей rc" "1" "$rc"

echo "=== [S-o] main (subshell со стабами) ==="
( main --help ) > "$WORK/mh.out" 2>&1; rc=$?
check "main --help rc" "0" "$rc"
check_true "main --help текст" grep -q -- "--new-ip" "$WORK/mh.out"
( main --version ) > "$WORK/mv.out" 2>&1; rc=$?
check "main --version rc" "0" "$rc"
check "main --version текст" "ocvpn $OCVPN_VERSION" "$(cat "$WORK/mv.out")"
( pgrep() { return 1; }; ss() { :; }; iptables() { :; }; main --status ) > "$WORK/ms.out" 2>&1; rc=$?
check_true "main --status rc 0/1" test "$rc" -eq 1 -o "$rc" -eq 0
check_true "main --status текст" grep -q "ocvpn $OCVPN_VERSION" "$WORK/ms.out"
( do_rotate() { echo "ROTATE:$1"; }; main --new-ip why ) > "$WORK/mni.out" 2>&1; rc=$?
check "main --new-ip rc" "0" "$rc"
check "main --new-ip reason" "ROTATE:why" "$(cat "$WORK/mni.out")"
( do_rotate() { echo "ROTATE:$1"; }; main --rotate ) > "$WORK/mr2.out" 2>&1
check "main --rotate default reason" "ROTATE:ручная ротация" "$(cat "$WORK/mr2.out")"
( do_restart() { echo RESTART; }; main --restart ) > "$WORK/mrst.out" 2>&1; rc=$?
check "main --restart rc" "0" "$rc"
check "main --restart text" "RESTART" "$(cat "$WORK/mrst.out")"
( do_watch() { echo WATCH; }; main --watch ) > "$WORK/mw.out" 2>&1; rc=$?
check "main --watch rc" "0" "$rc"
check "main --watch text" "WATCH" "$(cat "$WORK/mw.out")"
( stop_all() { echo STOP; }; cleanup_routes() { echo CLEAN; }; main --cleanup ) > "$WORK/mc.out" 2>&1; rc=$?
check "main --cleanup rc" "0" "$rc"
check "main --cleanup stop" "1" "$(grep -c '^STOP$' "$WORK/mc.out")"
check "main --cleanup routes" "1" "$(grep -c '^CLEAN$' "$WORK/mc.out")"
( _spawn() { echo "SPAWN:$1"; }; main --daemon ) > "$WORK/md.out" 2>&1; rc=$?
check "main --daemon rc" "0" "$rc"
check_true "main --daemon spawn" grep -q '^SPAWN:' "$WORK/md.out"

finish
