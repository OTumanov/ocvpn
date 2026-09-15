#!/usr/bin/env bash
# Покрытие CLI-поверхности ocvpn.sh: пользовательские хосты, apply_hosts_live,
# --help/--status, find_xray, ping_host, _spawn, kill/stop_all/cleanup и
# безопасные ветки main. Харнесс lib.sh изолирует окружение и ограничивает
# убийство процессов только собственными fake-xray/fake-ocvpn.
. "$(dirname "$0")/lib.sh"

# lib.sh вызывает no_cleanup (trap - EXIT) после source ocvpn.sh, поэтому его
# собственный trap _cleanup снимается. Возвращаем уборку: свои фоновые фейки и WORK.
_cov_cleanup() {
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
    done < <(jobs -p 2>/dev/null || true)
    pkill -f "fake-xray" 2>/dev/null || true
    pkill -f "fake-ocvpn" 2>/dev/null || true
    rm -rf "$WORK"
}
trap _cov_cleanup EXIT

# ---------------------------------------------------------------------------
echo "=== [CLI-A] apply_hosts_live (реальные ветки, в subshell) ==="

# (1) VPN не активен: сообщение + rc 0
rm -f "$ACTIVE_FILE"
apply_hosts_live > "$WORK/apply-off.out" 2>&1
check "apply_hosts_live не активен rc" 0 $?
check_true "apply_hosts_live не активен msg" grep -q "VPN не активен" "$WORK/apply-off.out"

# (2) активный файл есть, xray мёртв
printf 'XRAY_PID=424242\n' > "$ACTIVE_FILE"
apply_hosts_live > "$WORK/apply-dead.out" 2>&1
check "apply_hosts_live мёртвый xray rc" 0 $?
check_true "apply_hosts_live мёртвый xray msg" grep -q "Активного xray нет" "$WORK/apply-dead.out"

# (2b) активный файл есть, XRAY_PID пуст
printf 'HOLDER_PID=1\n' > "$ACTIVE_FILE"
apply_hosts_live > "$WORK/apply-nopid.out" 2>&1
check "apply_hosts_live без pid rc" 0 $?
check_true "apply_hosts_live без pid msg" grep -q "Активного xray нет" "$WORK/apply-nopid.out"

# (3) активный + живой xray: setup_routes вызывается
printf 'XRAY_PID=%s\n' "$$" > "$ACTIVE_FILE"
: > "$WORK/setup.log"
( setup_routes() { echo called >> "$WORK/setup.log"; return 0; }; apply_hosts_live ) > "$WORK/apply-live.out" 2>&1
check_true "apply_hosts_live вызвал setup_routes" test -s "$WORK/setup.log"
check_true "apply_hosts_live updated msg" grep -q "Маршрутизация обновлена" "$WORK/apply-live.out"

# (4) setup_routes падает -> warn
( setup_routes() { return 1; }; apply_hosts_live ) > "$WORK/apply-fail.out" 2>&1
check_true "apply_hosts_live warn при ошибке" grep -q "Не удалось обновить маршруты" "$WORK/apply-fail.out"
rm -f "$ACTIVE_FILE"

# ---------------------------------------------------------------------------
echo "=== [CLI-B] add_host / rm_host / hosts_list ==="
# apply_hosts_live изолируем, чтобы add/rm не трогали маршруты
apply_hosts_live() { echo applied >> "$WORK/apply.log"; }
: > "$WORK/apply.log"
UHF="$USER_HOSTS_FILE"
rm -f "$UHF"

# валидация домена
add_host "" > "$WORK/v-empty.out" 2>&1;        check "add_host пусто -> 2" 2 $?
check_true "add_host пусто msg" grep -q "корректный домен" "$WORK/v-empty.out"
add_host "no-dot" > /dev/null 2>&1;           check "add_host без точки -> 2" 2 $?
add_host "@@@" > /dev/null 2>&1;              check "add_host мусор -> 2" 2 $?
add_host "http://x.com" > /dev/null 2>&1;     check "add_host URL -> 2" 2 $?
add_host "bad_host.com" > /dev/null 2>&1;     check "add_host underscore -> 2" 2 $?
add_host ".com" > /dev/null 2>&1;             check "add_host .com -> 2" 2 $?
add_host "example." > /dev/null 2>&1;         check "add_host example. -> 2" 2 $?
# регресс: невалидные домены (двойная точка, метка на дефис) отвергаются
add_host "a..b" > /dev/null 2>&1;             check "add_host a..b -> 2" 2 $?
add_host "a-.b.com" > /dev/null 2>&1;         check "add_host a-.b.com -> 2" 2 $?
add_host "-a.com" > /dev/null 2>&1;           check "add_host -a.com -> 2" 2 $?

# валидное добавление
add_host "example.com" > "$WORK/a1.out" 2>&1
check "add_host example.com rc" 0 $?
check_true "add_host записал в файл" grep -qxF "example.com" "$UHF"
check_true "add_host вызвал apply_hosts_live" test -s "$WORK/apply.log"

# идемпотентность/дедуп в файле
add_host "example.com" > "$WORK/a2.out" 2>&1
check "add_host повторно rc" 0 $?
check_true "add_host 'уже в списке'" grep -q "уже в списке" "$WORK/a2.out"
check "add_host файл без дублей" 1 "$(grep -cxF 'example.com' "$UHF")"
check "hosts_list без дублей" 1 "$(hosts_list | grep -cx 'example.com')"
# регресс: повторный add не дублирует OPENCODE_DOMAINS
check "add_host не дублирует OPENCODE_DOMAINS" 1 \
    "$(printf '%s\n' "${OPENCODE_DOMAINS[@]}" | grep -cx 'example.com')"

# пробелы обрезаются
add_host "  spaced.com  " > /dev/null 2>&1
check "add_host обрезает пробелы" 0 $?
rm_host "spaced.com" > /dev/null 2>&1

add_host "sub.example.org" > /dev/null 2>&1
check "hosts_list два пользовательских хоста" 2 \
    "$(hosts_list | grep -cxE 'example\.com|sub\.example\.org')"

# hosts_list: встроенные домены и дедуп
check "hosts_list openrouter.ai" 1 "$(hosts_list | grep -cx 'openrouter.ai')"
check "hosts_list chatgpt.com" 1 "$(hosts_list | grep -cx 'chatgpt.com')"
check "hosts_list дедуп массива" "$(printf 'a.com\nb.com')" \
    "$(OPENCODE_DOMAINS=(a.com a.com b.com); hosts_list)"

# rm_host
rm -f "$UHF"
rm_host "x.com" > "$WORK/r-nofile.out" 2>&1
check "rm_host нет файла -> 1" 1 $?
check_true "rm_host нет файла msg" grep -q "нет в списке" "$WORK/r-nofile.out"
rm_host "" > /dev/null 2>&1
check "rm_host пусто -> 2" 2 $?

printf 'example.com\nsub.example.org\n' > "$UHF"
rm_host "example.com" > "$WORK/r1.out" 2>&1
check "rm_host rc" 0 $?
check "rm_host убрал из файла" 0 "$(grep -cxF 'example.com' "$UHF")"
check_true "rm_host msg" grep -q "Удалён хост" "$WORK/r1.out"
check "rm_host убрал из OPENCODE_DOMAINS" 0 \
    "$(printf '%s\n' "${OPENCODE_DOMAINS[@]}" | grep -cx 'example.com')"
rm_host "ghost.com" > /dev/null 2>&1
check "rm_host чужой не портит файл" 1 "$(grep -c . "$UHF")"
check "hosts_list после rm: example.com нет" 0 "$(hosts_list | grep -cx 'example.com')"
check "hosts_list после rm: sub остался" 1 "$(hosts_list | grep -cx 'sub.example.org')"

# ---------------------------------------------------------------------------
echo "=== [CLI-C] print_help ==="
print_help > "$WORK/help.out" 2>&1
for k in --add-host --rm-host --hosts --cleanup --status --help --version; do
    check_true "print_help содержит $k" grep -q -- "$k" "$WORK/help.out"
done
check_true "print_help содержит версию" grep -q "$OCVPN_VERSION" "$WORK/help.out"

# ---------------------------------------------------------------------------
echo "=== [CLI-D] do_status ==="
# (1) xray "запущен" (pgrep-мок), active.env, маркер в hosts, карантин, вотчдог
printf '# opencode-vpn\n' >> "$HOSTS_FILE"
printf 'ACTIVE_LABEL=Node-1\nACTIVE_HOST=h.example\nACTIVE_PORT=443\nXRAY_PID=%s\n' "$$" > "$ACTIVE_FILE"
printf '%s\n' "$$" > "$WATCH_PIDFILE"
printf 'h\t443\t1.2.3.4\t9999999999\treason\n' > "$QUARANTINE_FILE"
( pgrep() {
    case "$*" in
        *"-c"*"xray run"*) echo 1; return 0 ;;
        *"xray run"*)      echo 4242; return 0 ;;
    esac
    return 1
  }; do_status ) > "$WORK/st1.out" 2>&1
check_true "do_status версия" grep -q "ocvpn $OCVPN_VERSION" "$WORK/st1.out"
check_true "do_status xray запущен" grep -q "xray: запущен (1 проц.)" "$WORK/st1.out"
check_true "do_status ключ" grep -q "ключ: Node-1 (h.example:443)" "$WORK/st1.out"
check_true "do_status hosts есть" grep -q "IPv4-записи есть" "$WORK/st1.out"
check_true "do_status карантин" grep -q "карантин: 1 записей" "$WORK/st1.out"
check_true "do_status вотчдог запущен" grep -q "вотчдог: запущен" "$WORK/st1.out"

# (2) всё выключено / пусто
rm -f "$ACTIVE_FILE" "$WATCH_PIDFILE" "$QUARANTINE_FILE"
grep -v 'opencode-vpn' "$HOSTS_FILE" > "$WORK/h.nomark" 2>/dev/null && mv "$WORK/h.nomark" "$HOSTS_FILE"
( pgrep() { return 1; }; do_status ) > "$WORK/st2.out" 2>&1
check_true "do_status xray НЕ запущен" grep -q "xray: НЕ запущен" "$WORK/st2.out"
check_true "do_status нет ключа" grep -q "ключ: нет активного" "$WORK/st2.out"
check_true "do_status hosts нет" grep -q "$HOSTS_FILE: IPv4-записей нет" "$WORK/st2.out"
check_true "do_status вотчдог выключен" grep -q "вотчдог: выключен" "$WORK/st2.out"
check_true "do_status маршруты нет" grep -q "маршруты (iptables $IPTABLES_CHAIN): нет" "$WORK/st2.out"
check_true "do_status порт" grep -qE "порт $SOCKS_PORT: (слушается|закрыт)" "$WORK/st2.out"

# ---------------------------------------------------------------------------
echo "=== [CLI-E] find_xray ==="
# найден в PATH
mkdir -p "$WORK/binpath"
printf '#!/bin/bash\necho xray\n' > "$WORK/binpath/xray"; chmod +x "$WORK/binpath/xray"
XRAY_BIN=""
PATH="$WORK/binpath:$PATH" find_xray > /dev/null 2>&1
check "find_xray найден в PATH" "xray" "$XRAY_BIN"

# неподдерживаемая архитектура -> exit 1
mkdir -p "$WORK/emptybin" "$WORK/fh-err"
( HOME="$WORK/fh-err" PATH="$WORK/emptybin"; uname() { echo sparc; }; find_xray ) \
    > "$WORK/fx-err.out" 2>&1
check "find_xray arch error rc" 1 $?
check_true "find_xray arch error msg" grep -q "Неподдерживаемая архитектура" "$WORK/fx-err.out"

# установка (curl/unzip моки внутри subshell)
mkdir -p "$WORK/fh-inst/bin"
(
    HOME="$WORK/fh-inst"; PATH="/usr/bin:/bin"
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
    find_xray > /dev/null 2>&1
    echo "$XRAY_BIN"
) > "$WORK/fx-inst.out" 2>&1
check "find_xray установил" "$WORK/fh-inst/bin/xray" "$(cat "$WORK/fx-inst.out")"

# ---------------------------------------------------------------------------
echo "=== [CLI-F] ping_host / _spawn ==="
python3 -c "import socket,threading; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',34567)); s.listen(1); threading.Event().wait(3)" &
LP=$!
sleep 0.4
PING_TIMEOUT=2
check "ping_host живой" "1" "$(ping_host 127.0.0.1 34567 | awk '{print ($1<99999)}')"
check "ping_host мёртвый" "99999 10.255.255.1 443" "$(ping_host 10.255.255.1 443)"
kill "$LP" 2>/dev/null || true

_spawn "$WORK/spawn.log" /bin/true
_spawn "$WORK/spawn2.log" /bin/echo hello
sleep 0.4
check_true "_spawn создал лог" test -f "$WORK/spawn.log"
check_true "_spawn пишет в лог" grep -q "hello" "$WORK/spawn2.log"

# ---------------------------------------------------------------------------
echo "=== [CLI-K] _kill_matching / _kill_matching9 / stop_all / cleanup ==="

# _kill_matching убивает свой fake-xray, но НЕ хостовый xray
exec -a 'fake-xray run -c /tmp/opencode-vpn/K1/config.json' /bin/sleep 30 & KM1=$!
exec -a 'xray run -c /tmp/opencode-vpn/REAL/config.json' /bin/sleep 37 & HOSTLIKE=$!
sleep 0.3
_kill_matching 'xray run -c /tmp/opencode-vpn'
sleep 0.3
check_true "_kill_matching убил fake-xray" bash -c "! kill -0 $KM1 2>/dev/null"
check_true "_kill_matching НЕ убил хостовый xray" bash -c "kill -0 $HOSTLIKE 2>/dev/null"
kill -9 "$HOSTLIKE" 2>/dev/null || true
wait "$KM1" "$HOSTLIKE" 2>/dev/null || true

# _kill_matching9
exec -a 'fake-xray run -c /tmp/opencode-vpn/K9/config.json' /bin/sleep 30 & KM9=$!
sleep 0.3
_kill_matching9 'xray run -c /tmp/opencode-vpn'
sleep 0.3
check_true "_kill_matching9 убил fake-xray" bash -c "! kill -0 $KM9 2>/dev/null"
wait "$KM9" 2>/dev/null || true

# _kill_matching по маске ocvpn(\.sh)?$
printf '#!/bin/bash\nsleep 30\n' > "$WORK/fake-ocvpn.sh"; chmod +x "$WORK/fake-ocvpn.sh"
bash "$WORK/fake-ocvpn.sh" & KO=$!
sleep 0.3
_kill_matching 'ocvpn(\.sh)?$'
sleep 0.3
check_true "_kill_matching убил fake-ocvpn" bash -c "! kill -0 $KO 2>/dev/null"
wait "$KO" 2>/dev/null || true

# stop_all: прямые kill из active.env/watch.pid + _kill_matching, хостовый цел
printf '#!/bin/bash\nsleep 30\n' > "$WORK/fake-ocvpn2.sh"; chmod +x "$WORK/fake-ocvpn2.sh"
bash "$WORK/fake-ocvpn2.sh" & SH=$!
exec -a 'fake-xray run -c /tmp/opencode-vpn/S/config.json' /bin/sleep 30 & SX=$!
exec -a 'fake-xray run -c /tmp/opencode-vpn/S2/config.json' /bin/sleep 30 & SM=$!
exec -a 'fake-ocvpn-watchdog' /bin/sleep 30 & SW=$!
exec -a 'xray run -c /tmp/opencode-vpn/REAL2/config.json' /bin/sleep 37 & SHOST=$!
sleep 0.3
printf 'HOLDER_PID=%s\nXRAY_PID=%s\n' "$SH" "$SX" > "$ACTIVE_FILE"
printf '%s\n' "$SW" > "$WATCH_PIDFILE"
stop_all
sleep 0.5
check_true "stop_all убил holder" bash -c "! kill -0 $SH 2>/dev/null"
check_true "stop_all убил xray" bash -c "! kill -0 $SX 2>/dev/null"
check_true "stop_all убил fake через _kill_matching" bash -c "! kill -0 $SM 2>/dev/null"
check_true "stop_all убил watch" bash -c "! kill -0 $SW 2>/dev/null"
check_true "stop_all НЕ убил хостовый xray" bash -c "kill -0 $SHOST 2>/dev/null"
check_true "stop_all удалил active.env" test ! -f "$ACTIVE_FILE"
check_true "stop_all удалил watch.pid" test ! -f "$WATCH_PIDFILE"
kill -9 "$SHOST" 2>/dev/null || true
wait "$SH" "$SX" "$SM" "$SW" "$SHOST" 2>/dev/null || true

# cleanup: no-op без владения
out="$( ( unset TMPDIR XRAY_PID OCVPN_OWNER; cleanup ); echo "rc=$?" )"
check "cleanup no-op rc" "rc=0" "$out"

# cleanup: убивает XRAY_PID и сносит TMPDIR
TMPDIR="$WORK/cleanme"; mkdir -p "$TMPDIR"
exec -a 'fake-xray cleanup' /bin/sleep 30 & CP=$!
sleep 0.3
XRAY_PID=$CP
cleanup
sleep 0.3
check_true "cleanup убил XRAY_PID" bash -c "! kill -0 $CP 2>/dev/null"
check_true "cleanup удалил TMPDIR" test ! -d "$TMPDIR"
unset XRAY_PID TMPDIR

# ---------------------------------------------------------------------------
echo "=== [CLI-X] main-ветки (subshell) ==="
( main --help ) > "$WORK/mh.out" 2>&1
check "main --help rc" 0 $?
check_true "main --help текст" grep -q -- "--add-host" "$WORK/mh.out"
( main --version ) > "$WORK/mv.out" 2>&1
check "main --version rc" 0 $?
check "main --version текст" "ocvpn $OCVPN_VERSION" "$(cat "$WORK/mv.out")"
( pgrep() { return 1; }; main --status ) > "$WORK/ms.out" 2>&1
rc=$?
check_true "main --status rc 0/1" bash -c "[[ $rc -eq 0 || $rc -eq 1 ]]"
check_true "main --status текст" grep -q "ocvpn $OCVPN_VERSION" "$WORK/ms.out"

rm -f "$USER_HOSTS_FILE"
( main --add-host cli.example.net ) > "$WORK/ma.out" 2>&1
check "main --add-host rc" 0 $?
check_true "main --add-host записал" grep -qxF 'cli.example.net' "$USER_HOSTS_FILE"
( main --add-host badhost ) > /dev/null 2>&1
check "main --add-host невалидный rc" 2 $?
( main --rm-host cli.example.net ) > "$WORK/mr.out" 2>&1
check "main --rm-host rc" 0 $?
check "main --rm-host убрал" 0 "$(grep -cxF 'cli.example.net' "$USER_HOSTS_FILE")"
( main --hosts ) > "$WORK/mhos.out" 2>&1
check "main --hosts rc" 0 $?
check_true "main --hosts builtin" grep -qx 'openrouter.ai' "$WORK/mhos.out"
check_true "main --hosts user" grep -qx 'sub.example.org' "$WORK/mhos.out"

finish
