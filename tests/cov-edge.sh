#!/usr/bin/env bash
# Остаточные (edge/error) ветки ocvpn.sh, не покрытые cov-converters.sh и
# cov-subs-routes.sh. Хост не трогаем: изоляция и моки — из tests/lib.sh.
. "$(dirname "$0")/lib.sh"

# --- сохранённые оригиналы функций, которые локально мокаем ---
SAVE_RESOLVE_IPV4="$(declare -f resolve_ipv4)"
SAVE_RESOLVE_DOMAINS="$(declare -f resolve_domains)"
SAVE_HOSTS_SETUP="$(declare -f hosts_setup)"
SAVE_HOSTS_CLEANUP="$(declare -f hosts_cleanup)"
SAVE_FETCH_ONE="$(declare -f _fetch_one_source)"
SAVE_CURL="$(declare -f curl)"
SAVE_IPTABLES="$(declare -f iptables)"

CFG="$WORK/cfg"; mkdir -p "$CFG"
b64() { python3 -c "import base64,sys;print(base64.b64encode(sys.stdin.buffer.read()).decode())"; }
jp() { jget "$CFG/$1/config.json" "$2"; }
present() { jget "$CFG/$1/config.json" "'yes' if '$3' in $2 else 'no'"; }
valid_json() { python3 -m json.tool "$CFG/$1/config.json" >/dev/null 2>&1; }
mk() { mkdir -p "$CFG/$1" && printf '%s' "$CFG/$1"; }

echo "=== [1] vmess_to_xray: kcp, нет id, tls без sni (fallback на host) ==="
VM_KCP=$(printf '{"v":"2","add":"vm.ex","port":"443","id":"uuid-k","net":"kcp","path":"/k"}' | b64)
vmess_to_xray "vmess://$VM_KCP#K" "$(mk vmess_kcp)"
check_true "vmess kcp JSON валиден" valid_json vmess_kcp
check "vmess kcp network не ремапится" "kcp" "$(jp vmess_kcp "d['outbounds'][0]['streamSettings']['network']")"
VM_NOID=$(printf '{"v":"2","add":"vm.ex","port":"443"}' | b64)
vmess_to_xray "vmess://$VM_NOID#N" "$(mk vmess_noid)" >/dev/null 2>&1
check "vmess нет id -> rc1" "1" "$?"
check "vmess нет id -> нет config" "no" "$([[ -f "$CFG/vmess_noid/config.json" ]] && echo yes || echo no)"
VM_TLSHOST=$(printf '{"v":"2","add":"vm.ex","port":"443","id":"uuid-h","net":"ws","host":"vh.ex","path":"/p","tls":"tls"}' | b64)
vmess_to_xray "vmess://$VM_TLSHOST#H" "$(mk vmess_tlshost)"
check "vmess tls sni fallback serverName" "vh.ex" "$(jp vmess_tlshost "d['outbounds'][0]['streamSettings']['tlsSettings']['serverName']")"
check "vmess tls sni fallback ws Host" "vh.ex" "$(jp vmess_tlshost "d['outbounds'][0]['streamSettings']['wsSettings']['headers']['Host']")"
check "vmess tls sni fallback ws path" "/p" "$(jp vmess_tlshost "d['outbounds'][0]['streamSettings']['wsSettings']['path']")"

echo "=== [2] vless_to_xray: tls без alpn, reality+xhttp+mode ==="
VL_TNA='vless://u@ex.com:8443?security=tls&sni=s.ex&type=tcp#T'
vless_to_xray "$VL_TNA" "$(mk vless_tls_noalpn)"
check_true "vless tls без alpn JSON валиден" valid_json vless_tls_noalpn
check "vless tls без alpn нет ключа alpn" "no" "$(present vless_tls_noalpn "d['outbounds'][0]['streamSettings']['tlsSettings']" alpn)"
check "vless tls без alpn serverName" "s.ex" "$(jp vless_tls_noalpn "d['outbounds'][0]['streamSettings']['tlsSettings']['serverName']")"
VL_RX='vless://u@ex.com:443?security=reality&sni=s.ex&pbk=P&sid=S&type=xhttp&path=%2Fxr&host=xh.ex&mode=packet-up#X'
vless_to_xray "$VL_RX" "$(mk vless_reality_xhttp)"
check_true "vless reality xhttp JSON валиден" valid_json vless_reality_xhttp
check "vless reality xhttp network" "xhttp" "$(jp vless_reality_xhttp "d['outbounds'][0]['streamSettings']['network']")"
check "vless reality xhttp path" "/xr" "$(jp vless_reality_xhttp "d['outbounds'][0]['streamSettings']['xhttpSettings']['path']")"
check "vless reality xhttp mode" "packet-up" "$(jp vless_reality_xhttp "d['outbounds'][0]['streamSettings']['xhttpSettings']['mode']")"
check "vless reality xhttp publicKey" "P" "$(jp vless_reality_xhttp "d['outbounds'][0]['streamSettings']['realitySettings']['publicKey']")"

echo "=== [3] trojan_to_xray: ws без host, grpc serviceName, raw->tcp ==="
TR_WS_NH='trojan://p@ex.com:443?security=none&type=ws&path=%2Ft#T'
trojan_to_xray "$TR_WS_NH" "$(mk trojan_ws_nohost)"
check_true "trojan ws без host JSON валиден" valid_json trojan_ws_nohost
check "trojan ws без host path" "/t" "$(jp trojan_ws_nohost "d['outbounds'][0]['streamSettings']['wsSettings']['path']")"
check "trojan ws без host Host=host" "ex.com" "$(jp trojan_ws_nohost "d['outbounds'][0]['streamSettings']['wsSettings']['headers']['Host']")"
TR_GRPC='trojan://p@ex.com:443?security=none&type=grpc&serviceName=tsvc#T'
trojan_to_xray "$TR_GRPC" "$(mk trojan_grpc)"
check "trojan grpc serviceName" "tsvc" "$(jp trojan_grpc "d['outbounds'][0]['streamSettings']['grpcSettings']['serviceName']")"
TR_RAW='trojan://p@ex.com:443?security=tls&sni=s.ex&type=raw#T'
trojan_to_xray "$TR_RAW" "$(mk trojan_raw)"
check "trojan raw->tcp" "tcp" "$(jp trojan_raw "d['outbounds'][0]['streamSettings']['network']")"
check "trojan raw sni" "s.ex" "$(jp trojan_raw "d['outbounds'][0]['streamSettings']['tlsSettings']['serverName']")"

echo "=== [4] ss_to_xray: срез ?query, пустой password -> rc1 ==="
SS_Q="ss://$(printf '%s' 'aes-256-gcm:pw' | base64)@ss.ex:8388?plugin=obfs-local%3Bobfs%3Dhttp#Q"
ss_to_xray "$SS_Q" "$(mk ss_query)"
check_true "ss с ?query JSON валиден" valid_json ss_query
check "ss с ?query method" "aes-256-gcm" "$(jp ss_query "d['outbounds'][0]['settings']['servers'][0]['method']")"
check "ss с ?query port" "8388" "$(jp ss_query "d['outbounds'][0]['settings']['servers'][0]['port']")"
ss_to_xray 'ss://aes-256-gcm:@ss.ex:8388#E' "$(mk ss_emptypass)" >/dev/null 2>&1
check "ss пустой password -> rc1" "1" "$?"
check "ss пустой password -> нет config" "no" "$([[ -f "$CFG/ss_emptypass/config.json" ]] && echo yes || echo no)"

echo "=== [5] http/socks: userinfo без ':' (user only), http с путём ==="
http_to_xray 'http://onlyuser@hp.ex:8080#H' "$(mk http_useronly)"
check "http user only user" "onlyuser" "$(jp http_useronly "d['outbounds'][0]['settings']['servers'][0]['users'][0]['user']")"
check "http user only pass пуст" "" "$(jp http_useronly "d['outbounds'][0]['settings']['servers'][0]['users'][0]['pass']")"
http_to_xray 'http://hp.ex:8080/some/path#H' "$(mk http_path)"
check "http с путём address" "hp.ex" "$(jp http_path "d['outbounds'][0]['settings']['servers'][0]['address']")"
check "http с путём port" "8080" "$(jp http_path "d['outbounds'][0]['settings']['servers'][0]['port']")"
socks_to_xray 'socks5://onlyuser@sp.ex:1080#S' "$(mk socks_useronly)"
check "socks user only user" "onlyuser" "$(jp socks_useronly "d['outbounds'][0]['settings']['servers'][0]['users'][0]['user']")"
check "socks user only pass пуст" "" "$(jp socks_useronly "d['outbounds'][0]['settings']['servers'][0]['users'][0]['pass']")"

echo "=== [6] download_subscription: только-комментарии/пустой home -> sys/fallback ==="
unset OCVPN_SUBS_URL OCVPN_SUBS_FILE
SRC_LOG="$WORK/src_log"
_fetch_one_source() { printf 'SRC:%s\n' "$1" >> "$SRC_LOG"; printf 'vless://mock@h:443?type=tcp#M\n'; }
printf '# just a comment\n\n' > "$HOME/.ocvpn-subs-url"
: > "$SRC_LOG"; download_subscription "$WORK/d_comment" >/dev/null 2>&1
check "home только комментарии -> fallback" "SRC:$SUBS_FALLBACK_URL" "$(cat "$SRC_LOG")"
: > "$HOME/.ocvpn-subs-url"
printf 'https://sys2/sub\n' > "$SYS_SUBS_FILE"
: > "$SRC_LOG"; download_subscription "$WORK/d_emptyhome" >/dev/null 2>&1
check "home пуст -> sys" "SRC:https://sys2/sub" "$(cat "$SRC_LOG")"
printf '# c\n\n' > "$SYS_SUBS_FILE"
: > "$SRC_LOG"; download_subscription "$WORK/d_commentsys" >/dev/null 2>&1
check "sys только комментарии -> fallback" "SRC:$SUBS_FALLBACK_URL" "$(cat "$SRC_LOG")"
rm -f "$HOME/.ocvpn-subs-url" "$SYS_SUBS_FILE"
eval "$SAVE_FETCH_ONE"

echo "=== [7] _fetch_one_source: пустой download и http-URL без порта ==="
CURL_CALLS="$WORK/curl_edge"
curl() {
    printf '%s\n' "$*" >> "$CURL_CALLS"
    local o=""
    while [[ $# -gt 0 ]]; do case "$1" in -o) o="$2"; shift 2 ;; *) shift ;; esac; done
    [[ -n "$o" ]] && : > "$o"
    return 0
}
: > "$CURL_CALLS"
out="$(_fetch_one_source https://ex/empty)"; rc=$?
check "fetch url empty-body rc" "0" "$rc"
check "fetch url empty-body out" "" "$out"
curl() { return 1; }
out="$(_fetch_one_source 'http://host/no_port_path' 2>/dev/null)"; rc=$?
check "fetch http URL без порта (curl-fail) rc" "1" "$rc"
check "fetch http URL без порта out" "" "$out"
eval "$SAVE_CURL"

echo "=== [8] setup_routes_linux без XRAY_PID / cleanup без цепи ==="
IPT_CALLS="$WORK/ipt_edge"; : > "$IPT_CALLS"
iptables() {
    printf 'ipt %s\n' "$*" >> "$IPT_CALLS"
    [[ "$*" == *"-S OUTPUT"* ]] && printf -- '-A OUTPUT -p tcp -j %s\n' "$IPTABLES_CHAIN"
    return 0
}
hosts_setup() { printf 'hosts_setup\n' >> "$IPT_CALLS"; }
hosts_cleanup() { printf 'hosts_cleanup\n' >> "$IPT_CALLS"; }
resolve_domains() { printf '1.1.1.1\n'; }
XRAY_PID=""
( setup_routes_linux >/dev/null 2>&1 ); rc=$?
check "setup без XRAY_PID rc" "0" "$rc"
check "setup без XRAY_PID нет pid-owner" "0" "$(grep -c -- '--pid-owner' "$IPT_CALLS")"
XRAY_PID="invalid-pid"
: > "$IPT_CALLS"
( setup_routes_linux >/dev/null 2>&1 ); rc=$?
check "setup недоступный pid rc" "0" "$rc"
check "setup недоступный pid нет pid-owner" "0" "$(grep -c -- '--pid-owner' "$IPT_CALLS")"
unset XRAY_PID
: > "$IPT_CALLS"
iptables() { printf 'ipt %s\n' "$*" >> "$IPT_CALLS"; return 1; }
cleanup_routes_linux >/dev/null 2>&1; rc=$?
check "cleanup без цепи rc" "0" "$rc"
check "cleanup без цепи нет -F" "0" "$(grep -c -- '-F OPENCODE_VPN' "$IPT_CALLS")"
check "cleanup без цепи нет -X" "0" "$(grep -c -- '-X OPENCODE_VPN' "$IPT_CALLS")"
check "cleanup без цепи hosts_cleanup" "1" "$(grep -c '^hosts_cleanup$' "$IPT_CALLS")"
eval "$SAVE_IPTABLES"; eval "$SAVE_HOSTS_SETUP"; eval "$SAVE_HOSTS_CLEANUP"; eval "$SAVE_RESOLVE_DOMAINS"

echo "=== [9] hosts_setup: устаревший маркер удаляется, если IP не резолвятся ==="
printf '# test hosts\n1.1.1.1 old.example %s\n' "$HOSTS_MARK" > "$HOSTS_FILE"
resolve_ipv4() { :; }
OPENCODE_DOMAINS=("nope.example")
hosts_setup >/dev/null 2>&1; rc=$?
check "hosts_setup stale rc" "0" "$rc"
check "hosts_setup stale: маркер удалён" "0" "$(grep -c "$HOSTS_MARK" "$HOSTS_FILE" || true)"
check "hosts_setup stale: запись удалена" "0" "$(grep -c 'old.example' "$HOSTS_FILE" || true)"
eval "$SAVE_RESOLVE_IPV4"
OPENCODE_DOMAINS=("stub.example")

echo "=== [10] url_host_port: битый base64 vmess/ss -> rc1 ==="
check "hp vmess битый base64 -> rc1" "1" "$(url_host_port 'vmess://!!!' >/dev/null 2>&1; echo $?)"
check "hp ss base64 без порта -> rc1" "1" \
    "$(url_host_port "ss://$(printf '%s' 'noporthere' | base64)#x" >/dev/null 2>&1; echo $?)"
check "hp ss sip002 с путём" "h 8388" \
    "$(url_host_port "ss://$(printf '%s' 'aes-256-gcm:p' | base64)@h:8388/some#x")"

echo "=== [11] vless_to_xray: валидация host/port/id ==="
# vless теперь проверяет host/port/id (как vmess/trojan/ss): битый URL → rc1,
# config.json не создаётся (раньше писался невалидный JSON с пустым "port").
vless_to_xray 'vless://u@host#x' "$(mk vless_noport)" >/dev/null 2>&1; rc=$?
check "vless без порта rc=1" "1" "$rc"
check_true "vless без порта config не создан" test ! -f "$CFG/vless_noport/config.json"
vless_to_xray 'vless://u@:443#x' "$(mk vless_emptyhost)" >/dev/null 2>&1; rc=$?
check "vless пустой host rc=1" "1" "$rc"
vless_to_xray 'vless://@h:443#x' "$(mk vless_noid)" >/dev/null 2>&1; rc=$?
check "vless пустой id rc=1" "1" "$rc"

finish
