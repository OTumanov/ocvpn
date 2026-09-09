#!/usr/bin/env bash
set -euo pipefail

# === Config ===
SUBS_URL="https://raw.githubusercontent.com/zxcursedzxc0721/vless-subscriptions/refs/heads/main/ru/vless.txt"
SOCKS_PORT=10808
HTTP_PORT=10809
REDIRECT_PORT=12345
TEST_URL="https://www.google.com/generate_204"
TIMEOUT=5
BATCH_SIZE=10
MAX_TRIES=5
PING_TIMEOUT=3
XRAY_BIN=""
TMPDIR_BASE="/tmp/opencode-vpn"
IPTABLES_CHAIN="OPENCODE_VPN"
# Эндпоинты opencode, которые будут ходить через VPN
OPENCODE_DOMAINS=(
    "opencode.ai"
    "api.opencode.ai"
    "models.opencode.ai"
    "app.opencode.ai"
    "ai.zenifra.com"
    "zenmux.ai"
    "auth.openai.com"
)

# === Colors ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*" >&2; }

cleanup() {
    if [[ -n "${XRAY_PID:-}" ]] && kill -0 "$XRAY_PID" 2>/dev/null; then
        kill "$XRAY_PID" 2>/dev/null || true
        wait "$XRAY_PID" 2>/dev/null || true
    fi
    if [[ "${KEEP_ROUTES:-0}" != "1" ]]; then
        cleanup_routes
    fi
    rm -rf "$TMPDIR" 2>/dev/null || true
}
trap cleanup EXIT

# === Resolve opencode endpoint IPs ===
resolve_domains() {
    local ips=()
    for d in "${OPENCODE_DOMAINS[@]}"; do
        while IFS= read -r ip; do
            ips+=("$ip")
        done < <(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u)
    done
    # dedup
    printf '%s\n' "${ips[@]}" | sort -u
}

# === Flush REDIRECT rules (safe: только цепь OPENCODE_VPN) ===
cleanup_routes() {
    if iptables -t nat -L "$IPTABLES_CHAIN" >/dev/null 2>&1; then
        iptables -t nat -F "$IPTABLES_CHAIN" 2>/dev/null || true
    fi
    # Удаляем ссылку из OUTPUT (если есть)
    if iptables -t nat -S OUTPUT | grep -q -- "-j $IPTABLES_CHAIN"; then
        iptables -t nat -D OUTPUT -p tcp -j "$IPTABLES_CHAIN" 2>/dev/null || true
    fi
    if iptables -t nat -L "$IPTABLES_CHAIN" >/dev/null 2>&1; then
        iptables -t nat -X "$IPTABLES_CHAIN" 2>/dev/null || true
    fi
    hosts_cleanup
}

# === Форсировать IPv4-резолв эндпоинтов через /etc/hosts (маркер opencode-vpn) ===
HOSTS_MARK="# opencode-vpn"
hosts_setup() {
    local tmp
    mkdir -p "$TMPDIR_BASE" 2>/dev/null || true
    tmp=$(mktemp "${TMPDIR_BASE}/hosts.XXXXXX")
    # убрать старый блок
    sed "/^[^#]*$HOSTS_MARK\$/d" /etc/hosts > "$tmp" 2>/dev/null || cp /etc/hosts "$tmp"
    # собрать IPv4-адреса доменов
    local ip d
    declare -A seen
    for d in "${OPENCODE_DOMAINS[@]}"; do
        while IFS= read -r ip; do
            [[ -z "$ip" || -n "${seen[$ip]+x}" ]] && continue
            seen["$ip"]=1
            printf '%-15s %s %s\n' "$ip" "$d" "$HOSTS_MARK" >> "$tmp"
        done < <(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u)
    done
    # записать только если есть добавленные строки с маркером
    if grep -q -- "$HOSTS_MARK" "$tmp"; then
        cp "$tmp" /etc/hosts
        log "Добавлены IPv4-записи opencode в /etc/hosts (для принудительной IPv4-маршрутизации)"
    fi
    rm -f "$tmp"
}

hosts_cleanup() {
    local tmp
    mkdir -p "$TMPDIR_BASE" 2>/dev/null || true
    tmp=$(mktemp "${TMPDIR_BASE}/hosts.XXXXXX")
    sed "/$HOSTS_MARK\$/d" /etc/hosts > "$tmp"
    cp "$tmp" /etc/hosts
    rm -f "$tmp"
}

# === Apply REDIRECT: только IP эндпоинтов opencode, только dport 443, исходящий ===
setup_routes() {
    # Всегда чистим перед созданием
    cleanup_routes

    # Форсируем IPv4-резолв эндпоинтов (чтобы соединения гарантированно шли по IPv4)
    hosts_setup

    iptables -t nat -N "$IPTABLES_CHAIN" 2>/dev/null || true

    # 1) Не трогаем исходящий трафик xray (сам прокси) — иначе петля
    local xray_pid="${XRAY_PID:-}"
    if [[ -n "$xray_pid" ]] && [[ -r "/proc/$xray_pid" ]]; then
        iptables -t nat -A "$IPTABLES_CHAIN" -m owner --pid-owner "$xray_pid" -j RETURN
    fi

    # 2) Не трогаем private/локальные подсети (nginx, контейнеры, докер, ssh admin)
    iptables -t nat -A "$IPTABLES_CHAIN" -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A "$IPTABLES_CHAIN" -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A "$IPTABLES_CHAIN" -d 100.64.0.0/10 -j RETURN
    iptables -t nat -A "$IPTABLES_CHAIN" -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A "$IPTABLES_CHAIN" -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A "$IPTABLES_CHAIN" -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A "$IPTABLES_CHAIN" -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A "$IPTABLES_CHAIN" -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A "$IPTABLES_CHAIN" -d 240.0.0.0/4 -j RETURN

    # 3) Только OPENCODE IP на порт 443 → REDIRECT на прозрачный xray-порт
    local ip
    local n=0
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        iptables -t nat -A "$IPTABLES_CHAIN" -d "$ip" -p tcp --dport 443 -j REDIRECT --to-ports "$REDIRECT_PORT"
        log "  маршрут: $ip:443 → VPN"
        n=$((n+1))
    done < <(resolve_domains)

    if [[ $n -eq 0 ]]; then
        err "Не найден ни один IP эндпоинтов opencode. Отказываюсь от маршрутизации."
        cleanup_routes
        exit 1
    fi

    # 4) Подключаем цепь к OUTPUT (только новые исходящие TCP)
    iptables -t nat -A OUTPUT -p tcp -j "$IPTABLES_CHAIN"
    log "Маршрутизация активна: $n IP/доменов opencode → через VPN"
}

# === Find / auto-install xray ===
find_xray() {
    for bin in xray /usr/local/bin/xray /usr/bin/xray "$HOME/xray/xray"; do
        if command -v "$bin" &>/dev/null || [[ -x "$bin" ]]; then
            XRAY_BIN="$bin"
            return
        fi
    done

    warn "xray не найден. Устанавливаю автоматически..."
    local arch url
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="64" ;;
        aarch64|arm64)  arch="arm64-v8a" ;;
        *)
            err "Неподдерживаемая архитектура: $arch"
            exit 1
            ;;
    esac

    local ver zipdir
    # Get latest release tag
    ver=$(curl -fsSL --connect-timeout 10 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null) \
        || { err "Не удалось определить версию Xray"; exit 1; }
    ver="${ver#v}"

    url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-${arch}.zip"
    local instdir="$HOME/.local/opt/xray"
    mkdir -p "$instdir" "$HOME/bin"

    if ! command -v unzip &>/dev/null; then
        err "Нужен unzip: apt install unzip / yum install unzip"
        exit 1
    fi

    local zf="$TMPDIR/xray.zip"
    log "Скачиваю Xray v$ver (${arch})..."
    curl -fL --connect-timeout 15 "$url" -o "$zf" || { err "Не удалось скачать Xray: $url"; exit 1; }
    unzip -o -q "$zf" -d "$instdir"
    chmod +x "$instdir/xray"
    mkdir -p "$instdir/geoip" 2>/dev/null || true

    # Symlink into PATH
    ln -sf "$instdir/xray" "$HOME/bin/xray"
    if [[ -z "$(command -v xray)" ]]; then
        export PATH="$HOME/bin:$PATH"
    fi

    XRAY_BIN="$HOME/bin/xray"
    log "Xray установлен: $XRAY_BIN"
}

# === Parse vless URL -> xray JSON config ===
vless_to_xray() {
    local url="$1"
    local tmp="$2"

    # Decode the URL - extract parts
    local uuid host port params
    # vless://UUID@HOST:PORT?params#name
    uuid=$(echo "$url" | sed -n 's|^vless://\([^@]*\)@.*|\1|p')
    host=$(echo "$url" | sed -n 's|^vless://[^@]*@\([^:]*\):.*|\1|p')
    port=$(echo "$url" | sed -n 's|^vless://[^@]*@[^:]*:\([0-9]*\).*|\1|p')
    params=$(echo "$url" | sed -n 's|^vless://[^?]*?\([^#]*\).*|\1|p')
    local name
    name=$(echo "$url" | sed -n 's|^.*#\([^"]*\)$|\1|p' | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null || echo "node-$RANDOM")

    # Parse params
    local security="none" flow="" sni="" fp="" pbk="" sid="" alpn="" type="tcp" path="" host_param=""
    local serviceName="" mode=""
    IFS='&' read -ra PARAM_ARR <<< "$params"
    for p in "${PARAM_ARR[@]}"; do
        local key="${p%%=*}"
        local val="${p#*=}"
        case "$key" in
            security) security="$val" ;;
            flow)     flow="$val" ;;
            sni)      sni="$val" ;;
            fp)       fp="$val" ;;
            pbk)      pbk="$val" ;;
            sid)      sid="$val" ;;
            alpn)     alpn="$val" ;;
            type)     type="$val" ;;
            path)     path="$val" ;;
            host)     host_param="$val" ;;
            serviceName) serviceName="$val" ;;
            mode)     mode="$val" ;;
        esac
    done

    # URL-decode relevant params
    for v in path sni host_param serviceName; do
        local decoded
        decoded=$(printf '%s' "${!v}" | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))" 2>/dev/null || echo "${!v}")
        eval "$v=\$decoded"
    done

    # Map xray network types (raw = reality over tcp)
    [[ "$type" == "raw" ]] && type="tcp"

    # Determine SNI: use sni param, fallback to host_param, fallback to host
    [[ -z "$sni" ]] && sni="${host_param:-$host}"

    # Build TLS/reality settings
    local tls_settings=""
    local stream_settings=""

    if [[ "$security" == "reality" ]]; then
        stream_settings=$(cat <<REALITY_EOF
{
    "network": "$type",
    "security": "reality",
    "realitySettings": {
        "serverName": "$sni",
        "fingerprint": "${fp:-chrome}",
        "publicKey": "$pbk",
        "shortId": "$sid"
    }$(if [[ "$type" == "grpc" ]]; then echo ',
    "grpcSettings": {
        "serviceName": "'"$serviceName"'"
    }'; elif [[ "$type" == "ws" ]]; then echo ',
    "wsSettings": {
        "path": "'"$path"'",
        "headers": {
            "Host": "'"$sni"'"
        }
    }'; elif [[ "$type" == "xhttp" ]]; then echo ',
    "httpSettings": {
        "path": "'"$path"'",
        "host": ["'"$sni"'"]
    }'; fi)
}
REALITY_EOF
)
    elif [[ "$security" == "tls" ]]; then
        local alpn_json=""
        if [[ -n "$alpn" ]]; then
            alpn_json=$(echo "$alpn" | python3 -c "import sys,urllib.parse
raw=urllib.parse.unquote(sys.stdin.read()).replace('h2%2Chttp%2F1.1','h2,http/1.1')
vals=[a.strip() for a in raw.split(',') if a.strip()]
print('\"alpn\": ['+','.join('\"'+a+'\"' for a in vals)+']')" 2>/dev/null || echo "")
        fi
        stream_settings=$(cat <<TLS_EOF
{
    "network": "$type",
    "security": "tls",
    "tlsSettings": {
        "serverName": "$sni",
        "allowInsecure": false$(if [[ -n "$alpn_json" ]]; then echo ",
        $alpn_json"; fi)
    }$(if [[ "$type" == "ws" ]]; then echo ',
    "wsSettings": {
        "path": "'"$path"'",
        "headers": {
            "Host": "'"$sni"'"
        }
    }'; elif [[ "$type" == "grpc" ]]; then echo ',
    "grpcSettings": {
        "serviceName": "'"$serviceName"'"
    }'; elif [[ "$type" == "xhttp" ]]; then echo ',
    "httpSettings": {
        "path": "'"$path"'",
        "host": ["'"$sni"'"]
    }'; fi)
}
TLS_EOF
)
    else
        stream_settings=$(cat <<NONE_EOF
{
    "network": "$type"$(if [[ "$type" == "ws" ]]; then echo ',
    "wsSettings": {
        "path": "'"$path"'",
        "headers": {
            "Host": "'"$sni"'"
        }
    }'; elif [[ "$type" == "grpc" ]]; then echo ',
    "grpcSettings": {
        "serviceName": "'"$serviceName"'"
    }'; elif [[ "$type" == "xhttp" ]]; then echo ',
    "httpSettings": {
        "path": "'"$path"'",
        "host": ["'"$sni"'"]
    }'; fi)
}
NONE_EOF
)
    fi

    # Build flow string
    local flow_str=""
    [[ -n "$flow" ]] && flow_str="\"flow\": \"$flow\","

    # Write full xray config
    cat > "$tmp/config.json" <<XRAY_EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [
        {
            "tag": "socks",
            "port": $SOCKS_PORT,
            "listen": "127.0.0.1",
            "protocol": "socks",
            "settings": { "auth": "noauth", "udp": true }
        },
        {
            "tag": "http",
            "port": $HTTP_PORT,
            "listen": "127.0.0.1",
            "protocol": "http"
        },
        {
            "tag": "transparent",
            "port": $REDIRECT_PORT,
            "listen": "0.0.0.0",
            "protocol": "dokodemo-door",
            "settings": {
                "network": "tcp",
                "followRedirect": true
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        }
    ],
    "outbounds": [
        {
            "tag": "proxy",
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": "$host",
                        "port": $port,
                        "users": [
                            {
                                "id": "$uuid",
                                $flow_str
                                "encryption": "none"
                            }
                        ]
                    }
                ]
            },
            "streamSettings": $stream_settings
        },
        { "tag": "direct", "protocol": "freedom" }
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            { "type": "field", "outboundTag": "direct", "ip": ["geoip:private"] }
        ]
    }
}
XRAY_EOF
}

# === TCP-пинг до VLESS-сервера (быстрая проверка живости) ===
# Вывод: latency_ms host port
ping_host() {
    local host="$1" port="$2"
    local start end ms
    start=$(date +%s%N 2>/dev/null || echo 0)
    if timeout "${PING_TIMEOUT}" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
        end=$(date +%s%N 2>/dev/null || echo 0)
        if [[ $start != 0 && $end != 0 ]]; then
            ms=$(( (end - start) / 1000000 ))
        else
            ms=0
        fi
        echo "$ms $host $port"
    else
        echo "99999 $host $port"
    fi
}

# === Отбор 10 случайных ключей по короткому TCP-пингу ===
select_candidates() {
    local subs_file="$1"
    local poolfile="$TMPDIR/pool.txt"
    mapfile -t pool < <(grep -E '^vless://' "$subs_file" | shuf -n "${BATCH_SIZE}" 2>/dev/null)
    printf '%s\n' "${pool[@]:-}" > "$poolfile" 2>/dev/null || true

    # Параллельный пинг всех 10
    log "Пингую ${BATCH_SIZE} случайных серверов..."
    local results="$TMPDIR/ping_results.txt"
    : > "$results"
    local url host port
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        host=$(echo "$url" | sed -n 's|^vless://[^@]*@\([^:]*\):.*|\1|p')
        port=$(echo "$url" | sed -n 's|^vless://[^@]*@[^:]*:\([0-9]*\).*|\1|p')
        if [[ -n "$host" && -n "$port" ]]; then
            ping_host "$host" "$port" >> "$results" &
        fi
    done < "$poolfile"
    wait

    # Сортируем по latency, отбрасываем недоступные
    sort -n "$results" | awk '$1 < 99999' | head -n "${MAX_TRIES}"
}

# === Main ===
main() {
    if [[ "${1:-}" == "--cleanup" ]]; then
        mkdir -p "$TMPDIR_BASE"
        cleanup_routes
        log "Маршрутизация opencode-VPN отключена. Хост как был."
        exit 0
    fi

    # Check dependencies
    for cmd in curl python3 unzip; do
        command -v "$cmd" &>/dev/null || { err "Нужен $cmd"; exit 1; }
    done

    mkdir -p "$TMPDIR_BASE"
    TMPDIR=$(mktemp -d "$TMPDIR_BASE/XXXXXX")

    find_xray

    # Download subscription
    log "Скачиваю список серверов..."
    local subs_file="$TMPDIR/subs.txt"
    curl -fsSL --connect-timeout 10 "$SUBS_URL" -o "$subs_file" 2>/dev/null || { err "Не удалось скачать подписку"; exit 1; }

    local total
    total=$(grep -cE '^vless://' "$subs_file")
    if [[ "$total" -eq 0 ]]; then
        err "Нет vless серверов в подписке"
        exit 1
    fi
    log "Найдено $total серверов."

    # Отбор кандидатов с наименьшим пингом (порция из 10 случайных)
    local candidates
    mapfile -t candidates < <(select_candidates "$subs_file")

    if [[ ${#candidates[@]} -eq 0 ]]; then
        err "Ни один из ${BATCH_SIZE} серверов не ответил на ping. Пробую расширенный пул..."
        mapfile -t candidates < <(grep -E '^vless://' "$subs_file" | shuf | head -n "${MAX_TRIES}" \
            | while IFS= read -r url; do
                host=$(echo "$url" | sed -n 's|^vless://[^@]*@\([^:]*\):.*|\1|p')
                port=$(echo "$url" | sed -n 's|^vless://[^@]*@[^:]*:\([0-9]*\).*|\1|p')
                [[ -n "$host" && -n "$port" ]] && echo "99999 $host $port"
            done)
    fi

    log "Кандидаты (по пингу):"
    local tried=0
    for cand in "${candidates[@]}"; do
        ((tried++))
        local host cport
        host=$(echo "$cand" | awk '{print $2}')
        cport=$(echo "$cand" | awk '{print $3}')
        # Найти URL по host:port из основного списка
        local url=""
        url=$(grep -m1 -E "^vless://[^@]*@${host}:${cport}\b" "$subs_file" || true)
        if [[ -z "$url" ]]; then
            # fallback: ищем из рандомного пула
            url=$(grep -m1 "${host}:${cport}" "$subs_file" || true)
        fi
        [[ -z "$url" ]] && { warn "  нет URL для ${host}:${cport}, пропускаю"; continue; }

        local label
        label=$(echo "$url" | sed -n 's|^.*#\([^"]*\)$|\1|p' | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip())[:50])" 2>/dev/null || echo "node-$tried-${host}")

        warn "[$tried/${#candidates[@]}] Пробую: $label ($host:$cport)"

        local workdir="$TMPDIR/node_$tried"
        mkdir -p "$workdir"

        vless_to_xray "$url" "$workdir"

        "$XRAY_BIN" run -c "$workdir/config.json" &>/dev/null &
        XRAY_PID=$!
        sleep 1

        if ! kill -0 "$XRAY_PID" 2>/dev/null; then
            warn "  xray не запустился, пропускаю"
            continue
        fi

        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' \
            --proxy "socks5h://127.0.0.1:$SOCKS_PORT" \
            --connect-timeout "$TIMEOUT" \
            --max-time "$TIMEOUT" \
            "$TEST_URL" 2>/dev/null || echo "000")

        if [[ "$code" == "204" ]]; then
            log "  РАБОТАЕТ! (HTTP $code)"
            log "  Настраиваю маршрутизацию только для эндпоинтов opencode..."
            setup_routes
            log ""
            log "Готово. Только трафик к эндпоинтам opencode идёт через VPN (рабочий ключ: $label, $host:$cport)."
            log "Сайты на nginx и весь остальной хост — не тронуты."
            log "Запускай opencode сам. Для смены ключа/очистки: $0 --cleanup"
            # держим xray в foreground
            KEEP_ROUTES=1
            wait "$XRAY_PID" 2>/dev/null || true
            exit 0
        else
            warn "  Не работает (HTTP $code)"
            kill "$XRAY_PID" 2>/dev/null || true
            wait "$XRAY_PID" 2>/dev/null || true
        fi
    done

    err "Все кандидаты не сработали. Запусти ещё раз — будут другие случайные."
    exit 1
}

main "$@"
