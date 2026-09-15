#!/usr/bin/env bash
# Дымовой тест харнесса: проверяем, что lib.sh корректно изолирует окружение.
. "$(dirname "$0")/lib.sh"

check "версия читается" "1.5.5" "$OCVPN_VERSION"
check "HOSTS_FILE изолирован" "$WORK/hosts" "$HOSTS_FILE"
check "USER_HOSTS_FILE изолирован" "$WORK/user-hosts" "$USER_HOSTS_FILE"
check "hosts_list содержит openrouter" "1" "$(hosts_list | grep -c '^openrouter.ai$')"
check "hosts_list содержит chatgpt" "1" "$(hosts_list | grep -c '^chatgpt.com$')"
check "iptables заглушен" "0" "$(iptables -t nat -S >/dev/null 2>&1; echo $?)"
check "ранний cleanup не выходит" "0" "$( ( unset TMPDIR XRAY_PID OCVPN_OWNER; cleanup ); echo $? )"

finish
