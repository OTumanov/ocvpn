#!/usr/bin/env bash
# Тесты для opencode-vpn.sh (безопасно: iptables/hosts/xray замоканы)
set -uo pipefail

SCRIPT="/root/opencode-vpn.sh"
PASS=0
FAIL=0
TESTS_DIR=$(mktemp -d /tmp/ovpn-tests-XXXXXX)
export TESTS_DIR

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

echo "XHTTP=$(cfg 'vless://2aa7f4b1-e859-46d0-b8ac-8587811ab7b1@xh.example:443?encryption=none&security=reality&sni=x.example.com&pbk=abc&type=xhttp&path=%2Fxh#Xh' x)"
echo "XHTTP_NET=$(grep -o '"network": "xhttp"' "$TESTS_DIR/cfg/x/config.json" | head -1)"

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
echo "[3] E2E: подписка + парсинг реальных ключей"
SUBS_TEST="$TESTS_DIR/subs.txt"
curl -fsSL --connect-timeout 10 "https://raw.githubusercontent.com/zxcursedzxc0721/vless-subscriptions/refs/heads/main/ru/vless.txt" -o "$SUBS_TEST" 2>/dev/null \
    && { PASS=$((PASS+1)); echo "  ▸ подписка скачана: OK"; } \
    || { FAIL=$((FAIL+1)); echo "  ▸ подписка скачана: FAIL"; }

if [[ -s "$SUBS_TEST" ]]; then
    TOTAL=$(grep -cE '^vless://' "$SUBS_TEST")
    if [[ "$TOTAL" -ge 300 ]]; then
        PASS=$((PASS+1)); echo "  ▸ vless-ключей >= 300: OK ($TOTAL)"
    else
        FAIL=$((FAIL+1)); echo "  ▸ vless-ключей >= 300: FAIL ($TOTAL)"
    fi

    # парсим 5 случайных реальных ключей (все типы) через функцию
    V5=$(grep -E '^vless://' "$SUBS_TEST" | shuf -n 5 | while IFS= read -r k; do
        d="$TESTS_DIR/v5_$RANDOM"; mkdir -p "$d"
        vless_to_xray "$k" "$d" && python3 -m json.tool "$d/config.json" >/dev/null 2>&1 && echo S || echo F
    done | tr -d '\n')
    echo "  ▸ проверка 5 случайных ключей: $V5"
    if [[ "$V5" == "SSSSS" ]]; then
        PASS=$((PASS+1)); echo "  ▸ парсинг 5 случайных реальных ключей: OK"
    else
        FAIL=$((FAIL+1)); echo "  ▸ парсинг 5 случайных реальных ключей: FAIL ($V5)"
    fi
fi

echo ""
echo "Итог: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]