#!/usr/bin/env bash
set -euo pipefail

# iptables обычно лежит в /usr/sbin или /sbin, которых может не быть в PATH
# (в частности под sudo/systemd с урезанным PATH). Добавляем, не затирая остальное.
export PATH="/usr/sbin:/sbin:$PATH"

OCVPN_VERSION="1.3.5"
# Linux (iptables REDIRECT) или macOS (pf rdr). Определяем один раз.
OCVPN_OS="$(uname -s 2>/dev/null || echo Linux)"
is_macos() { [[ "$OCVPN_OS" == "Darwin" ]]; }

# === Config ===
# Приоритет подписки: $OCVPN_SUBS_URL (env) > ~/.ocvpn-subs-url (файл пользователя)
#   > /etc/ocvpn/subs-url (системный — виден root/daemon/GUI через osascript) > fallback
SUBS_FALLBACK_URL="https://raw.githubusercontent.com/zxcursedzxc0721/vless-subscriptions/refs/heads/main/ru/vless.txt"
SUBS_URL="${OCVPN_SUBS_URL:-}"
if [[ -z "$SUBS_URL" && -s "$HOME/.ocvpn-subs-url" ]]; then
    SUBS_URL="$(head -n1 "$HOME/.ocvpn-subs-url" 2>/dev/null | tr -d '[:space:]')"
fi
if [[ -z "$SUBS_URL" && -s /etc/ocvpn/subs-url ]]; then
    SUBS_URL="$(head -n1 /etc/ocvpn/subs-url 2>/dev/null | tr -d '[:space:]')"
fi
SUBS_URL="${SUBS_URL:-$SUBS_FALLBACK_URL}"
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
# macOS (pf): якорь и маркер в /etc/pf.conf
PF_ANCHOR="com.otumanov.ocvpn"
PF_ANCHOR_FILE="/etc/pf.anchors/$PF_ANCHOR"
PF_CONF="/etc/pf.conf"
PF_MARK="# ocvpn anchor"
OCVPN_LOG="${OCVPN_LOG:-/var/log/ocvpn.log}"
# Эндпоинты opencode, которые будут ходить через VPN
OPENCODE_DOMAINS=(
    # --- Инфраструктура OpenCode (v1.18.30) ---
    "opencode.ai"          # console auth/device, /console/api/*, Zen (/zen/v1), Go (/zen/go/v1)
    "api.opencode.ai"      # GitHub App интеграция
    "models.opencode.ai"   # каталог моделей (models.json)
    "app.opencode.ai"      # upstream веб-UI сервера
    "opncd.ai"             # share-сервис
    # --- Провайдеры моделей (из ~/.local/share/opencode/auth.json) ---
    "api.deepseek.com"     # DeepSeek
    "ollama.com"           # Ollama Cloud
    "api.ollama.com"
    "openrouter.ai"        # OpenRouter
    "zenmux.ai"            # ZenMux
    "auth.openai.com"      # OpenAI OAuth
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
    # Процесс, который ничего не поднимал (read-only режимы, вотчер,
    # --rotate, родитель --daemon), НЕ трогает чужие маршруты и xray.
    if [[ -z "${TMPDIR:-}" && -z "${XRAY_PID:-}" && -z "${OCVPN_OWNER:-}" ]]; then
        return 0
    fi
    if [[ -n "${XRAY_PID:-}" ]] && kill -0 "$XRAY_PID" 2>/dev/null; then
        kill "$XRAY_PID" 2>/dev/null || true
        wait "$XRAY_PID" 2>/dev/null || true
    fi
    if [[ "${KEEP_ROUTES:-0}" != "1" ]]; then
        cleanup_routes
    fi
    rm -rf "${TMPDIR:-}" 2>/dev/null || true
}
trap cleanup EXIT
# no_cleanup: режимы без владения маршрутами — снять EXIT-trap сразу.
# Без этого --help/--version/--status/--watch/--rotate сносили бы живые
# маршруты чужого запущенного ocvpn при своём завершении.
no_cleanup() { trap - EXIT; }

# === Resolve IPv4 одного домена (Linux: getent, macOS: dscacheutil/dig/python) ===
resolve_ipv4() {
    local d="$1"
    if is_macos; then
        # 1) системный резолвер macOS
        dscacheutil -q host -a name "$d" 2>/dev/null \
            | awk '/^ip_address:/{print $2}' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u
        # 2) запасной вариант — dig, если dscacheutil ничего не дал
        if ! dscacheutil -q host -a name "$d" 2>/dev/null | grep -q ip_address; then
            dig +short A "$d" 2>/dev/null \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u
        fi
    else
        getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u
    fi
}

# === Resolve opencode endpoint IPs ===
resolve_domains() {
    local ips=()
    for d in "${OPENCODE_DOMAINS[@]}"; do
        while IFS= read -r ip; do
            ips+=("$ip")
        done < <(resolve_ipv4 "$d")
    done
    # dedup
    printf '%s\n' "${ips[@]}" | sort -u
}

# === Flush REDIRECT rules, Linux (safe: только цепь OPENCODE_VPN) ===
cleanup_routes_linux() {
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
    local ip d key
    declare -A seen
    for d in "${OPENCODE_DOMAINS[@]}"; do
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            # дедуп по паре domain+ip: один и тот же IP может обслуживать
            # несколько доменов, и каждый должен получить IPv4-запись
            key="$d|$ip"
            [[ -n "${seen[$key]+x}" ]] && continue
            seen["$key"]=1
            printf '%-15s %s %s\n' "$ip" "$d" "$HOSTS_MARK" >> "$tmp"
        done < <(resolve_ipv4 "$d")
    done
    # записать только если есть добавленные строки с маркером
    if grep -q -- "$HOSTS_MARK" "$tmp"; then
        cp "$tmp" /etc/hosts
        log "Добавлены IPv4-записи opencode в /etc/hosts (для принудительной IPv4-маршрутизации)"
    fi
    rm -f "$tmp"
}

hosts_cleanup() {
    # Нет наших записей — /etc/hosts не трогаем вообще (ни mtime, ни содержимого).
    grep -q -- "$HOSTS_MARK" /etc/hosts 2>/dev/null || return 0
    local tmp
    mkdir -p "$TMPDIR_BASE" 2>/dev/null || true
    tmp=$(mktemp "${TMPDIR_BASE}/hosts.XXXXXX")
    sed "/$HOSTS_MARK\$/d" /etc/hosts > "$tmp"
    cp "$tmp" /etc/hosts
    rm -f "$tmp"
}

# === Apply REDIRECT, Linux: только IP эндпоинтов opencode, только dport 443, исходящий ===
setup_routes_linux() {
    # Всегда чистим перед созданием
    cleanup_routes_linux

    # Форсируем IPv4-резолв эндпоинтов (чтобы соединения гарантированно шли по IPv4)
    hosts_setup

    iptables -t nat -N "$IPTABLES_CHAIN" 2>/dev/null || true

    # 1) Не трогаем исходящий трафик xray (сам прокси) — иначе петля
    #    owner --pid-owner поддерживается не везде (iptables-nft/контейнеры) — тогда пропускаем:
    #    петля исключается и так, т.к. REDIRECT ловит только opencode-IP:443, а xray ходит на IP VPN-сервера.
    local xray_pid="${XRAY_PID:-}"
    if [[ -n "$xray_pid" ]] && [[ -r "/proc/$xray_pid" ]]; then
        if iptables -t nat -A "$IPTABLES_CHAIN" -m owner --pid-owner "$xray_pid" -j RETURN 2>/dev/null; then
            log "  исключён трафик самого xray (pid $xray_pid)"
        else
            warn "  owner --pid-owner не поддержан ядром (iptables-nft?), правило исключения xray пропущено"
        fi
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
        cleanup_routes_linux
        exit 1
    fi

    # 4) Подключаем цепь к OUTPUT (только новые исходящие TCP)
    iptables -t nat -A OUTPUT -p tcp -j "$IPTABLES_CHAIN"
    log "Маршрутизация активна: $n IP/доменов opencode → через VPN"
}

# === macOS (pf): якорь с rdr локально-сгенерированных пакетов на lo0 ===
# Локальный трафик на macOS проходит через lo0, поэтому rdr вешаем туда.
# Приватные подсети исключать не нужно: rdr ловит только IP из таблицы целей.
pf_anchor_content() {
    local ip
    {
        echo "table <ocvpn_targets> persist {"
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            echo "  $ip"
        done < <(resolve_domains)
        echo "}"
        echo "rdr pass on lo0 proto tcp from any to <ocvpn_targets> port 443 -> 127.0.0.1 port $REDIRECT_PORT"
        echo "pass out route-to (lo0 127.0.0.1) proto tcp from any to <ocvpn_targets> port 443 keep state"
    }
}

pf_ensure_refs() {
    # Идемпотентно добавляем ссылки на якорь в /etc/pf.conf (с бэкапом оригинала)
    if grep -q -- "$PF_MARK" "$PF_CONF" 2>/dev/null; then
        return 0
    fi
    if [[ ! -f "${PF_CONF}.ocvpn-bak" ]]; then
        cp "$PF_CONF" "${PF_CONF}.ocvpn-bak"
    fi
    {
        echo ""
        echo "rdr-anchor \"$PF_ANCHOR\" $PF_MARK"
        echo "anchor \"$PF_ANCHOR\" $PF_MARK"
        echo "load anchor \"$PF_ANCHOR\" from \"$PF_ANCHOR_FILE\" $PF_MARK"
    } >> "$PF_CONF"
}

pf_remove_refs() {
    # Убираем наши строки из pf.conf; если остался только наш блок — чистим
    [[ -f "$PF_CONF" ]] || return 0
    local tmp
    tmp="$(mktemp /tmp/ocvpn-pf.XXXXXX)"
    sed "/$PF_MARK\$/d" "$PF_CONF" > "$tmp"
    cp "$tmp" "$PF_CONF"
    rm -f "$tmp"
}

setup_routes_darwin() {
    pf_remove_refs  # всегда чистим перед созданием (без бэкапа чужого)
    hosts_setup

    local n
    n=$(resolve_domains | grep -c . || true)
    if [[ "$n" -eq 0 ]]; then
        err "Не найден ни один IP эндпоинтов opencode. Отказываюсь от маршрутизации."
        hosts_cleanup
        exit 1
    fi

    pf_anchor_content > "$PF_ANCHOR_FILE"
    pf_ensure_refs
    # Включаем pf, если выключен (иначе rdr не работает)
    pfctl -e 2>/dev/null || true
    pfctl -f "$PF_CONF" 2>/dev/null || { err "pfctl -f $PF_CONF не сработал"; exit 1; }
    log "Маршрутизация активна (pf): $n IP/доменов opencode → через VPN"
}

cleanup_routes_darwin() {
    pf_remove_refs
    rm -f "$PF_ANCHOR_FILE"
    # Перезагружаем очищенный pf.conf, чтобы снять rdr (pf оставляем включённым —
    # его мог включить не только ocvpn; выключение — вручную: pfctl -d)
    if [[ -f "$PF_CONF" ]]; then
        pfctl -f "$PF_CONF" 2>/dev/null || true
    fi
    hosts_cleanup
}

# === Диспетчеры по ОС ===
setup_routes() {
    if is_macos; then setup_routes_darwin; else setup_routes_linux; fi
}

cleanup_routes() {
    if is_macos; then cleanup_routes_darwin; else cleanup_routes_linux; fi
}

# === Find / auto-install xray ===
find_xray() {
    for bin in xray /usr/local/bin/xray /usr/bin/xray "$HOME/bin/xray" "$HOME/.local/opt/xray/xray" "$HOME/xray/xray"; do
        if command -v "$bin" &>/dev/null || [[ -x "$bin" ]]; then
            XRAY_BIN="$bin"
            return
        fi
    done

    warn "xray не найден. Устанавливаю автоматически..."
    local arch url asset_os
    arch=$(uname -m)
    if is_macos; then
        asset_os="macos"
        case "$arch" in
            x86_64)        arch="64" ;;
            arm64|aarch64) arch="arm64" ;;
            *)
                err "Неподдерживаемая архитектура: $arch"
                exit 1
                ;;
        esac
    else
        asset_os="linux"
        case "$arch" in
            x86_64)  arch="64" ;;
            aarch64|arm64)  arch="arm64-v8a" ;;
            *)
                err "Неподдерживаемая архитектура: $arch"
                exit 1
                ;;
        esac
    fi

    local ver zipdir
    # Get latest release tag
    ver=$(curl -fsSL --connect-timeout 10 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null) \
        || { err "Не удалось определить версию Xray"; exit 1; }
    ver="${ver#v}"

    url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-${asset_os}-${arch}.zip"
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

# Генерация фрагмента настроек ws/grpc/xhttp для streamSettings.
# Возвращает ", <newline>  \"<type>Settings\": {...}" либо пусто. Вызывается в $( ) внутри heredoc.
ws_stream_settings() {
    [[ "$1" == "ws" ]] || return 0
    local path="$2" sni="$3"
    printf ',
    "wsSettings": {
        "path": "%s",
        "headers": {
            "Host": "%s"
        }
    }' "$path" "$sni"
}

grpc_stream_settings() {
    [[ "$1" == "grpc" ]] || return 0
    local service_name="$2"
    printf ',
    "grpcSettings": {
        "serviceName": "%s"
    }' "$service_name"
}

# Xray 26: транспорта xhttp использует ключ xhttpSettings (НЕ httpSettings), host — строка (НЕ массив).
xhttp_stream_settings() {
    [[ "$1" == "xhttp" ]] || return 0
    local path="$2" sni="$3" mode="$4"
    local mode_json=""
    if [[ -n "$mode" ]]; then
        mode_json=$(printf ',
        "mode": "%s"' "$mode")
    fi
    printf ',
    "xhttpSettings": {
        "path": "%s",
        "host": "%s"%s
    }' "$path" "$sni" "$mode_json"
}

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
    }$(xhttp_stream_settings "$type" "$path" "$sni" "$mode")
    $(grpc_stream_settings "$type" "$serviceName")
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
    }$(ws_stream_settings "$type" "$path" "$sni")
    $(xhttp_stream_settings "$type" "$path" "$sni" "$mode")
    $(grpc_stream_settings "$type" "$serviceName")
}
TLS_EOF
)
    else
        stream_settings=$(cat <<NONE_EOF
{
    "network": "$type"$(ws_stream_settings "$type" "$path" "$sni")
    $(xhttp_stream_settings "$type" "$path" "$sni" "$mode")
    $(grpc_stream_settings "$type" "$serviceName")
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
                "address": "$host",
                "port": $port,
                "id": "$uuid",
                "encryption": "none",
                $flow_str
                "level": 0
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
# Выбираем только vless-ключи тех типов, что умеет vless_to_xray.
select_candidates() {
    local subs_file="$1"
    local poolfile="$TMPDIR/pool.txt"
    mapfile -t pool < <(grep -E '^vless://' "$subs_file" | while IFS= read -r u; do
        is_supported_key "$u" && echo "$u"
    done | shuf -n "${BATCH_SIZE}" 2>/dev/null)
    printf '%s\n' "${pool[@]:-}" > "$poolfile" 2>/dev/null || true

    # Параллельный пинг всех 10
    log "Пингую ${BATCH_SIZE} случайных серверов..." >&2
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

# === Скачивание подписки с авто-декодированием base64 ===
# Многие провайдеры (V2Board/Marzban) отдают подписку в base64. Пишем в $1 декодированный текст.
download_subscription() {
    local out="$1"
    # Разовый источник через --subs: готовый файл с ключами (без скачивания)
    if [[ -n "${OCVPN_SUBS_FILE:-}" ]]; then
        [[ -f "$OCVPN_SUBS_FILE" ]] || { err "Файл ключей не найден: $OCVPN_SUBS_FILE"; return 1; }
        grep -qE '^vless://' "$OCVPN_SUBS_FILE" \
            || { err "В файле нет vless:// ключей: $OCVPN_SUBS_FILE"; return 1; }
        cp "$OCVPN_SUBS_FILE" "$out"
        log "Ключи из файла: $OCVPN_SUBS_FILE (разово, не сохраняется)"
        return 0
    fi
    local raw="$TMPDIR/sub_raw.$$"
    curl -fsSL --connect-timeout 10 "$SUBS_URL" -o "$raw" 2>/dev/null || { err "Не удалось скачать подписку"; return 1; }

    # Если это чистый vless-текст — используем как есть
    if grep -qE '^vless://' "$raw"; then
        cp "$raw" "$out"
    else
        # Пытаемся декодировать base64
        if base64 -d "$raw" > "$out" 2>/dev/null && grep -qE '^(vless|vmess|ss|trojan)://' "$out"; then
            log "Подписка в base64 — декодирована."
        else
            cp "$raw" "$out"
        fi
    fi
    rm -f "$raw"
}

# Поддерживаем ли мы тип ключа (только vless-типы, что умеет vless_to_xray)
is_supported_key() {
    local url="$1" t
    # тип берём строго из параметра type=, а не из подстроки во всём URL
    t=$(printf '%s' "$url" | sed -n 's/.*[?&]type=\([^&#]*\).*/\1/p')
    [[ -z "$t" ]] && t="tcp"
    case "$t" in
        tcp|raw|ws|grpc|xhttp) ;;
        *) return 1 ;;
    esac
    # xhttp c sing-box extra (packet-up/upstream) пока не поддерживаем в xray
    case "$url" in
        *"extra="*) return 1 ;;
    esac
    return 0
}

# === Автопереключение при лимитах opencode/zen/go ===
# Триггерит ТОЛЬКО IP-лимиты opencode.ai/zen/go (free-tier лимитируется по IP —
# смена выходного IP сбрасывает лимит). Аккаунтные лимиты (ollama, баланс,
# биллинг), геоблок и сетевые ошибки — НЕ триггерят: смена IP там не поможет.
# Карантин: в исходниках opencode фиксированного N нет — сервер присылает
# динамический reset (x-ratelimit-reset / retry-after), клиент показывает
# «Usage limit reached. It will reset in N minutes/hours/days». Если такой
# хинт есть в строке лога — карантин выставляется по нему (+запас), иначе
# QUARANTINE_HOURS по умолчанию.
OCVPN_STATE_DIR="${OCVPN_STATE_DIR:-$HOME/.local/share/ocvpn}"
QUARANTINE_FILE="$OCVPN_STATE_DIR/quarantine.tsv"
ROTATIONS_LOG="$OCVPN_STATE_DIR/rotations.tsv"
ACTIVE_FILE="$OCVPN_STATE_DIR/active.env"
WATCH_PIDFILE="$OCVPN_STATE_DIR/watch.pid"
LAST_ROTATE_FILE="$OCVPN_STATE_DIR/last_rotate"
REASON_FILE="$OCVPN_STATE_DIR/rotate.reason"
ROTATE_HOUR_FILE="$OCVPN_STATE_DIR/rotate_hour"
QUARANTINE_HOURS="${OCVPN_QUARANTINE_HOURS:-6}"
ROTATE_COOLDOWN="${OCVPN_ROTATE_COOLDOWN:-600}"
ROTATE_MAX_PER_HOUR="${OCVPN_ROTATE_MAX_PER_HOUR:-6}"
OPENCODE_LOG="${OCVPN_OPENCODE_LOG:-$HOME/.local/share/opencode/log/opencode.log}"
ACTIVE_HOST=""; ACTIVE_PORT=""; ACTIVE_LABEL=""; ACTIVE_EXIT_IP=""

ROTATE_PATTERNS=(
    "Rate limit exceeded"
    "Too many requests"
    "429"
    "usage limit.*reset in"
    "account_rate_limit"
)
EXCLUDE_PATTERNS=(
    "ollama"
    "Insufficient balance"
    "/billing"
    "not available in your country"
    "Forbidden"
    "Model is disabled"
    "Cannot connect"
    "Task cancelled"
)

# 0 = строка лога — IP-лимит opencode/zen/go, надо ротировать
is_rotatable_limit() {
    local line="$1" p
    for p in "${EXCLUDE_PATTERNS[@]}"; do
        if printf '%s' "$line" | grep -qiF -- "$p"; then
            return 1
        fi
    done
    for p in "${ROTATE_PATTERNS[@]}"; do
        if printf '%s' "$line" | grep -qiE -- "$p"; then
            return 0
        fi
    done
    return 1
}

# Карантин в часах по хинту «reset in N minute/hour/day», иначе дефолт
parse_reset_hours() {
    local line="$1" n unit h
    if [[ "$line" =~ [Rr]eset\ in\ ([0-9]+)\ (minute|hour|day) ]]; then
        n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
        case "$unit" in
            minute) h=$(( (n + 59) / 60 )); [[ $h -lt 1 ]] && h=1 ;;
            hour)   h="$n" ;;
            day)    h=$(( n * 24 )) ;;
        esac
        [[ $h -gt 168 ]] && h=168
        echo "$h"
    else
        echo "$QUARANTINE_HOURS"
    fi
}

quarantine_prune() {
    mkdir -p "$OCVPN_STATE_DIR"
    touch "$QUARANTINE_FILE"
    local now tmp
    now=$(date +%s)
    tmp="$(mktemp "${OCVPN_STATE_DIR}/q.XXXXXX")"
    awk -F'\t' -v now="$now" '$4 > now' "$QUARANTINE_FILE" > "$tmp"
    mv "$tmp" "$QUARANTINE_FILE"
}

# quarantine_add host port exit_ip reason hours
quarantine_add() {
    local host="$1" port="$2" ip="$3" reason="$4" hours="${5:-$QUARANTINE_HOURS}"
    local clean
    clean="$(printf '%s' "$reason" | tr '\t\n' '  ' | cut -c1-160)"
    quarantine_prune
    local exp
    exp=$(($(date +%s) + hours * 3600))
    printf '%s\t%s\t%s\t%s\t%s\n' "$host" "$port" "$ip" "$exp" "$clean" >> "$QUARANTINE_FILE"
    log "Карантин: ${host}:${port} / ${ip} на ${hours} ч"
}

# quarantine_blocked host port exit_ip → 0 если сервер или exit IP в карантине
quarantine_blocked() {
    local host="$1" port="$2" ip="$3"
    quarantine_prune
    [[ -s "$QUARANTINE_FILE" ]] || return 1
    awk -F'\t' -v h="$host" -v p="$port" -v ip="$ip" \
        '($1 == h && $2 == p) || (ip != "" && $3 == ip) {found=1} END{exit !found}' \
        "$QUARANTINE_FILE"
}

quarantine_count() {
    quarantine_prune
    grep -c . "$QUARANTINE_FILE" 2>/dev/null || echo 0
}

# === Проверка доступности моделей через opencode API (geo-block детект) ===
# После HTTP 204 (VPN жив) делаем минимальный запрос к opencode API
# с конкретными free-моделями, которые реально блокируются по GeoIP.
# Если хотя бы одна free-модель доступна — регион ОК.
# Если ВСЕ free-модели вернули geo-block — exit IP нерабочий.
# Возвращает 0 = доступно (хотя бы одна free OK), 1 = все заблокированы.
FREE_MODELS=(
    "opencode/muse-spark-1.3-contributor-free"
    "opencode/muse-spark-1.2-contributor-free"
    "opencode/ling-3.0-flash-fin-free"
    "opencode/nemotron-3-ultra-free"
    "opencode/mimo-v2.5-free"
)
GEO_BLOCK_PATTERNS=(
    "not available in your country"
    "not available in your region"
    "not supported in your country"
    "not supported in your region"
    "geo restricted"
    "unavailable in your area"
    "forbidden.*country"
    "blocked.*region"
)
check_model_available() {
    local api_key=""
    local auth_file="$HOME/.local/share/opencode/auth.json"
    if [[ -f "$auth_file" ]]; then
        api_key=$(python3 -c "
import json, sys
try:
    d = json.load(open('$auth_file'))
    print(d.get('opencode', {}).get('key', ''))
except: pass
" 2>/dev/null) || true
    fi
    if [[ -z "$api_key" ]]; then
        warn "  auth.json не найден или нет ключа opencode — пропускаю проверку моделей"
        return 0
    fi
    local ok_count=0 blocked_count=0 total=${#FREE_MODELS[@]}
    local model
    for model in "${FREE_MODELS[@]}"; do
        local payload
        payload=$(printf '{"model":"%s","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' "$model")
        local http_code body
        body=$(curl -s -w '\n%{http_code}' \
            --proxy "socks5h://127.0.0.1:$SOCKS_PORT" \
            --connect-timeout 8 --max-time 12 \
            -X POST "https://api.opencode.ai/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $api_key" \
            -d "$payload" 2>/dev/null) || true
        http_code=$(printf '%s' "$body" | tail -n1)
        body=$(printf '%s' "$body" | sed '$d')
        local short_model="${model#opencode/}"
        # 200/201 = OK, 429 = rate limit (не geo, считаем OK)
        if [[ "$http_code" == "200" || "$http_code" == "201" || "$http_code" == "429" ]]; then
            ok_count=$((ok_count+1))
            continue
        fi
        # Проверяем body на geo-паттерны
        local lower_body is_geo=0
        lower_body=$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')
        local pat
        for pat in "${GEO_BLOCK_PATTERNS[@]}"; do
            if printf '%s' "$lower_body" | grep -qiE -- "$pat" 2>/dev/null; then
                is_geo=1; break
            fi
        done
        # HTTP 403/451 без явного geo-паттерна — тоже geo-block
        if [[ "$is_geo" -eq 0 && ("$http_code" == "403" || "$http_code" == "451") ]]; then
            is_geo=1
        fi
        if [[ "$is_geo" -eq 1 ]]; then
            blocked_count=$((blocked_count+1))
            warn "  $short_model: GEO-BLOCK (HTTP $http_code)"
        else
            # 500/502/timeout — проблемы сервера, не geo
            ok_count=$((ok_count+1))
        fi
    done
    log "  Модели: $ok_count/$total доступны, $blocked_count/$total заблокированы"
    if [[ "$ok_count" -eq 0 ]]; then
        return 1
    fi
    return 0
}

# Текущий выходной IP через поднятый SOCKS (пусто — прокси недоступен)
current_exit_ip() {
    local ip=""
    ip=$(curl -fsSL --max-time 8 --proxy "socks5h://127.0.0.1:$SOCKS_PORT" \
        https://api.ipify.org 2>/dev/null) \
    || ip=$(curl -fsSL --max-time 8 --proxy "socks5h://127.0.0.1:$SOCKS_PORT" \
        https://ipinfo.io/ip 2>/dev/null) || true
    ip="$(printf '%s' "${ip:-}" | tr -d '[:space:]')"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "$ip"
    fi
    return 0
}

SUBS_FILE=""

fetch_subscription() {
    log "Скачиваю список серверов..."
    SUBS_FILE="$TMPDIR/subs.txt"
    download_subscription "$SUBS_FILE" || return 1
    local total
    total=$(grep -cE '^vless://' "$SUBS_FILE")
    if [[ "$total" -eq 0 ]]; then
        err "Нет vless серверов в подписке"
        return 1
    fi
    log "Найдено $total серверов (vless)."
}

# pick_working_key [exclude_ip]: перебирает кандидатов, поднимает рабочий xray.
# Успех → 0; установлены XRAY_PID, ACTIVE_LABEL/HOST/PORT/EXIT_IP. xray ОСТАЁТСЯ запущен.
# Кандидаты из карантина и с exclude_ip пропускаются (нужен ДРУГОЙ выходной IP).
pick_working_key() {
    local exclude_ip="${1:-}"
    local candidates
    mapfile -t candidates < <(select_candidates "$SUBS_FILE")

    if [[ ${#candidates[@]} -eq 0 ]]; then
        err "Ни один из ${BATCH_SIZE} серверов не ответил на ping. Пробую расширенный пул..."
        mapfile -t candidates < <(grep -E '^vless://' "$SUBS_FILE" | while IFS= read -r u; do
            is_supported_key "$u" && echo "$u"
        done | shuf | head -n "${MAX_TRIES}" \
            | while IFS= read -r url; do
                host=$(echo "$url" | sed -n 's|^vless://[^@]*@\([^:]*\):.*|\1|p')
                port=$(echo "$url" | sed -n 's|^vless://[^@]*@[^:]*:\([0-9]*\).*|\1|p')
                [[ -n "$host" && -n "$port" ]] && echo "99999 $host $port"
            done)
    fi

    log "Кандидаты (по пингу):"
    local tried=0
    for cand in "${candidates[@]}"; do
        tried=$((tried+1))
        local host cport
        host=$(echo "$cand" | awk '{print $2}')
        cport=$(echo "$cand" | awk '{print $3}')
        # Найти URL по host:port из основного списка (предпочтительно поддерживаемого типа)
        local url=""
        while IFS= read -r u; do
            if is_supported_key "$u"; then url="$u"; break; fi
        done < <(grep -E "^vless://[^@]*@${host}:${cport}" "$SUBS_FILE" || true)
        if [[ -z "$url" ]]; then
            # fallback: любой vless с этим host:port
            url=$(grep -m1 -E "^vless://[^@]*@${host}:${cport}" "$SUBS_FILE" || true)
        fi
        [[ -z "$url" ]] && { warn "  нет URL для ${host}:${cport}, пропускаю"; continue; }
        if quarantine_blocked "$host" "$cport" ""; then
            warn "  ${host}:${cport} в карантине, пропускаю"
            continue
        fi

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
            "$TEST_URL" 2>/dev/null || true)

        if [[ "$code" == "204" ]]; then
            local exit_ip
            exit_ip="$(current_exit_ip)"
            if [[ -n "$exclude_ip" && "$exit_ip" == "$exclude_ip" ]]; then
                warn "  тот же exit IP ($exit_ip) — нужен ДРУГОЙ, пропускаю"
                kill "$XRAY_PID" 2>/dev/null || true
                wait "$XRAY_PID" 2>/dev/null || true
                continue
            fi
            if [[ -n "$exit_ip" ]] && quarantine_blocked "" "" "$exit_ip"; then
                warn "  exit IP $exit_ip в карантине, пропускаю"
                kill "$XRAY_PID" 2>/dev/null || true
                wait "$XRAY_PID" 2>/dev/null || true
                continue
            fi
            # Проверяем доступность моделей opencode из текущего региона
            if ! check_model_available; then
                warn "  exit IP $exit_ip: модели заблокированы по региону — карантин 12 ч"
                quarantine_add "$host" "$cport" "$exit_ip" "geo-block: модели не доступны из региона" 12
                kill "$XRAY_PID" 2>/dev/null || true
                wait "$XRAY_PID" 2>/dev/null || true
                continue
            fi
            ACTIVE_LABEL="$label"
            ACTIVE_HOST="$host"
            ACTIVE_PORT="$cport"
            ACTIVE_EXIT_IP="$exit_ip"
            log "  РАБОТАЕТ! (HTTP $code, exit IP ${exit_ip:-?})"
            return 0
        else
            warn "  Не работает (HTTP $code)"
            kill "$XRAY_PID" 2>/dev/null || true
            wait "$XRAY_PID" 2>/dev/null || true
        fi
    done

    return 1
}

# Фиксирует активный ключ: маршруты + active.env для --rotate/--status/GUI
activate_current() {
    log "  Настраиваю маршрутизацию только для эндпоинтов opencode..."
    setup_routes
    log ""
    log "Готово. Только трафик к эндпоинтам opencode идёт через VPN (рабочий ключ: $ACTIVE_LABEL, $ACTIVE_HOST:$ACTIVE_PORT, exit IP ${ACTIVE_EXIT_IP:-?})."
    log "Сайты на nginx и весь остальной хост — не тронуты."
    log "Запускай opencode сам. Для смены ключа/очистки: $0 --cleanup"
    mkdir -p "$OCVPN_STATE_DIR"
    local tmp
    tmp="$(mktemp "${OCVPN_STATE_DIR}/active.XXXXXX")"
    {
        echo "HOLDER_PID=$$"
        echo "XRAY_PID=$XRAY_PID"
        echo "ACTIVE_HOST=$ACTIVE_HOST"
        echo "ACTIVE_PORT=$ACTIVE_PORT"
        printf 'ACTIVE_LABEL=%q\n' "$ACTIVE_LABEL"
        echo "ACTIVE_EXIT_IP=$ACTIVE_EXIT_IP"
        echo "STARTED=$(date +%s)"
    } > "$tmp"
    mv "$tmp" "$ACTIVE_FILE"
}

# Ротация внутри держателя (по USR1 от --rotate/вотчдога).
# Старый ключ гасится ТОЛЬКО после проверки нового — обрыва нет.
ROTATING=0
rotate_now() {
    [[ "$ROTATING" == "1" ]] && { warn "Ротация уже идёт, пропускаю"; return 0; }
    [[ -z "${ACTIVE_HOST:-}" ]] && return 0  # ещё не подключены — нечего ротировать
    ROTATING=1
    local reason hours old_pid old_ip old_host old_port
    reason="$(tr '\t\n' '  ' < "$REASON_FILE" 2>/dev/null | cut -c1-200)"
    [[ -z "$reason" ]] && reason="limit (watchdog)"
    hours="$(parse_reset_hours "$reason")"
    old_pid="$XRAY_PID"; old_ip="$ACTIVE_EXIT_IP"
    old_host="$ACTIVE_HOST"; old_port="$ACTIVE_PORT"
    quarantine_add "$old_host" "$old_port" "$old_ip" "$reason" "$hours"
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$old_ip" "quarantined:${hours}h" "$reason" >> "$ROTATIONS_LOG"
    if ! fetch_subscription; then
        err "Ротация: не скачалась подписка — старый ключ продолжает работать"
        ROTATING=0
        return 1
    fi
    if pick_working_key "$old_ip"; then
        kill "$old_pid" 2>/dev/null || true
        wait "$old_pid" 2>/dev/null || true
        activate_current
        printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$old_ip" "$ACTIVE_EXIT_IP" "$ACTIVE_LABEL" >> "$ROTATIONS_LOG"
        echo "$(date +%s)" > "$LAST_ROTATE_FILE"
        log "РОТАЦИЯ: ${old_ip} → ${ACTIVE_EXIT_IP} (${ACTIVE_LABEL})"
    else
        err "Ротация не удалась (нет ключей с другим IP) — старый ключ продолжает работать"
    fi
    ROTATING=0
}
trap rotate_now USR1

# Держатель: ждём xray; смерть xray = выход (перезапустит systemd/launchd).
# Ротация по USR1 подменяет XRAY_PID на лету — такой wait просто продолжается.
supervise() {
    while true; do
        wait "$XRAY_PID" 2>/dev/null || true
        if kill -0 "$XRAY_PID" 2>/dev/null; then
            continue
        fi
        err "xray (pid $XRAY_PID) завершился. Выход — перезапустит systemd/launchd."
        exit 1
    done
}

# --restart: прибить держателя (если есть) и поднять свежий ключ В ФОНЕ.
# В терминал — пара строк, весь подбор — в $OCVPN_LOG.
do_restart() {
    no_cleanup
    local old_ip="" old_started=""
    if [[ -f "$ACTIVE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$ACTIVE_FILE" 2>/dev/null || true
        old_ip="${ACTIVE_EXIT_IP:-}"; old_started="${STARTED:-}"
        if [[ -n "${HOLDER_PID:-}" ]] && kill -0 "$HOLDER_PID" 2>/dev/null; then
            log "Глушу держателя (pid $HOLDER_PID, exit IP ${old_ip:-?})…"
            kill "$HOLDER_PID" 2>/dev/null || true
            local i
            for i in $(seq 1 15); do
                kill -0 "$HOLDER_PID" 2>/dev/null || break
                sleep 1
            done
            if kill -0 "$HOLDER_PID" 2>/dev/null; then
                kill -9 "$HOLDER_PID" 2>/dev/null || true
                sleep 1
            fi
            log "Держатель остановлен (маршруты сняты его trap'ом)."
        fi
    fi
    # Ждём освобождения SOCKS-порта — признак, что старый xray точно умер
    local i
    for i in $(seq 1 15); do
        (exec 3<>/dev/tcp/127.0.0.1/$SOCKS_PORT) 2>/dev/null || break
        exec 3>&- 2>/dev/null || true
        sleep 1
    done
    mkdir -p "$(dirname "$OCVPN_LOG")"
    log "Подбираю новый ключ в фоне (лог $OCVPN_LOG)…"
    setsid nohup "$0" </dev/null >>"$OCVPN_LOG" 2>&1 &
    local bgpid=$!
    # Ждём свежий active.env (подбор: подписка+пинг+тесты, обычно < 90 сек)
    local j
    for j in $(seq 1 90); do
        sleep 2
        kill -0 "$bgpid" 2>/dev/null || break
        if [[ -f "$ACTIVE_FILE" ]]; then
            local ns nip
            ns="$(grep -E '^STARTED=' "$ACTIVE_FILE" 2>/dev/null | cut -d= -f2)"
            nip="$(grep -E '^ACTIVE_EXIT_IP=' "$ACTIVE_FILE" 2>/dev/null | cut -d= -f2)"
            if [[ -n "$ns" && "$ns" != "$old_started" && -n "$nip" ]]; then
                if [[ -n "$old_ip" && "$nip" == "$old_ip" ]]; then
                    log "Выпал тот же IP ($nip) — добираю другой…"
                    bash "$0" --rotate "restart: тот же IP" >/dev/null 2>&1 || true
                    sleep 5
                    nip="$(grep -E '^ACTIVE_EXIT_IP=' "$ACTIVE_FILE" 2>/dev/null | cut -d= -f2)"
                fi
                log "Готово в фоне: exit IP ${nip:-?} (было ${old_ip:-none}). Детали: $OCVPN_LOG"
                return 0
            fi
        fi
    done
    if kill -0 "$bgpid" 2>/dev/null; then
        log "Подбор ещё идёт в фоне (pid $bgpid) — смотри: tail -f $OCVPN_LOG"
        return 0
    fi
    err "Фоновый подбор упал — смотри хвост: tail -n 30 $OCVPN_LOG"
    return 1
}

# --rotate [reason]: отдельный процесс — просит держателя переключиться
do_rotate() {
    no_cleanup
    local reason="${1:-ручная ротация}"
    [[ -f "$ACTIVE_FILE" ]] || { err "Нет активного подключения ($ACTIVE_FILE). Запустите ocvpn сначала."; exit 1; }
    # shellcheck disable=SC1090
    source "$ACTIVE_FILE"
    if ! kill -0 "${HOLDER_PID:-0}" 2>/dev/null; then
        err "Держатель (pid ${HOLDER_PID:-?}) не запущен. Ротировать нечего."
        exit 1
    fi
    local before="${STARTED:-0}"
    printf '%s' "$reason" > "$REASON_FILE"
    kill -USR1 "$HOLDER_PID"
    log "Сигнал ротации отправлен (pid $HOLDER_PID), жду новый IP…"
    local i
    for i in $(seq 1 60); do
        sleep 2
        # shellcheck disable=SC1090
        source "$ACTIVE_FILE"
        if [[ "${STARTED:-0}" != "$before" && -n "${ACTIVE_EXIT_IP:-}" ]]; then
            log "РОТАЦИЯ выполнена: exit IP ${ACTIVE_EXIT_IP} (${ACTIVE_LABEL:-?})"
            return 0
        fi
    done
    err "Ротация не подтвердилась за 120 сек — смотри лог $OCVPN_LOG"
    exit 1
}

# --watch: следит за логом opencode, ловит IP-лимиты, дёргает --rotate
do_watch() {
    no_cleanup
    if [[ -f "$WATCH_PIDFILE" ]] && kill -0 "$(cat "$WATCH_PIDFILE" 2>/dev/null)" 2>/dev/null; then
        err "Вотчдог уже запущен (pid $(cat "$WATCH_PIDFILE")). Дубль не стартую."
        exit 1
    fi
    [[ -f "$OPENCODE_LOG" ]] || { err "Лог opencode не найден: $OPENCODE_LOG"; exit 1; }
    mkdir -p "$OCVPN_STATE_DIR"
    echo $$ > "$WATCH_PIDFILE"
    trap 'rm -f "$WATCH_PIDFILE"' EXIT
    log "Вотчдог запущен (pid $$): слежу за IP-лимитами opencode/zen/go в $OPENCODE_LOG"
    tail -n0 -F "$OPENCODE_LOG" 2>/dev/null | while IFS= read -r line; do
        is_rotatable_limit "$line" || continue
        local now last hour ch cc
        now=$(date +%s); last=$(cat "$LAST_ROTATE_FILE" 2>/dev/null || echo 0)
        if (( now - last < ROTATE_COOLDOWN )); then
            warn "Вотчдог: лимит в cooldown (${ROTATE_COOLDOWN}c), пропускаю"
            continue
        fi
        hour=$(date +%Y%m%d%H)
        if [[ -f "$ROTATE_HOUR_FILE" ]]; then
            read -r ch cc < "$ROTATE_HOUR_FILE"
        else
            ch=""; cc=0
        fi
        if [[ "$ch" == "$hour" ]] && (( cc >= ROTATE_MAX_PER_HOUR )); then
            warn "Вотчдог: превышен лимит ротаций (${ROTATE_MAX_PER_HOUR}/час), пропускаю"
            continue
        fi
        log "Вотчдог: пойман IP-лимит: $(printf '%s' "$line" | cut -c1-150)"
        if bash "$0" --rotate "$line"; then
            echo "$(date +%s)" > "$LAST_ROTATE_FILE"
            if [[ "$ch" == "$hour" ]]; then
                echo "$hour $((cc+1))" > "$ROTATE_HOUR_FILE"
            else
                echo "$hour 1" > "$ROTATE_HOUR_FILE"
            fi
        fi
    done
}

# Разбор --subs <http(s)-url|путь-к-файлу>: файл — готовый txt с vless://
# ключами, URL — подписка для скачивания. Действует разово (не сохраняется).
parse_subs_flag() {
    local next=0 a
    for a in "$@"; do
        if (( next )); then
            next=0
            if [[ -f "$a" ]]; then
                export OCVPN_SUBS_FILE="$a"
            elif [[ "$a" =~ ^https?:// ]]; then
                export OCVPN_SUBS_URL="$a" OCVPN_SUBS_FROM_FLAG=1
            else
                err "--subs: не файл и не http(s)-URL: $a"
                exit 2
            fi
        elif [[ "$a" == "--subs" ]]; then
            next=1
        fi
    done
    if (( next )); then
        err "--subs: нет значения (нужен URL или путь к файлу)"
        exit 2
    fi
}

# === Main ===
print_help() {
    cat <<HELP_EOF
ocvpn $OCVPN_VERSION — прозрачная маршрутизация эндпоинтов opencode через VLESS-VPN.

Использование:
  ocvpn                  запустить в foreground (терминал занят, Ctrl-C = стоп + cleanup)
  ocvpn --daemon         запустить в фоне (лог: $OCVPN_LOG), терминал свободен
  ocvpn --daemon --watch фон + вотчдог лимитов (сам ловит лимиты и ротирует IP)
  ocvpn --watch          вотчдог лимитов в foreground (ловит лимиты в логе opencode)
  ocvpn --new-ip         сменить IP сейчас (то же, что --rotate): другой exit IP
  ocvpn --restart        перезапустить в фоне: новый ключ + (обычно) новый IP
  ocvpn --rotate [why]   то же, что --new-ip (алиас)

  --subs URL|ФАЙЛ       разовый источник ключей для запуска/рестарта
                        (URL подписки или готовый txt с vless://; можно в любом
                        месте строки: ocvpn --subs https://… --restart)

  Источник ключей (приоритет): OCVPN_SUBS_URL (env) > ~/.ocvpn-subs-url
  (файл) > /etc/ocvpn/subs-url (системный — для root/daemon/GUI) > публичный fallback.

  При подключении автоматически проверяется доступность моделей opencode
  из текущего региона (geo-block). Если модели недоступны — exit IP
  попадает в карантин на 12 ч, подключение отменяется, пробуется следующий.

  ocvpn --cleanup        снять маршрутизацию, убрать IPv4-записи из /etc/hosts
  ocvpn --status         показать состояние (xray, порты, маршруты, exit IP, карантин)
  ocvpn --version        версия
  ocvpn --help           эта справка

Только трафик к эндпоинтам opencode и провайдеров на порту 443 идёт через VPN.
Вотчдог триггерит только IP-лимиты opencode/zen/go; ollama/баланс/биллинг/геоблок игнорятся.
HELP_EOF
}

do_status() {
    local rc=0
    echo "ocvpn $OCVPN_VERSION ($OCVPN_OS)"
    if pgrep -f "xray run" >/dev/null 2>&1; then
        echo "xray: запущен ($(pgrep -cf "xray run") проц.)"
    else
        echo "xray: НЕ запущен"
        rc=1
    fi
    local p
    for p in "$SOCKS_PORT" "$HTTP_PORT" "$REDIRECT_PORT"; do
        if (command -v ss &>/dev/null && ss -tln 2>/dev/null | grep -q ":$p ") \
            || (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null; then
            exec 3>&- 2>/dev/null || true
            echo "порт $p: слушается"
        else
            echo "порт $p: закрыт"
            rc=1
        fi
    done
    if is_macos; then
        if pfctl -s rules 2>/dev/null | grep -q ocvpn_targets \
            || { [[ -f "$PF_ANCHOR_FILE" ]] && grep -q ocvpn_targets "$PF_ANCHOR_FILE"; }; then
            echo "маршруты (pf $PF_ANCHOR): есть"
        else
            echo "маршруты (pf $PF_ANCHOR): нет"
            rc=1
        fi
    else
        if iptables -t nat -S OUTPUT 2>/dev/null | grep -q -- "-j $IPTABLES_CHAIN"; then
            echo "маршруты (iptables $IPTABLES_CHAIN): есть"
        else
            echo "маршруты (iptables $IPTABLES_CHAIN): нет"
            rc=1
        fi
    fi
    if grep -q -- "$HOSTS_MARK" /etc/hosts 2>/dev/null; then
        echo "/etc/hosts: IPv4-записи есть ($(grep -c -- "$HOSTS_MARK" /etc/hosts))"
    else
        echo "/etc/hosts: IPv4-записей нет"
        rc=1
    fi
    # Активный ключ / exit IP / карантин / вотчдог (всё read-only)
    if [[ -f "$ACTIVE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$ACTIVE_FILE" 2>/dev/null || true
        echo "ключ: ${ACTIVE_LABEL:-?} (${ACTIVE_HOST:-?}:${ACTIVE_PORT:-?})"
    else
        echo "ключ: нет активного (active.env)"
    fi
    local eip
    eip="$(exit_ip_fast)"
    if [[ -n "$eip" ]]; then
        echo "exit IP: $eip"
    else
        echo "exit IP: недоступен"
        rc=1
    fi
    echo "карантин: $(quarantine_count) записей"
    if [[ -f "$WATCH_PIDFILE" ]] && kill -0 "$(cat "$WATCH_PIDFILE" 2>/dev/null)" 2>/dev/null; then
        echo "вотчдог: запущен (pid $(cat "$WATCH_PIDFILE"))"
    else
        echo "вотчдог: выключен"
    fi
    return $rc
}

# Быстрый опрос exit IP для --status (один URL, короткий таймаут)
exit_ip_fast() {
    local ip
    ip=$(curl -fsSL --max-time 3 --proxy "socks5h://127.0.0.1:$SOCKS_PORT" \
        https://api.ipify.org 2>/dev/null || true)
    ip="$(printf '%s' "${ip:-}" | tr -d '[:space:]')"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "$ip"
    fi
    return 0
}

main() {
    # --subs <url|файл> в любом месте командной строки: разовый источник ключей
    # для этого запуска/рестарта (фоновым потомкам достаётся через export).
    parse_subs_flag "$@"
    if [[ -n "${OCVPN_SUBS_URL:-}" ]]; then
        SUBS_URL="$OCVPN_SUBS_URL"
    fi
    case "${1:-}" in
        --help|-h)
            no_cleanup
            print_help
            exit 0
            ;;
        --version|-V)
            no_cleanup
            echo "ocvpn $OCVPN_VERSION"
            exit 0
            ;;
        --status)
            no_cleanup
            do_status
            exit $?
            ;;
        --rotate|--new-ip)
            do_rotate "${2:-ручная ротация}"
            exit $?
            ;;
        --restart)
            do_restart
            exit $?
            ;;
        --watch)
            do_watch
            exit $?
            ;;
        --daemon|-d)
            # Фон: двойной отрыв от терминала (setsid + nohup), лог в файл.
            # Использование: ocvpn --daemon [те же аргументы, что и у обычного запуска]
            no_cleanup  # родитель никого не владеет — маршруты ставит потомок
            shift
            mkdir -p "$(dirname "$OCVPN_LOG")"
            # shellcheck disable=SC2094
            setsid nohup "$0" "$@" </dev/null >>"$OCVPN_LOG" 2>&1 &
            log "ocvpn $OCVPN_VERSION запущен в фоне (pid $!, лог $OCVPN_LOG)"
            exit 0
            ;;
        --cleanup)
            no_cleanup  # чистим явно ниже, EXIT-trap не нужен
            mkdir -p "$TMPDIR_BASE"
            cleanup_routes
            rm -f "$ACTIVE_FILE" "$WATCH_PIDFILE" 2>/dev/null || true
            log "Маршрутизация opencode-VPN отключена. Хост как был."
            exit 0
            ;;
    esac

    # Check dependencies (набор зависит от ОС)
    if is_macos; then
        for cmd in curl python3 unzip pfctl dig; do
            command -v "$cmd" &>/dev/null || { err "Нужен $cmd"; exit 1; }
        done
    else
        for cmd in curl python3 unzip iptables; do
            command -v "$cmd" &>/dev/null || { err "Нужен $cmd (apt install iptables)"; exit 1; }
        done
    fi

    if [[ "$SUBS_URL" == "$SUBS_FALLBACK_URL" ]]; then
        warn "Подписка не задана — используется публичный fallback-источник (чужой). Своя: ~/.ocvpn-subs-url или системная /etc/ocvpn/subs-url"
    fi
    if [[ "${OCVPN_SUBS_FROM_FLAG:-}" == 1 ]]; then
        log "Подписка из --subs (разово; постоянно: ~/.ocvpn-subs-url или /etc/ocvpn/subs-url)"
    fi

    OCVPN_OWNER=1  # этот процесс владеет xray+маршрутами — EXIT-trap активен
    mkdir -p "$TMPDIR_BASE"
    TMPDIR=$(mktemp -d "$TMPDIR_BASE/XXXXXX")

    find_xray

    fetch_subscription || exit 1

    if ! pick_working_key ""; then
        err "Все кандидаты не сработали. Запусти ещё раз — будут другие случайные."
        exit 1
    fi
    activate_current
    # Держим xray: USR1-ротация уже armed (trap rotate_now), дальше supervise.
    # На выходе cleanup снимет маршруты, т.к. xray уже будет мёртв
    # и REDIRECT-правила стали бы чёрной дырой.
    supervise
}

main "$@"
