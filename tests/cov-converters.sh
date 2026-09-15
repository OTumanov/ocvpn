#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"

trap '_cleanup' EXIT

CFG="$WORK/cfg"; mkdir -p "$CFG"

b64() { python3 -c "import base64,sys;print(base64.b64encode(sys.stdin.buffer.read()).decode())"; }
jp() { jget "$CFG/$1/config.json" "$2"; }
present() { jget "$CFG/$1/config.json" "'yes' if '$3' in $2 else 'no'"; }
valid_json() { python3 -m json.tool "$CFG/$1/config.json" >/dev/null 2>&1; }
mk() { mkdir -p "$CFG/$1" && printf '%s' "$CFG/$1"; }

echo "=== [1] ws/grpc/xhttp stream settings ==="
check "ws чужой тип -> пусто" "" "$(ws_stream_settings tcp /p h)"
check "ws чужой тип grpc -> пусто" "" "$(ws_stream_settings grpc /p h)"
check "ws содержит wsSettings" "1" "$(ws_stream_settings ws /p h | grep -c '"wsSettings"')"
check "ws path" "1" "$(ws_stream_settings ws /mypath h | grep -c '"path": "/mypath"')"
check "ws Host header" "1" "$(ws_stream_settings ws /p myhost | grep -c '"Host": "myhost"')"
check "ws пустой хост -> пустой Host" "1" "$(ws_stream_settings ws /p '' | grep -c '"Host": ""')"
check "grpc чужой тип -> пусто" "" "$(grpc_stream_settings ws svc)"
check "grpc содержит grpcSettings" "1" "$(grpc_stream_settings grpc svc1 | grep -c '"grpcSettings"')"
check "grpc serviceName" "1" "$(grpc_stream_settings grpc svc1 | grep -c '"serviceName": "svc1"')"
check "xhttp чужой тип -> пусто" "" "$(xhttp_stream_settings ws /p h auto)"
check "xhttp содержит xhttpSettings" "1" "$(xhttp_stream_settings xhttp /p h auto | grep -c '"xhttpSettings"')"
check "xhttp host строкой" "1" "$(xhttp_stream_settings xhttp /p host1 auto | grep -c '"host": "host1"')"
check "xhttp mode при заданном" "1" "$(xhttp_stream_settings xhttp /p h auto | grep -c '"mode": "auto"')"
check "xhttp mode отсутствует" "0" "$(xhttp_stream_settings xhttp /p h '' | grep -c '"mode"')"

echo "=== [2] vless_to_xray: reality + grpc + flow ==="
VL_R='vless://11111111-1111-1111-1111-111111111111@ex.com:443?security=reality&sni=cdn.ex&fp=firefox&pbk=PUBKEY&sid=abcd&type=grpc&serviceName=grpcsvc&flow=xtls-rprx-vision#Node'
vless_to_xray "$VL_R" "$(mk vless_reality)"
check_true "vless reality JSON валиден" valid_json vless_reality
check "vless protocol" "vless" "$(jp vless_reality "d['outbounds'][0]['protocol']")"
check "vless tag proxy" "proxy" "$(jp vless_reality "d['outbounds'][0]['tag']")"
check "vless address" "ex.com" "$(jp vless_reality "d['outbounds'][0]['settings']['address']")"
check "vless port" "443" "$(jp vless_reality "d['outbounds'][0]['settings']['port']")"
check "vless id" "11111111-1111-1111-1111-111111111111" "$(jp vless_reality "d['outbounds'][0]['settings']['id']")"
check "vless encryption none" "none" "$(jp vless_reality "d['outbounds'][0]['settings']['encryption']")"
check "vless flow" "xtls-rprx-vision" "$(jp vless_reality "d['outbounds'][0]['settings']['flow']")"
check "vless network" "grpc" "$(jp vless_reality "d['outbounds'][0]['streamSettings']['network']")"
check "vless security reality" "reality" "$(jp vless_reality "d['outbounds'][0]['streamSettings']['security']")"
check "vless reality serverName" "cdn.ex" "$(jp vless_reality "d['outbounds'][0]['streamSettings']['realitySettings']['serverName']")"
check "vless reality fingerprint" "firefox" "$(jp vless_reality "d['outbounds'][0]['streamSettings']['realitySettings']['fingerprint']")"
check "vless reality publicKey" "PUBKEY" "$(jp vless_reality "d['outbounds'][0]['streamSettings']['realitySettings']['publicKey']")"
check "vless reality shortId" "abcd" "$(jp vless_reality "d['outbounds'][0]['streamSettings']['realitySettings']['shortId']")"
check "vless grpc serviceName" "grpcsvc" "$(jp vless_reality "d['outbounds'][0]['streamSettings']['grpcSettings']['serviceName']")"
check "vless reality без tlsSettings" "no" "$(present vless_reality "d['outbounds'][0]['streamSettings']" tlsSettings)"

echo "=== [3] vless_to_xray: reality fingerprint по умолчанию ==="
VL_RD='vless://u@ex.com:443?security=reality&sni=s.ex&pbk=P&sid=S&type=tcp#D'
vless_to_xray "$VL_RD" "$(mk vless_reality_def)"
check "vless reality fp default chrome" "chrome" "$(jp vless_reality_def "d['outbounds'][0]['streamSettings']['realitySettings']['fingerprint']")"

echo "=== [4] vless_to_xray: tls + ws + alpn (encoded) ==="
VL_T='vless://u@ex.com:8443?security=tls&sni=s.ex&type=ws&path=%2Fw&alpn=h2%2Chttp%2F1.1#T'
vless_to_xray "$VL_T" "$(mk vless_tls_ws)"
check_true "vless tls ws JSON валиден" valid_json vless_tls_ws
check "vless tls network" "ws" "$(jp vless_tls_ws "d['outbounds'][0]['streamSettings']['network']")"
check "vless tls security" "tls" "$(jp vless_tls_ws "d['outbounds'][0]['streamSettings']['security']")"
check "vless tls serverName" "s.ex" "$(jp vless_tls_ws "d['outbounds'][0]['streamSettings']['tlsSettings']['serverName']")"
check "vless tls allowInsecure" "False" "$(jp vless_tls_ws "d['outbounds'][0]['streamSettings']['tlsSettings']['allowInsecure']")"
check "vless tls alpn" "h2,http/1.1" "$(jp vless_tls_ws "','.join(d['outbounds'][0]['streamSettings']['tlsSettings']['alpn'])")"
check "vless tls ws path" "/w" "$(jp vless_tls_ws "d['outbounds'][0]['streamSettings']['wsSettings']['path']")"
check "vless tls ws Host=sni" "s.ex" "$(jp vless_tls_ws "d['outbounds'][0]['streamSettings']['wsSettings']['headers']['Host']")"
check "vless tls без realitySettings" "no" "$(present vless_tls_ws "d['outbounds'][0]['streamSettings']" realitySettings)"

echo "=== [5] vless_to_xray: sni fallback на host ==="
VL_H='vless://u@ex.com:8443?security=tls&type=ws&path=%2Fw&host=fallback.ex#H'
vless_to_xray "$VL_H" "$(mk vless_host)"
check "vless sni fallback serverName" "fallback.ex" "$(jp vless_host "d['outbounds'][0]['streamSettings']['tlsSettings']['serverName']")"
check "vless sni fallback ws Host" "fallback.ex" "$(jp vless_host "d['outbounds'][0]['streamSettings']['wsSettings']['headers']['Host']")"

echo "=== [6] vless_to_xray: security=none, raw->tcp, без flow ==="
VL_N='vless://u@ex.com:8443?security=none&type=ws&path=%2Fw&host=hp.ex#N'
vless_to_xray "$VL_N" "$(mk vless_none)"
check_true "vless none JSON валиден" valid_json vless_none
check "vless none network" "ws" "$(jp vless_none "d['outbounds'][0]['streamSettings']['network']")"
check "vless none без security" "no" "$(present vless_none "d['outbounds'][0]['streamSettings']" security)"
check "vless none без flow" "no" "$(present vless_none "d['outbounds'][0]['settings']" flow)"
check "vless none без tlsSettings" "no" "$(present vless_none "d['outbounds'][0]['streamSettings']" tlsSettings)"
VL_RAW='vless://u@ex.com:443?security=none&type=raw&sni=s.ex#R'
vless_to_xray "$VL_RAW" "$(mk vless_raw)"
check "vless raw->tcp" "tcp" "$(jp vless_raw "d['outbounds'][0]['streamSettings']['network']")"

echo "=== [7] vless_to_xray: xhttp mode и reality+ws ==="
VL_X='vless://u@ex.com:443?security=reality&pbk=P&type=xhttp&path=%2Fx&host=xh.ex&mode=auto#X'
vless_to_xray "$VL_X" "$(mk vless_xhttp)"
check "vless xhttp network" "xhttp" "$(jp vless_xhttp "d['outbounds'][0]['streamSettings']['network']")"
check "vless xhttp path" "/x" "$(jp vless_xhttp "d['outbounds'][0]['streamSettings']['xhttpSettings']['path']")"
check "vless xhttp host" "xh.ex" "$(jp vless_xhttp "d['outbounds'][0]['streamSettings']['xhttpSettings']['host']")"
check "vless xhttp mode" "auto" "$(jp vless_xhttp "d['outbounds'][0]['streamSettings']['xhttpSettings']['mode']")"
VL_XN='vless://u@ex.com:443?security=none&type=xhttp&path=%2Fx&host=xh.ex#X'
vless_to_xray "$VL_XN" "$(mk vless_xhttp_nomode)"
check "vless xhttp без mode" "no" "$(present vless_xhttp_nomode "d['outbounds'][0]['streamSettings']['xhttpSettings']" mode)"
VL_RWS='vless://u@ex.com:443?security=reality&sni=s.ex&pbk=P&sid=S&type=ws&path=%2Fwp&host=wh.ex#W'
vless_to_xray "$VL_RWS" "$(mk vless_reality_ws)"
check_true "vless reality ws JSON валиден" valid_json vless_reality_ws
check "vless reality ws network" "ws" "$(jp vless_reality_ws "d['outbounds'][0]['streamSettings']['network']")"
check "vless reality ws security" "reality" "$(jp vless_reality_ws "d['outbounds'][0]['streamSettings']['security']")"
check "vless reality ws serverName" "s.ex" "$(jp vless_reality_ws "d['outbounds'][0]['streamSettings']['realitySettings']['serverName']")"
check "vless reality ws без grpcSettings" "no" "$(present vless_reality_ws "d['outbounds'][0]['streamSettings']" grpcSettings)"
check "vless reality ws без xhttpSettings" "no" "$(present vless_reality_ws "d['outbounds'][0]['streamSettings']" xhttpSettings)"

echo "=== [8] vmess_to_xray: ws+tls, grpc, plain, h2, reality ==="
VM_WS=$(printf '{"v":"2","add":"vm.ex","port":"443","id":"uuid-1","aid":"7","scy":"chacha20-poly1305","net":"ws","host":"vh.ex","path":"/vmp","tls":"tls","sni":"vs.ex"}' | b64)
vmess_to_xray "vmess://$VM_WS#N" "$(mk vmess_ws)"
check_true "vmess ws JSON валиден" valid_json vmess_ws
check "vmess protocol" "vmess" "$(jp vmess_ws "d['outbounds'][0]['protocol']")"
check "vmess address" "vm.ex" "$(jp vmess_ws "d['outbounds'][0]['settings']['address']")"
check "vmess port" "443" "$(jp vmess_ws "d['outbounds'][0]['settings']['port']")"
check "vmess id" "uuid-1" "$(jp vmess_ws "d['outbounds'][0]['settings']['id']")"
check "vmess alterId" "7" "$(jp vmess_ws "d['outbounds'][0]['settings']['alterId']")"
check "vmess scy" "chacha20-poly1305" "$(jp vmess_ws "d['outbounds'][0]['settings']['security']")"
check "vmess ws network" "ws" "$(jp vmess_ws "d['outbounds'][0]['streamSettings']['network']")"
check "vmess ws security" "tls" "$(jp vmess_ws "d['outbounds'][0]['streamSettings']['security']")"
check "vmess ws serverName" "vs.ex" "$(jp vmess_ws "d['outbounds'][0]['streamSettings']['tlsSettings']['serverName']")"
check "vmess ws path" "/vmp" "$(jp vmess_ws "d['outbounds'][0]['streamSettings']['wsSettings']['path']")"
check "vmess ws Host" "vh.ex" "$(jp vmess_ws "d['outbounds'][0]['streamSettings']['wsSettings']['headers']['Host']")"
VM_GRPC=$(printf '{"v":"2","add":"vm.ex","port":"8443","id":"uuid-2","net":"grpc","path":"svcname"}' | b64)
vmess_to_xray "vmess://$VM_GRPC#N" "$(mk vmess_grpc)"
check "vmess grpc network" "grpc" "$(jp vmess_grpc "d['outbounds'][0]['streamSettings']['network']")"
check "vmess grpc serviceName" "svcname" "$(jp vmess_grpc "d['outbounds'][0]['streamSettings']['grpcSettings']['serviceName']")"
check "vmess grpc без tls" "no" "$(present vmess_grpc "d['outbounds'][0]['streamSettings']" tlsSettings)"
VM_PLAIN=$(printf '{"v":"2","add":"vm.ex","port":"80","id":"uuid-3","net":"tcp"}' | b64)
vmess_to_xray "vmess://$VM_PLAIN#N" "$(mk vmess_plain)"
check "vmess plain alterId default 0" "0" "$(jp vmess_plain "d['outbounds'][0]['settings']['alterId']")"
check "vmess plain scy default auto" "auto" "$(jp vmess_plain "d['outbounds'][0]['settings']['security']")"
check "vmess plain network tcp" "tcp" "$(jp vmess_plain "d['outbounds'][0]['streamSettings']['network']")"
check "vmess plain без security" "no" "$(present vmess_plain "d['outbounds'][0]['streamSettings']" security)"
VM_H2=$(printf '{"v":"2","add":"vm.ex","port":"443","id":"uuid-5","net":"h2","path":"/h2"}' | b64)
vmess_to_xray "vmess://$VM_H2#N" "$(mk vmess_h2)"
check "vmess h2->tcp" "tcp" "$(jp vmess_h2 "d['outbounds'][0]['streamSettings']['network']")"
VM_REAL=$(printf '{"v":"2","add":"vm.ex","port":"443","id":"uuid-4","net":"tcp","tls":"reality","sni":"rs.ex"}' | b64)
vmess_to_xray "vmess://$VM_REAL#N" "$(mk vmess_reality)"
check "vmess reality->tls" "tls" "$(jp vmess_reality "d['outbounds'][0]['streamSettings']['security']")"
check "vmess reality serverName" "rs.ex" "$(jp vmess_reality "d['outbounds'][0]['streamSettings']['tlsSettings']['serverName']")"
VM_NOHOST=$(printf '{"v":"2","port":"80","id":"uuid"}' | b64)
vmess_to_xray "vmess://$VM_NOHOST#N" "$(mk vmess_nohost)" >/dev/null 2>&1
check "vmess нет host -> rc1" "1" "$?"
check "vmess нет host -> нет config" "no" "$([[ -f "$CFG/vmess_nohost/config.json" ]] && echo yes || echo no)"
vmess_to_xray 'vmess://!!!notbase64!!!#x' "$(mk vmess_bad)" >/dev/null 2>&1
check "vmess битый base64 -> rc1" "1" "$?"
check "vmess битый -> нет config" "no" "$([[ -f "$CFG/vmess_bad/config.json" ]] && echo yes || echo no)"

echo "=== [9] trojan_to_xray ==="
TR_D='trojan://p%40ss@ex.com:443?type=tcp#T'
trojan_to_xray "$TR_D" "$(mk trojan_default)"
check_true "trojan default JSON валиден" valid_json trojan_default
check "trojan protocol" "trojan" "$(jp trojan_default "d['outbounds'][0]['protocol']")"
check "trojan address" "ex.com" "$(jp trojan_default "d['outbounds'][0]['settings']['servers'][0]['address']")"
check "trojan port" "443" "$(jp trojan_default "d['outbounds'][0]['settings']['servers'][0]['port']")"
check "trojan password decoded" "p@ss" "$(jp trojan_default "d['outbounds'][0]['settings']['servers'][0]['password']")"
check "trojan default security tls" "tls" "$(jp trojan_default "d['outbounds'][0]['streamSettings']['security']")"
check "trojan default serverName host" "ex.com" "$(jp trojan_default "d['outbounds'][0]['streamSettings']['tlsSettings']['serverName']")"
TR_N='trojan://p@ex.com:443?security=none&type=ws&path=%2Ft&host=hp.ex#T'
trojan_to_xray "$TR_N" "$(mk trojan_none)"
check "trojan none network" "ws" "$(jp trojan_none "d['outbounds'][0]['streamSettings']['network']")"
check "trojan none ws path" "/t" "$(jp trojan_none "d['outbounds'][0]['streamSettings']['wsSettings']['path']")"
check "trojan none ws Host" "hp.ex" "$(jp trojan_none "d['outbounds'][0]['streamSettings']['wsSettings']['headers']['Host']")"
check "trojan none без security" "no" "$(present trojan_none "d['outbounds'][0]['streamSettings']" security)"
TR_A='trojan://p@ex.com:443?security=tls&sni=s.ex&type=tcp&alpn=h2,http/1.1#T'
trojan_to_xray "$TR_A" "$(mk trojan_alpn)"
check "trojan alpn" "h2,http/1.1" "$(jp trojan_alpn "','.join(d['outbounds'][0]['streamSettings']['tlsSettings']['alpn'])")"
trojan_to_xray 'trojan://p@h#x' "$(mk trojan_bad)" >/dev/null 2>&1
check "trojan битый URL -> rc1" "1" "$?"
check "trojan битый -> нет config" "no" "$([[ -f "$CFG/trojan_bad/config.json" ]] && echo yes || echo no)"

echo "=== [10] ss_to_xray ==="
SS_SIP="ss://$(printf '%s' 'aes-256-gcm:p@ss' | base64)@ss.ex:8388#S"
ss_to_xray "$SS_SIP" "$(mk ss_sip002)"
check_true "ss sip002 JSON валиден" valid_json ss_sip002
check "ss protocol" "shadowsocks" "$(jp ss_sip002 "d['outbounds'][0]['protocol']")"
check "ss method" "aes-256-gcm" "$(jp ss_sip002 "d['outbounds'][0]['settings']['servers'][0]['method']")"
check "ss password" "p@ss" "$(jp ss_sip002 "d['outbounds'][0]['settings']['servers'][0]['password']")"
check "ss address" "ss.ex" "$(jp ss_sip002 "d['outbounds'][0]['settings']['servers'][0]['address']")"
check "ss port" "8388" "$(jp ss_sip002 "d['outbounds'][0]['settings']['servers'][0]['port']")"
check "ss network tcp" "tcp" "$(jp ss_sip002 "d['outbounds'][0]['streamSettings']['network']")"
SS_PLAIN='ss://aes-256-gcm:secret@ss.ex:8388#P'
ss_to_xray "$SS_PLAIN" "$(mk ss_plain)"
check "ss plain method" "aes-256-gcm" "$(jp ss_plain "d['outbounds'][0]['settings']['servers'][0]['method']")"
check "ss plain password" "secret" "$(jp ss_plain "d['outbounds'][0]['settings']['servers'][0]['password']")"
SS_LEG="ss://$(printf '%s' 'chacha20:leg@ss.ex:8388' | base64)#L"
ss_to_xray "$SS_LEG" "$(mk ss_legacy)"
check "ss legacy method" "chacha20" "$(jp ss_legacy "d['outbounds'][0]['settings']['servers'][0]['method']")"
check "ss legacy password" "leg" "$(jp ss_legacy "d['outbounds'][0]['settings']['servers'][0]['password']")"
check "ss legacy host" "ss.ex" "$(jp ss_legacy "d['outbounds'][0]['settings']['servers'][0]['address']")"
ss_to_xray 'ss://@@#x' "$(mk ss_bad)" >/dev/null 2>&1
check "ss битый -> rc1" "1" "$?"
check "ss битый -> нет config" "no" "$([[ -f "$CFG/ss_bad/config.json" ]] && echo yes || echo no)"

echo "=== [11] http_to_xray ==="
http_to_xray 'http://u%40x:p%3A1@hp.ex:8080#H' "$(mk http_auth)"
check_true "http auth JSON валиден" valid_json http_auth
check "http protocol" "http" "$(jp http_auth "d['outbounds'][0]['protocol']")"
check "http address" "hp.ex" "$(jp http_auth "d['outbounds'][0]['settings']['servers'][0]['address']")"
check "http port" "8080" "$(jp http_auth "d['outbounds'][0]['settings']['servers'][0]['port']")"
check "http user decoded" "u@x" "$(jp http_auth "d['outbounds'][0]['settings']['servers'][0]['users'][0]['user']")"
check "http pass decoded" "p:1" "$(jp http_auth "d['outbounds'][0]['settings']['servers'][0]['users'][0]['pass']")"
check "http network tcp" "tcp" "$(jp http_auth "d['outbounds'][0]['streamSettings']['network']")"
http_to_xray 'http://hp.ex:8080#H' "$(mk http_noauth)"
check "http без auth нет users" "no" "$(present http_noauth "d['outbounds'][0]['settings']['servers'][0]" users)"
https_url='https://hp.ex:8443#H'
http_to_xray "$https_url" "$(mk https_tls)"
check "https security tls" "tls" "$(jp https_tls "d['outbounds'][0]['streamSettings']['security']")"
check "https serverName host" "hp.ex" "$(jp https_tls "d['outbounds'][0]['streamSettings']['tlsSettings']['serverName']")"
http_to_xray 'http://hp.ex/path#H' "$(mk http_noport)" >/dev/null 2>&1
check "http без порта -> rc1" "1" "$?"
check "http без порта -> нет config" "no" "$([[ -f "$CFG/http_noport/config.json" ]] && echo yes || echo no)"

echo "=== [12] socks_to_xray ==="
socks_to_xray 'socks5://u%40x:p%3A1@sp.ex:1080#S' "$(mk socks_auth)"
check_true "socks auth JSON валиден" valid_json socks_auth
check "socks protocol" "socks" "$(jp socks_auth "d['outbounds'][0]['protocol']")"
check "socks address" "sp.ex" "$(jp socks_auth "d['outbounds'][0]['settings']['servers'][0]['address']")"
check "socks port" "1080" "$(jp socks_auth "d['outbounds'][0]['settings']['servers'][0]['port']")"
check "socks user decoded" "u@x" "$(jp socks_auth "d['outbounds'][0]['settings']['servers'][0]['users'][0]['user']")"
check "socks pass decoded" "p:1" "$(jp socks_auth "d['outbounds'][0]['settings']['servers'][0]['users'][0]['pass']")"
socks_to_xray 'socks://sp.ex:1080#S' "$(mk socks_noauth)"
check "socks без auth нет users" "no" "$(present socks_noauth "d['outbounds'][0]['settings']['servers'][0]" users)"
socks_to_xray 'socks5h://sp.ex#S' "$(mk socks_noport)" >/dev/null 2>&1
check "socks без порта -> rc1" "1" "$?"
check "socks без порта -> нет config" "no" "$([[ -f "$CFG/socks_noport/config.json" ]] && echo yes || echo no)"

echo "=== [13] uri_to_xray: диспетчер по схеме ==="
VM_D=$(printf '{"v":"2","add":"d.ex","port":"443","id":"id","net":"tcp"}' | b64)
uri_to_xray 'vless://u@d.ex:443?security=none&type=tcp#V' "$(mk dispatch_vless)"
check "dispatch vless" "vless" "$(jp dispatch_vless "d['outbounds'][0]['protocol']")"
uri_to_xray "vmess://$VM_D#M" "$(mk dispatch_vmess)"
check "dispatch vmess" "vmess" "$(jp dispatch_vmess "d['outbounds'][0]['protocol']")"
uri_to_xray 'trojan://p@d.ex:443#T' "$(mk dispatch_trojan)"
check "dispatch trojan" "trojan" "$(jp dispatch_trojan "d['outbounds'][0]['protocol']")"
uri_to_xray "ss://$(printf '%s' 'aes-256-gcm:p' | base64)@d.ex:8388#S" "$(mk dispatch_ss)"
check "dispatch ss" "shadowsocks" "$(jp dispatch_ss "d['outbounds'][0]['protocol']")"
uri_to_xray 'http://d.ex:8080#H' "$(mk dispatch_http)"
check "dispatch http" "http" "$(jp dispatch_http "d['outbounds'][0]['protocol']")"
uri_to_xray 'https://d.ex:8443#H' "$(mk dispatch_https)"
check "dispatch https" "http" "$(jp dispatch_https "d['outbounds'][0]['protocol']")"
uri_to_xray 'socks5://d.ex:1080#K' "$(mk dispatch_socks)"
check "dispatch socks5" "socks" "$(jp dispatch_socks "d['outbounds'][0]['protocol']")"
uri_to_xray 'ftp://d.ex:21#F' "$(mk dispatch_bad)" >/dev/null 2>&1
check "dispatch неизвестная схема -> rc1" "1" "$?"
check "dispatch неизвестная -> нет config" "no" "$([[ -f "$CFG/dispatch_bad/config.json" ]] && echo yes || echo no)"

echo "=== [14] is_supported_key ==="
for s in vless vmess trojan ss http https socks socks5 socks5h; do
    is_supported_key "$s://u@h:443?type=tcp#x" 2>/dev/null
    check "supported схема $s" "0" "$?"
done
for t in tcp raw ws grpc xhttp; do
    is_supported_key "vless://u@h:443?type=$t#x" 2>/dev/null
    check "supported vless type=$t" "0" "$?"
    is_supported_key "trojan://u@h:443?type=$t#x" 2>/dev/null
    check "supported trojan type=$t" "0" "$?"
done
is_supported_key 'vless://u@h:443#x' 2>/dev/null; check "supported vless default tcp" "0" "$?"
is_supported_key 'vless://u@h:443?type=kcp#x' 2>/dev/null; check "unsupported vless kcp" "1" "$?"
is_supported_key 'trojan://u@h:443?type=quic#x' 2>/dev/null; check "unsupported trojan quic" "1" "$?"
is_supported_key 'vless://u@h:443?type=xhttp&extra=%7B%7D#x' 2>/dev/null; check "unsupported xhttp extra" "1" "$?"
is_supported_key 'socks4://u@h:1080#x' 2>/dev/null; check "unsupported socks4" "1" "$?"
is_supported_key 'hysteria2://u@h:443#x' 2>/dev/null; check "unsupported hysteria2" "1" "$?"
is_supported_key 'garbage' 2>/dev/null; check "unsupported мусор" "1" "$?"
is_supported_key '' 2>/dev/null; check "unsupported пусто" "1" "$?"

echo "=== [15] emit_xray_config: каркас ==="
emit_xray_config '{ "tag": "proxy", "protocol": "vless" }' "$(mk emit)"
check_true "emit JSON валиден" valid_json emit
check "emit loglevel" "warning" "$(jp emit "d['log']['loglevel']")"
check "emit inbound tags" "socks,http,transparent" "$(jp emit "','.join(b['tag'] for b in d['inbounds'])")"
check "emit socks port" "10808" "$(jp emit "d['inbounds'][0]['port']")"
check "emit http port" "10809" "$(jp emit "d['inbounds'][1]['port']")"
check "emit transparent port" "12345" "$(jp emit "d['inbounds'][2]['port']")"
check "emit socks protocol" "socks" "$(jp emit "d['inbounds'][0]['protocol']")"
check "emit socks auth" "noauth" "$(jp emit "d['inbounds'][0]['settings']['auth']")"
check "emit socks udp" "True" "$(jp emit "d['inbounds'][0]['settings']['udp']")"
check "emit socks listen" "127.0.0.1" "$(jp emit "d['inbounds'][0]['listen']")"
check "emit http protocol" "http" "$(jp emit "d['inbounds'][1]['protocol']")"
check "emit transparent protocol" "dokodemo-door" "$(jp emit "d['inbounds'][2]['protocol']")"
check "emit transparent listen" "0.0.0.0" "$(jp emit "d['inbounds'][2]['listen']")"
check "emit transparent followRedirect" "True" "$(jp emit "d['inbounds'][2]['settings']['followRedirect']")"
check "emit transparent sniffing" "True" "$(jp emit "d['inbounds'][2]['sniffing']['enabled']")"
check "emit transparent destOverride" "http,tls" "$(jp emit "','.join(d['inbounds'][2]['sniffing']['destOverride'])")"
check "emit outbounds tags" "proxy,direct" "$(jp emit "','.join(o['tag'] for o in d['outbounds'])")"
check "emit direct protocol" "freedom" "$(jp emit "d['outbounds'][1]['protocol']")"
check "emit proxy protocol" "vless" "$(jp emit "d['outbounds'][0]['protocol']")"
check "emit routing strategy" "AsIs" "$(jp emit "d['routing']['domainStrategy']")"
check "emit routing direct tag" "direct" "$(jp emit "d['routing']['rules'][0]['outboundTag']")"
check "emit routing ip содержит 10/8" "1" "$(jp emit "1 if '10.0.0.0/8' in d['routing']['rules'][0]['ip'] else 0")"
check "emit routing ip содержит 192.168" "1" "$(jp emit "1 if '192.168.0.0/16' in d['routing']['rules'][0]['ip'] else 0")"
check "emit proxy_json встроен" "yes" "$(jp emit "'yes' if d['outbounds'][0]['tag']=='proxy' else 'no'")"

echo "=== [16] emit_xray_config: порты из переменных ==="
S_SOCKS=$SOCKS_PORT; S_HTTP=$HTTP_PORT; S_REDIR=$REDIRECT_PORT
SOCKS_PORT=19080; HTTP_PORT=19081; REDIRECT_PORT=19082
emit_xray_config '{ "tag": "proxy" }' "$(mk emit_ports)"
check "emit socks port из переменной" "19080" "$(jp emit_ports "d['inbounds'][0]['port']")"
check "emit http port из переменной" "19081" "$(jp emit_ports "d['inbounds'][1]['port']")"
check "emit redirect port из переменной" "19082" "$(jp emit_ports "d['inbounds'][2]['port']")"
SOCKS_PORT=$S_SOCKS; HTTP_PORT=$S_HTTP; REDIRECT_PORT=$S_REDIR

echo "=== [17] url_host_port ==="
check "hp vless" "h 443" "$(url_host_port 'vless://u@h:443?x=1#y')"
check "hp trojan" "h 443" "$(url_host_port 'trojan://p@h:443?x=1#y')"
check "hp http auth" "h 8080" "$(url_host_port 'http://u:p@h:8080#x')"
check "hp https auth" "h 8443" "$(url_host_port 'https://u:p@h:8443#x')"
check "hp socks" "h 1080" "$(url_host_port 'socks://u@h:1080#x')"
check "hp socks5" "h 1080" "$(url_host_port 'socks5://u@h:1080#x')"
check "hp socks5h" "h 1080" "$(url_host_port 'socks5h://u@h:1080#x')"
check "hp ss sip002" "h 8388" "$(url_host_port "ss://$(printf '%s' 'aes-256-gcm:p' | base64)@h:8388#x")"
check "hp ss legacy" "h 8388" "$(url_host_port "ss://$(printf '%s' 'aes-256-gcm:p@h:8388' | base64)#x")"
check "hp vmess" "h 443" "$(url_host_port "vmess://$(printf '{"add":"h","port":"443"}' | b64)#x")"
check "hp формат два поля" "2" "$(url_host_port 'vless://u@h:443#y' | wc -w | tr -d ' ')"
check "hp неизвестная схема -> rc1" "1" "$(url_host_port 'ftp://u@h:21#x' >/dev/null 2>&1; echo $?)"
check "hp без порта -> rc1" "1" "$(url_host_port 'vless://u@h#x' >/dev/null 2>&1; echo $?)"

finish
