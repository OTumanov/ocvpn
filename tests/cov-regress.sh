#!/usr/bin/env bash
# Регресс-тесты на исправленные баги (найдены покрытийными тестами).
. "$(dirname "$0")/lib.sh"

mk() { mktemp -d "$WORK/cfg.XXXXXX"; }

# --- Баг 1: vless reality + ws терял wsSettings ---
d="$(mk)"
vless_to_xray 'vless://u@ex.com:443?security=reality&sni=s.ex&pbk=P&sid=S&type=ws&path=%2Fwp&host=wh.ex#W' "$d" >/dev/null 2>&1
check "vless reality+ws network" "ws" "$(jget "$d/config.json" "d['outbounds'][0]['streamSettings']['network']")"
check "vless reality+ws path" "/wp" "$(jget "$d/config.json" "d['outbounds'][0]['streamSettings']['wsSettings']['path']")"

# --- Баг 4: Host в ws берётся из host=, а не из sni= ---
d="$(mk)"
vless_to_xray 'vless://u@ex.com:443?security=tls&sni=sni.ex&type=ws&path=%2Fw&host=host.ex#V' "$d" >/dev/null 2>&1
check "vless ws Host=host" "host.ex" "$(jget "$d/config.json" "d['outbounds'][0]['streamSettings']['wsSettings']['headers']['Host']")"
check "vless ws serverName=sni" "sni.ex" "$(jget "$d/config.json" "d['outbounds'][0]['streamSettings']['tlsSettings']['serverName']")"

# --- Баг 2: trojan не декодировал alpn ---
d="$(mk)"
trojan_to_xray 'trojan://p@ex.com:443?security=tls&sni=s.ex&type=tcp&alpn=h2%2Chttp%2F1.1#T' "$d" >/dev/null 2>&1
check "trojan alpn decoded" "['h2', 'http/1.1']" "$(jget "$d/config.json" "d['outbounds'][0]['streamSettings']['tlsSettings']['alpn']")"

# --- Баг 3: url_host_port без userinfo ---
check "hp http no-auth" "h 8080" "$(url_host_port 'http://h:8080')"
check "hp socks no-auth" "h 1080" "$(url_host_port 'socks5://h:1080')"
check "hp https no-auth" "h 8443" "$(url_host_port 'https://h:8443')"

# --- Баг: quarantine_count на пустом карантине давал "0\n0" ---
rm -f "$QUARANTINE_FILE"
check "quarantine_count пусто=0" "0" "$(quarantine_count)"

# --- Баг: hosts_setup оставлял устаревшие записи, если DNS не отрезолвился ---
printf '1.1.1.1 old.example # opencode-vpn\n' > "$HOSTS_FILE"
resolve_ipv4() { :; }
OPENCODE_DOMAINS=("noresolve.example")
hosts_setup >/dev/null 2>&1
check "hosts_setup убрал stale" "0" "$(grep -c 'opencode-vpn' "$HOSTS_FILE" || true)"

# --- add_host: строгая валидация ---
for bad in "a..b" "a-.b.com" "-a.com" ".com" "example." "bad_host.com" ""; do
    add_host "$bad" >/dev/null 2>&1
    check "add_host reject [$bad]" "2" "$?"
done
add_host "ok.example.com" >/dev/null 2>&1
check "add_host accept ok.example.com" "0" "$?"
check "add_host без дублей в массиве" "1" "$(printf '%s\n' "${OPENCODE_DOMAINS[@]}" | grep -cx 'ok.example.com')"
rm_host "ok.example.com" >/dev/null 2>&1

# --- rm_host отсутствующего домена не врёт про успех ---
printf 'present.com\n' > "$USER_HOSTS_FILE"
rm_host "absent.com" >/dev/null 2>&1
check "rm_host отсутствующего -> 1" "1" "$?"

# --- reset_opencode_conns: root + override IP ---
check "reset_opencode_conns rc" "0" "$( OCVPN_RESET_IPS="1.2.3.4 5.6.7.8" reset_opencode_conns >/dev/null 2>&1; echo $? )"
# не-root -> подсказка, rc 0
check "reset_opencode_conns не-root rc" "0" "$( id() { echo 1000; }; OCVPN_RESET_IPS="1.2.3.4" reset_opencode_conns >/dev/null 2>&1; echo $? )"
# macOS-ветка
check "reset_opencode_conns mac rc" "0" "$( OCVPN_OS=Darwin; OCVPN_RESET_IPS="1.2.3.4" reset_opencode_conns >/dev/null 2>&1; echo $? )"
OCVPN_OS="Linux"

finish
