#!/usr/bin/env bash
# Тесты для opencode-vpn.sh (безопасно: iptables/hosts/xray замоканы)
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ocvpn.sh"
PASS=0
FAIL=0
TESTS_DIR=$(mktemp -d /tmp/ovpn-tests-XXXXXX)
export TESTS_DIR
export TMPDIR="${TESTS_DIR}/tmp"
mkdir -p "$TMPDIR"

# Загрузить функции скрипта (до main) в текущую оболочку — понадобятся в [2], [3]
FUNC_LOAD="$TESTS_DIR/load.sh"
sed '/# === Main ===/,$d' "$SCRIPT" > "$FUNC_LOAD"
cat >> "$FUNC_LOAD" <<'AUTOLOAD'
# убираем trap cleanup, чтобы не трогать реальные /etc/hosts при exit теста
trap - EXIT
iptables() { return 0; }
AUTOLOAD
# shellcheck disable=SC1090
source "$FUNC_LOAD"

FUNC_H="$TESTS_DIR/func.sh"

# ==== 1. Загрузка функций без запуска main ====
sed '/# === Main ===/,$d' "$SCRIPT" > "$FUNC_H"
# убираем trap cleanup (в субшелл [1] rm -rf $TMPDIR убил бы общий каталог)
printf 'trap - EXIT\n' >> "$FUNC_H"
cat >> "$FUNC_H" <<'INJECT'
iptables() { return 0; }

# разрешение доменов -> только публичные IPv4 opencode
ips=$(resolve_domains)
echo "RESOLVE_COUNT=$(printf '%s\n' "$ips" | grep -c . )"
echo "RESOLVE_HAS_OPENCODE=$(printf '%s\n' "$ips" | grep -cE '^(172\.65\.|8\.6\.|8\.47\.|104\.18\.|172\.66\.|172\.64\.)' )"
echo "RESOLVE_HAS_PRIVATE=$(printf '%s\n' "$ips" | grep -cE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|0\.)' )"

# парсинг vless -> валидный xray json
cfg() {
    local url="$1" name="$2"
    local dir="$TESTS_DIR/cfg/$name"
    mkdir -p "$dir"
    vless_to_xray "$url" "$dir"
    python3 -m json.tool "$dir/config.json" >/dev/null 2>&1 && echo VALID || { cat "$dir/config.json"; echo INVALID; }
}

echo "REALITY=$(cfg 'vless://db9da8fb-c528-42ec-9b9e-e578cf934c04@195.19.164.93:443?encryption=none&flow=xtls-rprx-vision&fp=ios&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&security=reality&sni=sellflow.org&type=raw#Test' r)"
echo "REALITY_NET_TCP=$(grep -o '"network": "tcp"' "$TESTS_DIR/cfg/r/config.json" | head -1)"

echo "WS_NONE=$(cfg 'vless://2aa7f4b1-e859-46d0-b8ac-8587811ab7b1@212.67.9.113:2200?encryption=none&path=%2Fv1&security=none&type=ws#MegaMax' w)"
echo "WS_PATH_DECODED=$(grep -o '"path": "/v1"' "$TESTS_DIR/cfg/w/config.json" | head -1)"

echo "WS_TLS=$(cfg 'vless://2aa7f4b1-e859-46d0-b8ac-8587811ab7b1@mega.node.example:8443?encryption=none&security=tls&sni=cdn.example.com&fp=chrome&type=ws&path=%2Fws&host=cdn.example.com#TLSWS' t)"
echo "TLS_SNI=$(grep -o '"serverName": "cdn.example.com"' "$TESTS_DIR/cfg/t/config.json" | head -1)"

echo "GRPC=$(cfg 'vless://2aa7f4b1-e859-46d0-b8ac-8587811ab7b1@grpc.example:443?encryption=none&security=reality&sni=grpc.example.com&pbk=abc123&sid=1234&type=grpc&serviceName=svc#Grpc' g)"
echo "GRPC_SVC=$(grep -o '"serviceName": "svc"' "$TESTS_DIR/cfg/g/config.json" | head -1)"

echo "XHTTP=$(cfg 'vless://2aa7f4b1-e859-46d0-b8ac-8587811ab7b1@xh.example:443?encryption=none&security=reality&sni=x.example.com&pbk=abc&type=xhttp&path=%2Fxh&mode=auto#Xh' x)"
echo "XHTTP_NET=$(grep -o '"network": "xhttp"' "$TESTS_DIR/cfg/x/config.json" | head -1)"
echo "XHTTP_KEY=$(grep -o '"xhttpSettings"' "$TESTS_DIR/cfg/x/config.json" | head -1)"
echo "XHTTP_HOST_STR=$(grep -o '"host": "x.example.com"' "$TESTS_DIR/cfg/x/config.json" | head -1)"
echo "XHTTP_MODE=$(grep -o '"mode": "auto"' "$TESTS_DIR/cfg/x/config.json" | head -1)"
echo "XHTTP_NO_HTTPKEY=$(grep -c '"httpSettings"' "$TESTS_DIR/cfg/x/config.json")"

echo "BAD_NO_UUID=$(cfg 'vless://@host:443?security=none&type=tcp#bad' b)"

# === логика отбора кандидатов (мок) ===
# ping_host: мокаем /dev/tcp — недоступный host вернёт 99999
ping_host() {
    local h="$1" p="$2"
    case "$h" in
        dead.example) echo "99999 $h $p" ;;
        *.example)    echo "$((RANDOM % 200 + 10)) $h $p" ;;
        *)            echo "150 $h $p" ;;
    esac
}
# select_candidates заменяем лёгкой проверкой: BATCH=10, сортировка
SUBS="$TESTS_DIR/subs_pool_test"
{
  for i in $(seq 1 10); do echo "vless://uuid-$i@sv-$i.example:443?security=none&type=tcp#S$i"; done
  echo "vless://uuid-11@dead.example:443?security=none&type=tcp#Dead"
} > "$SUBS"
BATCH_SIZE=10
poolfile="$TESTS_DIR/pool.txt"
mapfile -t pool < <(grep -E '^vless://' "$SUBS" | shuf -n "$BATCH_SIZE")
printf '%s\n' "${pool[@]:-}" > "$poolfile" 2>/dev/null || true
results="$TESTS_DIR/ping_results.txt"
: > "$results"
while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    h=$(echo "$url" | sed -n 's|^vless://[^@]*@\([^:]*\):.*|\1|p')
    p=$(echo "$url" | sed -n 's|^vless://[^@]*@[^:]*:\([0-9]*\).*|\1|p')
    ping_host "$h" "$p" >> "$results" &
done < "$poolfile"
wait
sort -n "$results" | awk '$1 < 99999' | head -n 5 > "$TESTS_DIR/top5.txt"
echo "CAND_COUNT=$(wc -l < "$TESTS_DIR/top5.txt")"
echo "CAND_SORTED=$(sort -n "$TESTS_DIR/top5.txt" | awk '{print $1}' | tr '\n' ' ')"
echo "CAND_NO_DEAD=$(grep -c dead.example "$TESTS_DIR/top5.txt" || true)"
INJECT

echo "[1] Функциональные тесты"
bash "$FUNC_H"

echo ""
echo "[2] Тесты /etc/hosts (изолированно)"

# ==== hosts функции на временном файле ====
HOSTS_FILE="$TESTS_DIR/hosts_test"
cp /etc/hosts "$HOSTS_FILE"

run_hosts_setup() {
    local tmp
    tmp="$TESTS_DIR/tmp-hosts-1"
    sed "/# opencode-vpn/d" "$HOSTS_FILE" > "$tmp"
    local ip d
    declare -A seen
    for d in "${OPENCODE_DOMAINS[@]}"; do
        while IFS= read -r ip; do
            [[ -z "$ip" || -n "${seen[$ip]+x}" ]] && continue
            seen["$ip"]=1
            printf '%-15s %s %s\n' "$ip" "$d" "# opencode-vpn" >> "$tmp"
        done < <(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u)
    done
    cp "$tmp" "$HOSTS_FILE"
    rm -f "$tmp"
}

run_hosts_cleanup() {
    local tmp
    tmp="$TESTS_DIR/tmp-hosts-2"
    sed "/# opencode-vpn/d" "$HOSTS_FILE" > "$tmp"
    cp "$tmp" "$HOSTS_FILE"
    rm -f "$tmp"
}

run_hosts_setup
MARK_BEFORE=$(grep -c '# opencode-vpn' "$HOSTS_FILE" || true)
ORIG_LINE=$(grep -c "^127\.0\.1\.1" "$HOSTS_FILE" || true)

run_hosts_setup   # повторный запуск — без дубликатов
MARK_AFTER_RE=$(grep -c '# opencode-vpn' "$HOSTS_FILE" || true)

run_hosts_cleanup
MARK_AFTER_CLEAN=$(grep -c '# opencode-vpn' "$HOSTS_FILE" || true)
ORIG_AFTER=$(grep -c "^127\.0\.1\.1" "$HOSTS_FILE" || true)

echo "  ▸ hosts before=$MARK_BEFORE re=$MARK_AFTER_RE clean=$MARK_AFTER_CLEAN orig=$ORIG_LINE/$ORIG_AFTER"
if [[ "$MARK_BEFORE" -gt 0 && "$MARK_AFTER_RE" -eq "$MARK_BEFORE" && "$MARK_AFTER_CLEAN" -eq 0 && "$ORIG_AFTER" -eq "$ORIG_LINE" ]]; then
    PASS=$((PASS+1)); echo "  ▸ hosts_setup/cleanup: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ hosts_setup/cleanup: FAIL"
fi

# ==== 3. E2E: подписка + парсинг реального ключа ====
echo ""
echo "[3] E2E: подписка (base64/vless) + парсинг реальных ключей"
SUBS_TEST="$TESTS_DIR/subs.txt"
# Используем ту же логику загрузки, что и скрипт (env/локальный файл/fallback)
if download_subscription "$SUBS_TEST" 2>/dev/null; then
    PASS=$((PASS+1)); echo "  ▸ подписка скачана: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ подписка скачана: FAIL"
fi

if [[ -s "$SUBS_TEST" ]]; then
    TOTAL=$(grep -cE '^vless://' "$SUBS_TEST")
    echo "  ▸ vless-ключей: $TOTAL"
    if [[ "$TOTAL" -ge 5 ]]; then
        PASS=$((PASS+1)); echo "  ▸ vless-ключей >= 5: OK"
    else
        FAIL=$((FAIL+1)); echo "  ▸ vless-ключей >= 5: FAIL ($TOTAL)"
    fi

    # поддерживаемые ключи должны фильтроваться is_supported_key
    SUPP=$(grep -E '^vless://' "$SUBS_TEST" | while IFS= read -r k; do is_supported_key "$k" && echo S; done | grep -c . || true)
    echo "  ▸ поддерживаемых (is_supported_key): $SUPP"
    if [[ "$SUPP" -ge 1 ]]; then
        PASS=$((PASS+1)); echo "  ▸ есть поддерживаемые ключи: OK"
    else
        FAIL=$((FAIL+1)); echo "  ▸ есть поддерживаемые ключи: FAIL ($SUPP)"
    fi

    # парсим 5 случайных поддерживаемых реальных ключей через функцию
    V5=$(grep -E '^vless://' "$SUBS_TEST" | while IFS= read -r k; do is_supported_key "$k" && echo "$k"; done | shuf -n 5 | while IFS= read -r k; do
        d="$TESTS_DIR/v5_$RANDOM"; mkdir -p "$d"
        vless_to_xray "$k" "$d" && python3 -m json.tool "$d/config.json" >/dev/null 2>&1 && echo S || echo F
    done | tr -d '\n')
    echo "  ▸ проверка 5 случайных поддерживаемых ключей: $V5"
    if [[ "$V5" == "SSSSS" ]]; then
        PASS=$((PASS+1)); echo "  ▸ парсинг 5 случайных реальных ключей: OK"
    else
        FAIL=$((FAIL+1)); echo "  ▸ парсинг 5 случайных реальных ключей: FAIL ($V5)"
    fi
fi

# ==== 4. CLI-флаги и macOS-ветка (стабы, систему не трогаем) ====
echo ""
echo "[4] CLI и Darwin-dispatch (стабы)"

if bash "$SCRIPT" --help 2>/dev/null | grep -q -- "--daemon"; then
    PASS=$((PASS+1)); echo "  ▸ --help: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ --help: FAIL"
fi

if bash "$SCRIPT" --version 2>/dev/null | grep -qE '^ocvpn [0-9]+\.[0-9]+\.[0-9]+$'; then
    PASS=$((PASS+1)); echo "  ▸ --version: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ --version: FAIL"
fi

ST_OUT="$(bash "$SCRIPT" --status 2>/dev/null || true)"
if echo "$ST_OUT" | grep -q "^xray: " && echo "$ST_OUT" | grep -q "^порт 10808: " \
    && echo "$ST_OUT" | grep -q "^маршруты " && echo "$ST_OUT" | grep -q "^/etc/hosts: "; then
    PASS=$((PASS+1)); echo "  ▸ --status (секции): OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ --status (секции): FAIL"
fi

# Стабы Darwin-утилит (НЕ в /tmp: он бывает noexec — стабы бы не запустились)
mkdir -p "${HOME}/.cache"
STUBROOT="$(mktemp -d "${HOME}/.cache/ovpn-tests-XXXXXX")"
STUB="$STUBROOT/darwin-stub"
mkdir -p "$STUB"
cat > "$STUB/uname" <<'STUB_EOF'
#!/bin/bash
echo "Darwin"
STUB_EOF
cat > "$STUB/dscacheutil" <<'STUB_EOF'
#!/bin/bash
# dscacheutil -q host -a name <domain> -> один IPv4
echo "name: stub.example"
echo "ip_address: 93.184.216.34"
STUB_EOF
cat > "$STUB/dig" <<'STUB_EOF'
#!/bin/bash
echo "93.184.216.34"
STUB_EOF
cat > "$STUB/pfctl" <<'STUB_EOF'
#!/bin/bash
# pfctl -e | -f ... | -s rules : всегда успех, правил нет
exit 0
STUB_EOF
cat > "$STUB/iptables" <<'STUB_EOF'
#!/bin/bash
echo "STUB-iptables-called-unexpectedly" >&2
exit 1
STUB_EOF
chmod +x "$STUB"/*
DARWIN_LOAD="$TESTS_DIR/darwin-func.sh"
sed '/# === Main ===/,$d' "$SCRIPT" > "$DARWIN_LOAD"
printf 'trap - EXIT\n' >> "$DARWIN_LOAD"
cat >> "$DARWIN_LOAD" <<'INJECT2'
# pf/hosts пути — во временные файлы, /etc не трогаем
PF_ANCHOR_FILE="$TESTS_DIR/pf.anchor"
PF_CONF="$TESTS_DIR/pf.conf"
: > "$PF_CONF"
OPENCODE_DOMAINS=("stub.example")

echo "DARWIN_OS=$OCVPN_OS"
echo "DARWIN_RESOLVE=$(resolve_ipv4 stub.example)"
pf_anchor_content > "$TESTS_DIR/anchor.txt"
echo "ANCHOR_HAS_TABLE=$(grep -c '<ocvpn_targets>' "$TESTS_DIR/anchor.txt")"
echo "ANCHOR_HAS_RDR=$(grep -c 'rdr pass on lo0' "$TESTS_DIR/anchor.txt")"
echo "ANCHOR_HAS_IP=$(grep -c '93.184.216.34' "$TESTS_DIR/anchor.txt")"
pf_ensure_refs
pf_ensure_refs  # повтор — без дубликатов
echo "REFS_COUNT=$(grep -c -- "$PF_MARK" "$PF_CONF")"
pf_remove_refs
echo "REFS_AFTER_CLEAN=$(grep -c -- "$PF_MARK" "$PF_CONF" || true)"
# диспетчер обязан выбрать darwin-ветку и НЕ звать iptables
setup_routes_darwin() { echo "DARWIN_DISPATCH"; }
setup_routes
INJECT2
DARWIN_OUT="$(PATH="$STUB:$PATH" bash "$DARWIN_LOAD" 2>/dev/null)"

check_darwin() { # $1=имя $2=ожидаемая строка
    if echo "$DARWIN_OUT" | grep -qF "$2"; then
        PASS=$((PASS+1)); echo "  ▸ $1: OK"
    else
        FAIL=$((FAIL+1)); echo "  ▸ $1: FAIL"
    fi
}
check_darwin "darwin OS-detect" "DARWIN_OS=Darwin"
check_darwin "darwin resolve" "DARWIN_RESOLVE=93.184.216.34"
check_darwin "darwin anchor" "ANCHOR_HAS_RDR=1"
check_darwin "darwin anchor IP" "ANCHOR_HAS_IP=1"
check_darwin "darwin refs идемпотентны" "REFS_COUNT=3"
check_darwin "darwin refs cleanup" "REFS_AFTER_CLEAN=0"
check_darwin "darwin dispatch" "DARWIN_DISPATCH"
rm -rf "$STUBROOT"

# ==== 5. Вотчдог: лимиты opencode/zen/go, карантин, trap-регрессия ====
echo ""
echo "[5] Вотчдог лимитов и карантин"

limit_case() { # $1=want(yes/no) $2=имя $3=строка
    local want="$1" name="$2" line="$3" got="no"
    if is_rotatable_limit "$line"; then got="yes"; fi
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS+1)); echo "  ▸ лимит $name: OK"
    else
        FAIL=$((FAIL+1)); echo "  ▸ лимит $name: FAIL (want=$want got=$got)"
    fi
}

# Реальные образцы из лога opencode (IP-лимиты zen/console → ротируем)
limit_case yes "zen rate-limit" 'error.error="AI_APICallError: Rate limit exceeded. Please try again later.'
limit_case yes "console rate-limit" 'error.error="AI_APICallError: Error from provider (Console): Rate limit exceeded. Please try again later.'
limit_case yes "too-many" 'Upstream error: Too many requests, retry in 30s'
limit_case yes "http-429" 'request failed with status 429 from zen'
limit_case yes "reset-hint" 'Grok usage limit reached. It will reset in 25 minutes. To continue enable balance'
limit_case yes "account-rate" 'action.reason=account_rate_limit Usage limit reached. It will reset in 2 hours'
# Аккаунтное/гео/сеть (смена IP не поможет → НЕ ротируем; ollama игнорим целиком)
limit_case no "ollama-weekly" 'you (otumanov) have reached your weekly usage limit, upgrade: https://ollama.com/upgrade'
limit_case no "ollama-session" 'you (otumanov) have reached your session usage limit: https://ollama.com/settings'
limit_case no "billing" 'Insufficient balance. Manage your billing here: https://opencode.ai/workspace/wrk_01/billing'
limit_case no "geo" 'AI_APICallError: This model is not available in your country.'
limit_case no "forbidden" 'AI_APICallError: Forbidden'
limit_case no "model-off" 'AI_APICallError: Model is disabled'
limit_case no "net" 'AI_APICallError: Cannot connect to API: Unable to connect.'
limit_case no "cancel" 'Error: Task cancelled by user'
limit_case no "sql-noise" "SELECT * FROM uljsu_posts ORDER BY post_modified DESC LIMIT 20;"

reset_case() { # $1=want_hours $2=имя $3=строка
    local want="$1" name="$2" line="$3" got
    got="$(parse_reset_hours "$line")"
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS+1)); echo "  ▸ reset $name: OK"
    else
        FAIL=$((FAIL+1)); echo "  ▸ reset $name: FAIL (want=$want got=$got)"
    fi
}
reset_case 1 "минуты" "It will reset in 25 minutes."
reset_case 3 "часы" "It will reset in 3 hours."
reset_case 48 "дни" "It will reset in 2 days."
reset_case "$QUARANTINE_HOURS" "дефолт" "Rate limit exceeded. Please try again later."
reset_case 168 "потолок" "It will reset in 200 days."

# Карантин — на изолированном стейте
OCVPN_STATE_DIR="$TESTS_DIR/wstate"
QUARANTINE_FILE="$OCVPN_STATE_DIR/quarantine.tsv"
quarantine_add "1.2.3.4" "8443" "5.6.7.8" "test-limit" 6
if quarantine_blocked "1.2.3.4" "8443" ""; then
    PASS=$((PASS+1)); echo "  ▸ карантин host:port: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ карантин host:port: FAIL"
fi
if quarantine_blocked "" "" "5.6.7.8"; then
    PASS=$((PASS+1)); echo "  ▸ карантин exit-ip: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ карантин exit-ip: FAIL"
fi
if quarantine_blocked "9.9.9.9" "443" "" || quarantine_blocked "" "" "9.9.9.9"; then
    FAIL=$((FAIL+1)); echo "  ▸ карантин чужой: FAIL"
else
    PASS=$((PASS+1)); echo "  ▸ карантин чужой: OK"
fi
quarantine_add "9.9.9.9" "443" "9.9.9.9" "expired" 0
sleep 1
if quarantine_blocked "9.9.9.9" "443" ""; then
    FAIL=$((FAIL+1)); echo "  ▸ карантин expiry: FAIL"
else
    PASS=$((PASS+1)); echo "  ▸ карантин expiry: OK"
fi
if [[ "$(quarantine_count)" == "1" ]]; then
    PASS=$((PASS+1)); echo "  ▸ карантин count: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ карантин count: FAIL ($(quarantine_count))"
fi

# Trap-регрессия: read-only режимы не делают ЗАПИСЕЙ в iptables и не трогают hosts
# (стаб — НЕ в /tmp: там noexec)
mkdir -p "${HOME}/.cache"
TRAPROOT="$(mktemp -d "${HOME}/.cache/ovpn-traptest-XXXXXX")"
TRAPSTUB="$TRAPROOT/stub"
mkdir -p "$TRAPSTUB"
cat > "$TRAPSTUB/iptables" <<'STUB_EOF'
#!/bin/bash
echo "iptables $@" >> "$TRAP_CALLS"
exit 1
STUB_EOF
chmod +x "$TRAPSTUB/iptables"
export TRAP_CALLS="$TESTS_DIR/trap-calls.log"
: > "$TRAP_CALLS"
HOSTS_MD5_BEFORE="$(md5sum /etc/hosts | awk '{print $1}')"
PATH="$TRAPSTUB:$PATH" bash "$SCRIPT" --help >/dev/null 2>&1
PATH="$TRAPSTUB:$PATH" bash "$SCRIPT" --version >/dev/null 2>&1
if [[ -s "$TRAP_CALLS" ]]; then
    FAIL=$((FAIL+1)); echo "  ▸ trap help/version: FAIL (iptables вызывался)"
else
    PASS=$((PASS+1)); echo "  ▸ trap help/version: OK"
fi
: > "$TRAP_CALLS"
PATH="$TRAPSTUB:$PATH" bash "$SCRIPT" --status >/dev/null 2>&1 || true
if grep -qE 'iptables (-A|-D|-F|-X|-N)' "$TRAP_CALLS"; then
    FAIL=$((FAIL+1)); echo "  ▸ trap status-записи: FAIL"
else
    PASS=$((PASS+1)); echo "  ▸ trap status-записи: OK"
fi
HOSTS_MD5_AFTER="$(md5sum /etc/hosts | awk '{print $1}')"
if [[ "$HOSTS_MD5_BEFORE" == "$HOSTS_MD5_AFTER" ]]; then
    PASS=$((PASS+1)); echo "  ▸ trap hosts-нетронут: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ trap hosts-нетронут: FAIL"
fi
rm -rf "$TRAPROOT"

# ==== 6. CLI restart/subs ====
echo ""
echo "[6] Перезапуск и --subs"

if bash "$SCRIPT" --help 2>/dev/null | grep -q -- "--restart" \
    && bash "$SCRIPT" --help 2>/dev/null | grep -q -- "--new-ip" \
    && bash "$SCRIPT" --help 2>/dev/null | grep -q -- "--subs"; then
    PASS=$((PASS+1)); echo "  ▸ help ключи: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ help ключи: FAIL"
fi

# --new-ip без активного держателя: чистая ошибка, без побочек
# ВАЖНО: OCVPN_STATE_DIR передаётся через env, чтобы дочерний процесс
# НЕ видел реальный ~/.local/share/ocvpn/active.env
rc_newip=0
OCVPN_STATE_DIR="$TESTS_DIR/emptystate" bash "$SCRIPT" --new-ip </dev/null >/dev/null 2>&1 || rc_newip=$?
if [[ $rc_newip -ne 0 ]]; then
    PASS=$((PASS+1)); echo "  ▸ new-ip без держателя: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ new-ip без держателя: FAIL"
fi

# parse_subs_flag: файл / URL / мусор / пусто
PF_LOAD="$TESTS_DIR/subs-func.sh"
sed '/# === Main ===/,$d' "$SCRIPT" > "$PF_LOAD"
printf 'trap - EXIT\n' >> "$PF_LOAD"
printf 'vless://u1@1.2.3.4:443?security=none&type=tcp#One\nvless://u2@5.6.7.8:443?security=none&type=tcp#Two\n' > "$TESTS_DIR/keys.txt"
printf 'not a key\njust text\n' > "$TESTS_DIR/nokeys.txt"
subs_case() { # $1=имя $2=ожидаемый rc $3..=аргументы
    local name="$1" want="$2"; shift 2
    local rc=0
    ( set +e; source "$PF_LOAD" >/dev/null 2>&1; set +e; parse_subs_flag "$@" 2>/dev/null ) || rc=$?
    if [[ $rc == "$want" ]]; then
        PASS=$((PASS+1)); echo "  ▸ subs $name: OK"
    else
        FAIL=$((FAIL+1)); echo "  ▸ subs $name: FAIL (want rc=$want got $rc)"
    fi
}
subs_case "файл" 0 --subs "$TESTS_DIR/keys.txt"
subs_case "url" 0 --subs https://example.com/sub.txt
subs_case "флаг-после-команды" 0 --restart --subs https://example.com/sub.txt
subs_case "мусор" 2 --subs 'не файл и не ссылка'
subs_case "пусто" 2 --subs

# download_subscription из файла
dl_case() { # $1=имя $2=want_rc $3=файл
    local name="$1" want="$2" f="$3" rc=0
    ( source "$PF_LOAD" >/dev/null 2>&1; OCVPN_SUBS_FILE="$f" download_subscription "$TESTS_DIR/dl-out.txt" >/dev/null 2>&1 ) || rc=$?
    if [[ $rc == "$want" ]] && { [[ "$want" != 0 ]] || grep -q '^vless://' "$TESTS_DIR/dl-out.txt"; }; then
        PASS=$((PASS+1)); echo "  ▸ download $name: OK"
    else
        FAIL=$((FAIL+1)); echo "  ▸ download $name: FAIL (rc=$rc)"
    fi
}
dl_case "файл-с-ключами" 0 "$TESTS_DIR/keys.txt"
dl_case "нет-файла" 1 "$TESTS_DIR/nope.txt"
dl_case "без-vless" 1 "$TESTS_DIR/nokeys.txt"

# ==== 7. Geo-check (доступность моделей) ====
echo ""
echo "[7] Geo-check: доступность моделей"

# Функция check_model_available определена и вызываема
( source "$FUNC_LOAD" >/dev/null 2>&1; type check_model_available &>/dev/null )
if [[ $? -eq 0 ]]; then
    PASS=$((PASS+1)); echo "  ▸ check_model_available существует: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ check_model_available существует: FAIL"
fi

# GEO_BLOCK_PATTERNS определён и содержит ключевые паттерны
( source "$FUNC_LOAD" >/dev/null 2>&1; [[ ${#GEO_BLOCK_PATTERNS[@]} -ge 4 ]] )
if [[ $? -eq 0 ]]; then
    PASS=$((PASS+1)); echo "  ▸ GEO_BLOCK_PATTERNS >= 4: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ GEO_BLOCK_PATTERNS >= 4: FAIL"
fi

# FREE_MODELS определён
( source "$FUNC_LOAD" >/dev/null 2>&1; [[ ${#FREE_MODELS[@]} -ge 3 ]] )
if [[ $? -eq 0 ]]; then
    PASS=$((PASS+1)); echo "  ▸ FREE_MODELS >= 3: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ FREE_MODELS >= 3: FAIL"
fi

# quarantine_add с geo-block: записывается, quarantine_blocked возвращает 0
GEO_QDIR="$TESTS_DIR/geo"
mkdir -p "$GEO_QDIR"
( source "$FUNC_LOAD" >/dev/null 2>&1
  OCVPN_STATE_DIR="$GEO_QDIR"
  QUARANTINE_FILE="$GEO_QDIR/quarantine.tsv"
  touch "$QUARANTINE_FILE"
  quarantine_add "fr1.example.com" "443" "5.6.7.8" "geo-block: модели не доступны из региона" 12
  if quarantine_blocked "fr1.example.com" "443" ""; then
      echo "GEO_QUARANTINE_OK"
  else
      echo "GEO_QUARANTINE_FAIL"
  fi
) 2>/dev/null | grep -q GEO_QUARANTINE_OK
if [[ $? -eq 0 ]]; then
    PASS=$((PASS+1)); echo "  ▸ geo-block quarantine: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ geo-block quarantine: FAIL"
fi

# check_model_available с пустым auth.json: возвращает 0 (skip проверки)
GEO_EMPTY="$TESTS_DIR/empty-auth"
mkdir -p "$GEO_EMPTY/.local/share/ocvpn" "$GEO_EMPTY/.local/share/opencode"
echo '{}' > "$GEO_EMPTY/.local/share/opencode/auth.json"
CURL_STUB="$TESTS_DIR/curl-stub"
cat > "$CURL_STUB" <<'STUBEOF'
#!/bin/bash
echo "200"
STUBEOF
chmod +x "$CURL_STUB"
( source "$FUNC_LOAD" >/dev/null 2>&1
  HOME="$GEO_EMPTY"
  OCVPN_STATE_DIR="$GEO_EMPTY/.local/share/ocvpn"
  QUARANTINE_FILE="$GEO_EMPTY/.local/share/ocvpn/quarantine.tsv"
  touch "$QUARANTINE_FILE"
  PATH="$CURL_STUB:$PATH"
  check_model_available && echo "EMPTY_AUTH_OK" || echo "EMPTY_AUTH_FAIL"
) 2>/dev/null | grep -q EMPTY_AUTH_OK
if [[ $? -eq 0 ]]; then
    PASS=$((PASS+1)); echo "  ▸ пустой auth.json (skip): OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ пустой auth.json (skip): FAIL"
fi

# help содержит упоминание geo-block
bash "$SCRIPT" --help 2>/dev/null | grep -qi "geo-block\|geo.block\|доступность моделей\|регион"
if [[ $? -eq 0 ]]; then
    PASS=$((PASS+1)); echo "  ▸ help geo-check docs: OK"
else
    FAIL=$((FAIL+1)); echo "  ▸ help geo-check docs: FAIL"
fi

echo ""
echo "Итог: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]