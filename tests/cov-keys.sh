#!/usr/bin/env bash
# Покрытийные тесты ocvpn: подбор/ротация ключей и выходного IP.
#   shuffle, candidate_pool, select_candidates, pick_working_key, try_key,
#   check_model_available, fetch_subscription, current_exit_ip, exit_ip_fast,
#   activate_current, rotate_now, do_rotate, do_watch, supervise,
#   is_rotatable_limit, parse_reset_hours.
#
# Безопасность: ничего не запускаем как программу, не трогаем systemd,
# все мутирующие ветки живут в subshell с моками. Бесконечные циклы
# (do_watch/supervise) ограничены моками tail/sleep и не виснут.
. "$(dirname "$0")/lib.sh"

# --- фейковый xray для try_key (имя fake-xray — его убьёт _cleanup из lib.sh) ---
FAKE_XRAY="$WORK/fake-xray"
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$FAKE_XRAY"
chmod +x "$FAKE_XRAY"

: > "$WORK/watch_bash.log"

# ===========================================================================
echo "=== [A] shuffle ==="
got="$(printf 'b\na\nc\n' | shuffle | sort | tr '\n' ',')"
check "shuffle сохраняет набор строк" "a,b,c," "$got"
check "shuffle сохраняет число строк" "3" "$(printf 'b\na\nc\n' | shuffle | wc -l | tr -d ' ')"

# fallback: sort -R недоступен -> awk/sort -n
got="$( ( sort() { [[ "${1:-}" == "-R" ]] && return 1; command sort "$@"; }
           printf 'b\na\nc\n' | shuffle | sort | tr '\n' ',' ) )"
check "shuffle fallback (нет sort -R) сохраняет набор" "a,b,c," "$got"

# ===========================================================================
echo "=== [B] candidate_pool ==="
SUB="$WORK/pool_subs.txt"
printf '%s\n' \
    'vless://u1@h1:443?type=tcp#A' \
    'hysteria2://u@h:443#X' \
    'vmess://AAA#V' \
    'trojan://u3@h3:443?type=ws#B' \
    'vless://u4@h4:443?type=kcp#C' \
    'http://p:8080#P' \
    'garbage' > "$SUB"

want="$WORK/pool_want1"
printf '%s\n' 'vless://u1@h1:443?type=tcp#A' 'vmess://AAA#V' \
    'trojan://u3@h3:443?type=ws#B' 'http://p:8080#P' > "$want"
check "candidate_pool фильтрует схему/type" "$(cat "$want")" "$(candidate_pool "$SUB")"
check "candidate_pool без tried = 4" "4" "$(candidate_pool "$SUB" | grep -c .)"

printf 'vmess://AAA#V\n' > "$WORK/pool_tried.txt"
want2="$WORK/pool_want2"
printf '%s\n' 'vless://u1@h1:443?type=tcp#A' \
    'trojan://u3@h3:443?type=ws#B' 'http://p:8080#P' > "$want2"
check "candidate_pool исключает tried_file" "$(cat "$want2")" \
    "$(candidate_pool "$SUB" "$WORK/pool_tried.txt")"
check "candidate_pool несуществующий tried не мешает" "4" \
    "$(candidate_pool "$SUB" "$WORK/no_such_tried" | grep -c .)"

# ===========================================================================
echo "=== [C] select_candidates ==="
SEL="$WORK/sel_subs.txt"
printf '%s\n' \
    'vless://a@h1:443?type=tcp#H1' \
    'vless://b@h2:443?type=tcp#H2' \
    'vless://c@h3:443?type=tcp#H3' > "$SEL"
mkdir -p "$TMPDIR"

res="$( ( ping_host() { case "$1" in
            h1) echo "30 $1 $2" ;;
            h2) echo "10 $1 $2" ;;
            h3) echo "99999 $1 $2" ;;
        esac; }
        select_candidates "$SEL" "" ) 2>/dev/null )"
check "select_candidates отбрасывает недоступные" "2" "$(printf '%s\n' "$res" | grep -c .)"
check "select_candidates сортирует: быстрый h2 первым" "1" \
    "$(printf '%s\n' "$res" | head -n1 | grep -c 'h2')"
check "select_candidates h3 (99999) отсутствует" "0" \
    "$(printf '%s\n' "$res" | grep -c 'h3')"
check_true "select_candidates пишет pool.txt" test -s "$TMPDIR/pool.txt"

printf 'vless://a@h1:443?type=tcp#H1\n' > "$WORK/sel_tried.txt"
res="$( ( ping_host() { echo "5 $1 $2"; }; select_candidates "$SEL" "$WORK/sel_tried.txt" ) 2>/dev/null )"
check "select_candidates исключает tried" "0" "$(printf '%s\n' "$res" | grep -c 'h1')"

res="$( ( ping_host() { echo "99999 $1 $2"; }; select_candidates "$SEL" "" ) 2>/dev/null )"
check "select_candidates все недоступны -> пусто" "0" "$(printf '%s\n' "$res" | grep -c .)"

# ===========================================================================
echo "=== [D] pick_working_key ==="
SUBS_FILE="$WORK/pw_subs.txt"; : > "$SUBS_FILE"
PWU='vless://x@hx:443?type=tcp#X'
U_ONE='vless://x@one:443?type=tcp#one'
U_TWO='vless://x@two:443?type=tcp#two'
rm -f "$QUARANTINE_FILE" "$WORK/pw_try.log" "$WORK/pw_try2.log"

# D1 success
res="$( ( SUBS_FILE="$WORK/pw_subs.txt"
    select_candidates() { printf '5\t%s\n' "$PWU"; }
    url_host_port()    { printf 'hx 443'; }
    try_key()          { printf 'call:%s\n' "$1" >> "$WORK/pw_try.log"; return 0; }
    pick_working_key "" >/dev/null 2>&1; echo "rc=$?" ) )"
check "pick_working_key успех rc" "rc=0" "$res"
check "pick_working_key вызвал try_key с URL" "1" "$(grep -c 'call:vless://x@hx' "$WORK/pw_try.log")"
check_true "pick_working_key записал tried.txt" grep -qxF "$PWU" "$TMPDIR/tried.txt"

# D2 карантин: h1 пропускается, h2 пробуется
res="$( ( SUBS_FILE="$WORK/pw_subs.txt"
    select_candidates()  { printf '5\t%s\n5\t%s\n' "$U_ONE" "$U_TWO"; }
    url_host_port()      { case "$1" in *one*) printf 'qh1 443' ;; *) printf 'qh2 443' ;; esac; }
    quarantine_blocked() { [[ "$1" == "qh1" ]]; }
    try_key()            { printf '%s\n' "$1" >> "$WORK/pw_try2.log"; return 0; }
    pick_working_key "" >/dev/null 2>&1; echo "rc=$?" ) )"
check "pick_working_key карантин rc" "rc=0" "$res"
check "pick_working_key карантинный h1 не пробуется" "0" "$(grep -c 'one' "$WORK/pw_try2.log")"
check "pick_working_key рабочий h2 пробуется" "1" "$(grep -c 'two' "$WORK/pw_try2.log")"

# D3 батч провалился, пул исчерпан, подписка не скачалась -> 1
rm -f "$WORK/d3.flag" "$WORK/d3.fetch"
res="$( ( SUBS_FILE="$WORK/pw_subs.txt"
    select_candidates() { if [[ ! -f "$WORK/d3.flag" ]]; then
                             : > "$WORK/d3.flag"; printf '5\t%s\n' "$U_ONE"
                         fi; }
    candidate_pool()    { :; }
    url_host_port()     { printf 'hh 443'; }
    try_key()           { return 1; }
    fetch_subscription(){ printf 'fetch\n' >> "$WORK/d3.fetch"; return 1; }
    pick_working_key "" >/dev/null 2>&1; echo "rc=$?" ) )"
check "pick_working_key пул исчерпан rc" "rc=1" "$res"
check "pick_working_key подписка запрошена один раз" "1" "$(grep -c . "$WORK/d3.fetch")"

# D4 max_cycles: подписка скачивается, но кандидатов нет -> 1 после 5 циклов
rm -f "$WORK/d4.fetch"
res="$( ( SUBS_FILE="$WORK/pw_subs.txt"
    select_candidates() { :; }
    candidate_pool()    { :; }
    fetch_subscription(){ printf 'f\n' >> "$WORK/d4.fetch"; return 0; }
    pick_working_key "" >/dev/null 2>&1; echo "rc=$?" ) )"
check "pick_working_key max_cycles rc" "rc=1" "$res"
check "pick_working_key max_cycles: 5 обновлений" "5" "$(grep -c . "$WORK/d4.fetch")"

# ===========================================================================
echo "=== [E] try_key ==="
TKURL='vless://u@h:443?type=tcp#LBL'

# E1 success
res="$( ( XRAY_BIN="$FAKE_XRAY"
    uri_to_xray()          { mkdir -p "$2"; : > "$2/config.json"; return 0; }
    sleep()                { :; }
    curl()                 { printf '204'; }
    current_exit_ip()      { printf '5.5.5.5'; }
    quarantine_blocked()   { return 1; }
    check_model_available(){ return 0; }
    try_key "$TKURL" h 443 "" LBL 1 1 >/dev/null 2>&1
    rc=$?
    kill "$XRAY_PID" 2>/dev/null || true; wait "$XRAY_PID" 2>/dev/null || true
    printf 'rc=%s host=%s port=%s ip=%s\n' "$rc" "$ACTIVE_HOST" "$ACTIVE_PORT" "$ACTIVE_EXIT_IP" ) )"
check "try_key успех" "rc=0 host=h port=443 ip=5.5.5.5" "$res"

# E2 не 204
res="$( ( XRAY_BIN="$FAKE_XRAY"
    uri_to_xray() { mkdir -p "$2"; return 0; }
    sleep() { :; }
    curl()  { printf '500'; }
    try_key "$TKURL" h 443 "" LBL 1 1 >/dev/null 2>&1; rc=$?
    kill "$XRAY_PID" 2>/dev/null || true; wait "$XRAY_PID" 2>/dev/null || true
    printf 'rc=%s' "$rc" ) )"
check "try_key HTTP!=204 -> 1" "rc=1" "$res"

# E3 тот же exit IP
res="$( ( XRAY_BIN="$FAKE_XRAY"
    uri_to_xray()     { mkdir -p "$2"; return 0; }
    sleep()           { :; }
    curl()            { printf '204'; }
    current_exit_ip() { printf '5.5.5.5'; }
    try_key "$TKURL" h 443 5.5.5.5 LBL 1 1 >/dev/null 2>&1; rc=$?
    kill "$XRAY_PID" 2>/dev/null || true; wait "$XRAY_PID" 2>/dev/null || true
    printf 'rc=%s' "$rc" ) )"
check "try_key exclude_ip совпал -> 1" "rc=1" "$res"

# E4 exit IP в карантине
res="$( ( XRAY_BIN="$FAKE_XRAY"
    uri_to_xray()        { mkdir -p "$2"; return 0; }
    sleep()              { :; }
    curl()               { printf '204'; }
    current_exit_ip()    { printf '5.5.5.5'; }
    quarantine_blocked() { return 0; }
    try_key "$TKURL" h 443 "" LBL 1 1 >/dev/null 2>&1; rc=$?
    kill "$XRAY_PID" 2>/dev/null || true; wait "$XRAY_PID" 2>/dev/null || true
    printf 'rc=%s' "$rc" ) )"
check "try_key exit IP в карантине -> 1" "rc=1" "$res"

# E5 geo-block -> карантин 12ч
rm -f "$WORK/tk_geo.log"
res="$( ( XRAY_BIN="$FAKE_XRAY"
    uri_to_xray()          { mkdir -p "$2"; return 0; }
    sleep()                { :; }
    curl()                 { printf '204'; }
    current_exit_ip()      { printf '5.5.5.5'; }
    quarantine_blocked()   { return 1; }
    check_model_available(){ return 1; }
    quarantine_add()       { printf '%s\n' "$*" >> "$WORK/tk_geo.log"; }
    try_key "$TKURL" h 443 "" LBL 1 1 >/dev/null 2>&1; rc=$?
    kill "$XRAY_PID" 2>/dev/null || true; wait "$XRAY_PID" 2>/dev/null || true
    printf 'rc=%s' "$rc" ) )"
check "try_key geo-block -> 1" "rc=1" "$res"
check_true "try_key geo-block карантин 12ч" grep -qE ' 12$' "$WORK/tk_geo.log"

# E6 uri_to_xray падает
res="$( ( XRAY_BIN="$FAKE_XRAY"
    uri_to_xray() { return 1; }
    try_key "$TKURL" h 443 "" LBL 1 1 >/dev/null 2>&1; echo "rc=$?" ) )"
check "try_key не собрать конфиг -> 1" "rc=1" "$res"

# E7 xray не стартует (/bin/true сразу выходит)
res="$( ( XRAY_BIN=/bin/true
    uri_to_xray() { mkdir -p "$2"; return 0; }
    sleep() { :; }
    try_key "$TKURL" h 443 "" LBL 1 1 >/dev/null 2>&1; echo "rc=$?" ) )"
check "try_key xray не стартует -> 1" "rc=1" "$res"

# ===========================================================================
echo "=== [F] check_model_available ==="
AUTH_DIR="$HOME/.local/share/opencode"; mkdir -p "$AUTH_DIR"
printf '{"opencode":{"key":"k"}}' > "$AUTH_DIR/auth.json"

# имена _cmc/_cmb, т.к. check_model_available объявляет local body/http_code
# и через динамическую область видимости затеняет одноимённые переменные.
cm() { local _cmc="$1" _cmb="$2"
    ( curl() { printf '%s\n%s' "$_cmb" "$_cmc"; }
      check_model_available >/dev/null 2>&1; echo $? ); }

check "models 200 -> 0" "0" "$(cm 200 '{}')"
check "models 201 -> 0" "0" "$(cm 201 '{}')"
check "models 429 -> 0" "0" "$(cm 429 '{}')"
check "models 204 -> 0" "0" "$(cm 204 '')"
check "models 000 (timeout) -> 0" "0" "$(cm 000 '')"
check "models 500 -> 0 (не geo)" "0" "$(cm 500 'internal error')"
check "models 403 без geo-body -> 1" "1" "$(cm 403 '')"
check "models 451 -> 1" "1" "$(cm 451 '')"
check "models 403 geo-body -> 1" "1" "$(cm 403 'not available in your country')"
check "models 200 geo-body -> 0 (200 важнее)" "0" "$(cm 200 'not available in your country')"

# кэша нет: ровно по одному запросу на каждую FREE_MODEL
: > "$WORK/cm_calls"
( curl() { echo x >> "$WORK/cm_calls"; printf '%s\n%s' '' 200; }
  check_model_available >/dev/null 2>&1 )
check "models: запросов на каждую модель (кэша нет)" "${#FREE_MODELS[@]}" \
    "$(grep -c . "$WORK/cm_calls")"

# нет auth.json -> 0 без сети
mv "$AUTH_DIR/auth.json" "$WORK/auth.bak"
: > "$WORK/cm_calls"
res="$( ( curl() { echo x >> "$WORK/cm_calls"; printf '%s\n%s' '' 403; }
         check_model_available >/dev/null 2>&1; echo $? ) )"
check "models без auth -> 0" "0" "$res"
check "models без auth: curl не вызван" "0" "$(grep -c . "$WORK/cm_calls")"
mv "$WORK/auth.bak" "$AUTH_DIR/auth.json"

# ===========================================================================
echo "=== [G] fetch_subscription ==="
res="$( ( download_subscription() { printf 'vless://u@h:443?type=tcp#x\n' > "$1"; return 0; }
         fetch_subscription >/dev/null 2>&1; echo "rc=$? file=$SUBS_FILE" ) )"
check "fetch_subscription успех" "rc=0 file=$TMPDIR/subs.txt" "$res"
res="$( ( download_subscription() { return 1; }
         fetch_subscription >/dev/null 2>&1; echo "rc=$?" ) )"
check "fetch_subscription download fail -> 1" "rc=1" "$res"
res="$( ( download_subscription() { printf 'garbage\n' > "$1"; return 0; }
         fetch_subscription >/dev/null 2>&1; echo "rc=$?" ) )"
check "fetch_subscription нет поддерживаемых -> 1" "rc=1" "$res"

# ===========================================================================
echo "=== [H] current_exit_ip / exit_ip_fast ==="
check "current_exit_ip ok" "1.2.3.4" \
    "$( ( curl() { printf '1.2.3.4'; }; current_exit_ip ) )"
check "current_exit_ip fallback на ipinfo" "9.8.7.6" \
    "$( ( curl() { case "$*" in *ipify*) return 1 ;; *) printf '  9.8.7.6 \n' ;; esac; }
         current_exit_ip ) )"
check "current_exit_ip оба URL fail -> пусто" "" \
    "$( ( curl() { return 1; }; current_exit_ip ) )"
check "current_exit_ip не-IP отбрасывается" "" \
    "$( ( curl() { printf 'not-an-ip'; }; current_exit_ip ) )"
check "current_exit_ip пробелы обрезаются" "5.6.7.8" \
    "$( ( curl() { printf '\t 5.6.7.8 \r\n'; }; current_exit_ip ) )"

check "exit_ip_fast ok" "4.4.4.4" "$( ( curl() { printf '4.4.4.4\n'; }; exit_ip_fast ) )"
check "exit_ip_fast fail -> пусто" "" "$( ( curl() { return 1; }; exit_ip_fast ) )"
check "exit_ip_fast мусор -> пусто" "" "$( ( curl() { printf 'x'; }; exit_ip_fast ) )"

# ===========================================================================
echo "=== [I] activate_current ==="
: > "$WORK/setup.log"; rm -f "$ACTIVE_FILE"
res="$( ( setup_routes() { echo called >> "$WORK/setup.log"; return 0; }
         XRAY_PID=4242; ACTIVE_HOST=hh; ACTIVE_PORT=443
         ACTIVE_LABEL=Lbl; ACTIVE_EXIT_IP=5.5.5.5
         activate_current >/dev/null 2>&1; echo "rc=$?" ) )"
check "activate_current rc" "rc=0" "$res"
check_true "activate_current вызвал setup_routes" test -s "$WORK/setup.log"
check_true "active.env HOLDER_PID" grep -q '^HOLDER_PID=' "$ACTIVE_FILE"
check_true "active.env XRAY_PID" grep -q '^XRAY_PID=4242$' "$ACTIVE_FILE"
check_true "active.env ACTIVE_HOST" grep -q '^ACTIVE_HOST=hh$' "$ACTIVE_FILE"
check_true "active.env ACTIVE_PORT" grep -q '^ACTIVE_PORT=443$' "$ACTIVE_FILE"
check_true "active.env ACTIVE_EXIT_IP" grep -q '^ACTIVE_EXIT_IP=5.5.5.5$' "$ACTIVE_FILE"
check_true "active.env STARTED" grep -q '^STARTED=' "$ACTIVE_FILE"

# ===========================================================================
echo "=== [J] rotate_now ==="
# не подключены
rm -f "$WORK/j_none"
res="$( ( ACTIVE_HOST=""; XRAY_PID=""
         quarantine_add() { echo q >> "$WORK/j_none"; }
         rotate_now >/dev/null 2>&1; echo "rc=$?" ) )"
check "rotate_now не подключён -> 0" "rc=0" "$res"
check "rotate_now не подключён: без карантина" "0" \
    "$( [[ -f "$WORK/j_none" ]] && echo 1 || echo 0 )"

# повторный вход
res="$( ( ROTATING=1; ACTIVE_HOST=h
         rotate_now >/dev/null 2>&1; echo "rc=$?" ) )"
check "rotate_now ROTATING=1 -> 0 (guard)" "rc=0" "$res"

# успех
rm -f "$ROTATIONS_LOG" "$LAST_ROTATE_FILE" "$WORK/j_q" "$WORK/j_act"
printf 'rate limit reset in 2 hours' > "$REASON_FILE"
res="$( ( ROTATING=0; ACTIVE_HOST=oldh; ACTIVE_PORT=443
         ACTIVE_EXIT_IP=1.2.3.4; XRAY_PID=""
         quarantine_add()   { printf '%s\n' "$*" >> "$WORK/j_q"; }
         fetch_subscription(){ return 0; }
         pick_working_key() { ACTIVE_EXIT_IP=9.9.9.9; ACTIVE_LABEL=NEW
                              ACTIVE_HOST=newh; ACTIVE_PORT=8443; return 0; }
         activate_current() { printf 'act\n' >> "$WORK/j_act"; }
         rotate_now >/dev/null 2>&1
         echo "rc=$? rotating=$ROTATING ip=$ACTIVE_EXIT_IP" ) )"
check "rotate_now успех rc/состояние" "rc=0 rotating=0 ip=9.9.9.9" "$res"
check "rotate_now карантинит старый host:port:ip" "1" "$(grep -c '^oldh 443 1.2.3.4' "$WORK/j_q")"
check "rotate_now карантин с часами из хинта (2ч)" "1" "$(grep -c ' 2$' "$WORK/j_q")"
check "rotate_now пишет 2 строки в rotations.tsv" "2" "$(grep -c . "$ROTATIONS_LOG")"
check_true "rotate_now обновил LAST_ROTATE_FILE" test -s "$LAST_ROTATE_FILE"
check_true "rotate_now вызвал activate_current" test -s "$WORK/j_act"

# подписка не скачалась -> 1, pick не вызван
rm -f "$WORK/j_pick"
res="$( ( ROTATING=0; ACTIVE_HOST=h; ACTIVE_PORT=443; ACTIVE_EXIT_IP=1.2.3.4; XRAY_PID=""
         quarantine_add()    { :; }
         fetch_subscription(){ return 1; }
         pick_working_key()  { echo pick >> "$WORK/j_pick"; }
         activate_current()  { :; }
         rotate_now >/dev/null 2>&1; echo "rc=$? rotating=$ROTATING" ) )"
check "rotate_now fetch fail -> 1, ROTATING сброшен" "rc=1 rotating=0" "$res"
check "rotate_now fetch fail: pick не вызван" "0" \
    "$( [[ -f "$WORK/j_pick" ]] && echo 1 || echo 0 )"

# рабочий ключ не найден -> функция возвращает 0 (fall-through), старый остаётся
res="$( ( ROTATING=0; ACTIVE_HOST=h; ACTIVE_PORT=443; ACTIVE_EXIT_IP=1.2.3.4; XRAY_PID=""
         quarantine_add()    { :; }
         fetch_subscription(){ return 0; }
         pick_working_key()  { return 1; }
         activate_current()  { :; }
         rotate_now >/dev/null 2>&1; echo "rc=$? rotating=$ROTATING" ) )"
check "rotate_now pick fail: fall-through rc=0" "rc=0 rotating=0" "$res"

# ===========================================================================
echo "=== [K] do_rotate ==="
rm -f "$ACTIVE_FILE"
out="$( ( do_rotate 'x' ) 2>&1 )"; rc=$?
check "do_rotate нет active.env rc" "1" "$rc"
check_true "do_rotate нет active.env msg" grep -q "Нет активного подключения" <<<"$out"

printf 'HOLDER_PID=999999\nSTARTED=100\nACTIVE_EXIT_IP=1.2.3.4\n' > "$ACTIVE_FILE"
out="$( ( do_rotate 'x' ) 2>&1 )"; rc=$?
check "do_rotate мёртвый holder rc" "1" "$rc"
check_true "do_rotate мёртвый holder msg" grep -q "не запущен" <<<"$out"

# успех: kill -USR1 мок обновляет active.env
printf 'HOLDER_PID=999999\nSTARTED=100\nACTIVE_EXIT_IP=1.2.3.4\n' > "$ACTIVE_FILE"
out="$( ( sleep() { :; }
    kill() { case "$1" in
        -0)    return 0 ;;
        -USR1) printf 'HOLDER_PID=999999\nSTARTED=200\nACTIVE_EXIT_IP=9.9.9.9\nACTIVE_LABEL=NEW\n' > "$ACTIVE_FILE"
               return 0 ;;
        *) return 0 ;;
    esac; }
    do_rotate 'need better IP' ) 2>&1 )"; rc=$?
check "do_rotate успех rc" "0" "$rc"
check_true "do_rotate успех msg" grep -q "РОТАЦИЯ выполнена" <<<"$out"
check "do_rotate reason сохранён" "need better IP" "$(cat "$REASON_FILE")"

# таймаут: ротация не подтверждается -> 1 (60 итераций, sleep заглушен)
printf 'HOLDER_PID=999999\nSTARTED=100\nACTIVE_EXIT_IP=1.2.3.4\n' > "$ACTIVE_FILE"
out="$( ( sleep() { :; }
    kill() { case "$1" in -0) return 0 ;; -USR1) return 0 ;; *) return 0 ;; esac; }
    do_rotate 'timeout' ) 2>&1 )"; rc=$?
check "do_rotate таймаут rc" "1" "$rc"
check_true "do_rotate таймаут msg" grep -q "не подтвердилась" <<<"$out"

# ===========================================================================
echo "=== [L] do_watch ==="
run_watch() { # $1 — файл, содержимое которого отдаст мок tail
    local src="$1"
    ( tail()  { cat "$src"; }
      bash()  { printf '%s\n' "$*" >> "$WORK/watch_bash.log"; return 0; }
      sleep() { :; }
      do_watch ) >"$WORK/watch.out" 2>&1
    echo $?
}

# уже запущен (live pid)
printf '%s\n' "$$" > "$WATCH_PIDFILE"
rc="$(run_watch "$WORK/w_none")"
check "do_watch уже запущен rc" "1" "$rc"
check_true "do_watch уже запущен msg" grep -q "уже запущен" "$WORK/watch.out"
rm -f "$WATCH_PIDFILE"

# нет лога opencode
mv "$OPENCODE_LOG" "$WORK/oc.bak" 2>/dev/null || true
rc="$(run_watch "$WORK/w_none")"
check "do_watch нет лога rc" "1" "$rc"
check_true "do_watch нет лога msg" grep -q "не найден" "$WORK/watch.out"
mv "$WORK/oc.bak" "$OPENCODE_LOG" 2>/dev/null || : > "$OPENCODE_LOG"

# не-лимитная строка: цикл проходит и завершается, ротации нет
printf 'all good here\n' > "$WORK/w_nomatch"
: > "$WORK/watch_bash.log"; rm -f "$WATCH_PIDFILE"
rc="$(run_watch "$WORK/w_nomatch")"
check "do_watch не-лимит rc" "0" "$rc"
check "do_watch не-лимит: rotate не вызван" "0" "$(awk 'END{print NR}' "$WORK/watch_bash.log")"
check_true "do_watch снял watch.pid" test ! -f "$WATCH_PIDFILE"

# успешная ротация
rm -f "$WATCH_PIDFILE" "$LAST_ROTATE_FILE" "$ROTATE_HOUR_FILE"
printf 'Rate limit exceeded\n' > "$WORK/w_limit"
: > "$WORK/watch_bash.log"
rc="$(run_watch "$WORK/w_limit")"
check "do_watch rotate rc" "0" "$rc"
check_true "do_watch вызвал --rotate" grep -q -- '--rotate' "$WORK/watch_bash.log"
check_true "do_watch LAST_ROTATE записан" test -s "$LAST_ROTATE_FILE"
check "do_watch счётчик часа = 1" "1" "$(awk '{print $2}' "$ROTATE_HOUR_FILE")"

# cooldown
rm -f "$WATCH_PIDFILE" "$ROTATE_HOUR_FILE"
printf '%s' "$(date +%s)" > "$LAST_ROTATE_FILE"
: > "$WORK/watch_bash.log"
rc="$(run_watch "$WORK/w_limit")"
check "do_watch cooldown rc" "0" "$rc"
check_true "do_watch cooldown msg" grep -q "cooldown" "$WORK/watch.out"
check "do_watch cooldown: rotate не вызван" "0" "$(awk 'END{print NR}' "$WORK/watch_bash.log")"

# лимит ротаций в час достигнут
rm -f "$WATCH_PIDFILE"; : > "$WORK/watch_bash.log"
printf '%s 6\n' "$(date +%Y%m%d%H)" > "$ROTATE_HOUR_FILE"
printf '0' > "$LAST_ROTATE_FILE"
rc="$(run_watch "$WORK/w_limit")"
check "do_watch лимит/час rc" "0" "$rc"
check_true "do_watch лимит/час msg" grep -q "превышен лимит" "$WORK/watch.out"
check "do_watch лимит/час: rotate не вызван" "0" "$(awk 'END{print NR}' "$WORK/watch_bash.log")"

# счётчик часа инкрементируется (cc < max)
rm -f "$WATCH_PIDFILE" "$LAST_ROTATE_FILE"; : > "$WORK/watch_bash.log"
printf '%s 2\n' "$(date +%Y%m%d%H)" > "$ROTATE_HOUR_FILE"
rc="$(run_watch "$WORK/w_limit")"
check "do_watch инкремент rc" "0" "$rc"
check "do_watch счётчик часа 2 -> 3" "3" "$(awk '{print $2}' "$ROTATE_HOUR_FILE")"

# ===========================================================================
echo "=== [M] supervise ==="
out="$( ( XRAY_PID=999999; supervise ) 2>&1 )"; rc=$?
check "supervise мёртвый xray rc" "1" "$rc"
check_true "supervise мёртвый xray msg" grep -q "завершился" <<<"$out"

out="$( ( sleep 0.3 & XRAY_PID=$!; supervise ) 2>&1 )"; rc=$?
check "supervise дождался смерти xray rc" "1" "$rc"

# ===========================================================================
echo "=== [N] is_rotatable_limit / parse_reset_hours ==="
check "limit 429 -> 0" "0" "$(is_rotatable_limit 'HTTP 429 Too Many'; echo $?)"
check "limit rate -> 0" "0" "$(is_rotatable_limit 'Rate limit exceeded'; echo $?)"
check "limit reset-in -> 0" "0" "$(is_rotatable_limit 'usage limit will reset in 5 minutes'; echo $?)"
check "limit exclude ollama -> 1" "1" "$(is_rotatable_limit 'ollama reset in 2 hours'; echo $?)"
check "limit exclude Forbidden -> 1" "1" "$(is_rotatable_limit '429 Forbidden'; echo $?)"
check "limit random -> 1" "1" "$(is_rotatable_limit 'all good'; echo $?)"

check "reset 25m -> 1" "1" "$(parse_reset_hours 'It will reset in 25 minutes.')"
check "reset 90m -> 2" "2" "$(parse_reset_hours 'reset in 90 minute')"
check "reset 3h -> 3" "3" "$(parse_reset_hours 'It will reset in 3 hours.')"
check "reset 2d -> 48" "48" "$(parse_reset_hours 'It will reset in 2 days.')"
check "reset cap -> 168" "168" "$(parse_reset_hours 'It will reset in 200 days.')"
check "reset default" "$QUARANTINE_HOURS" "$(parse_reset_hours 'nope')"

finish
