#!/usr/bin/env bash
# Общий харнесс для покрытийных тестов ocvpn.
# Изолирует окружение и ГАРАНТИРУЕТ, что тесты не трогают хост: iptables,
# pfctl, ss, ip, pkill и хостовые процессы ocvpn/xray недоступны.
#
# Использование в тесте:
#   . "$(dirname "$0")/lib.sh"     # подключает функции и сорсит ocvpn.sh
#   check "имя" "want" "got"
#   check_true "имя" bash -c '...'
#   finish                          # печатает Итог и выходит с кодом
set -uo pipefail

: "${OCVPN_SCRIPT:?"OCVPN_SCRIPT не задан (запусти через tests/coverage.sh)"}"

WORK="$(mktemp -d /tmp/ocvpn-cov-XXXXXX)"
PASS=0
FAIL=0

_cleanup() {
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
    done < <(jobs -p 2>/dev/null || true)
    pkill -f "fake-xray" 2>/dev/null || true
    pkill -f "tail -n0 -F $WORK" 2>/dev/null || true
    rm -rf "$WORK"
}
trap _cleanup EXIT

# --- изолированное окружение (ДО source ocvpn.sh) ---
mkdir -p "$WORK/home"
printf '# user hosts\n' > "$WORK/user-hosts"
printf '# test hosts\n' > "$WORK/hosts"
export HOME="$WORK/home"
export OCVPN_USER_HOSTS_FILE="$WORK/user-hosts"
export OCVPN_HOSTS_FILE="$WORK/hosts"
export OCVPN_SYS_SUBS_FILE="$WORK/sys-subs-url"
export OCVPN_STATE_DIR="$WORK/state"
export OCVPN_OPENCODE_LOG="$WORK/opencode.log"
mkdir -p "$OCVPN_STATE_DIR"
: > "$OCVPN_OPENCODE_LOG"

# --- source реального скрипта (guard не даёт main запуститься) ---
# shellcheck disable=SC1090
source "$OCVPN_SCRIPT"
set +e
no_cleanup 2>/dev/null || true
# ocvpn.sh при source ставит свой trap cleanup и no_cleanup его снимает —
# возвращаем наш trap, иначе $WORK утекает.
trap _cleanup EXIT

# --- изолированные пути состояния/маршрутов ---
TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
TMPDIR_BASE="$WORK/tmpbase"; mkdir -p "$TMPDIR_BASE"
OCVPN_STATE_DIR="$WORK/state"; mkdir -p "$OCVPN_STATE_DIR"
QUARANTINE_FILE="$OCVPN_STATE_DIR/quarantine.tsv"
ACTIVE_FILE="$OCVPN_STATE_DIR/active.env"
WATCH_PIDFILE="$OCVPN_STATE_DIR/watch.pid"
LAST_ROTATE_FILE="$OCVPN_STATE_DIR/last_rotate"
REASON_FILE="$OCVPN_STATE_DIR/rotate.reason"
ROTATE_HOUR_FILE="$OCVPN_STATE_DIR/rotate_hour"
ROTATIONS_LOG="$OCVPN_STATE_DIR/rotations.tsv"
OPENCODE_LOG="$WORK/opencode.log"
OCVPN_LOG="$WORK/ocvpn.log"
PF_CONF="$WORK/pf.conf"; : > "$PF_CONF"
PF_ANCHOR_FILE="$WORK/pf.anchor"
HOSTS_FILE="$WORK/hosts"
USER_HOSTS_FILE="$WORK/user-hosts"
export OCVPN_STATE_DIR

# === SAFETY: физически не даём тестам тронуть хост ===
# _kill_matching в ocvpn бьёт pgrep+kill по широким маскам — в тестах
# ограничиваем убийство только собственными фейками.
_kill_matching() {
    local pid args
    while IFS= read -r pid; do
        [[ -z "$pid" || "$pid" == "$$" ]] && continue
        args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
        case "$args" in
            *fake-xray*|*fake-ocvpn*) kill "$pid" 2>/dev/null || true ;;
        esac
    done < <(pgrep -f "$1" 2>/dev/null || true)
}
_kill_matching9() {
    local pid args
    while IFS= read -r pid; do
        [[ -z "$pid" || "$pid" == "$$" ]] && continue
        args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
        case "$args" in
            *fake-xray*|*fake-ocvpn*) kill -9 "$pid" 2>/dev/null || true ;;
        esac
    done < <(pgrep -f "$1" 2>/dev/null || true)
}
# Внешние мутирующие команды — заглушки. Тест может переопределить локально
# (например, записывающий мок iptables) для проверки вызовов.
iptables() { :; }
pfctl() { :; }
ss() { :; }
ip() { :; }
route() { :; }
sysctl() { :; }
curl() { return 1; }

check() { # name want got
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $1 (want=[$2] got=[$3])"
    fi
}
check_true() { # name cmd...
    local name="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $name"; fi
}
# jq-помощник без jq: достать значение из JSON (python3 всегда есть).
jget() { # file python_expr
    python3 -c "import json,sys; d=json.load(open('$1')); print($2)" 2>/dev/null
}

finish() {
    echo "Итог: PASS=$PASS FAIL=$FAIL"
    [[ $FAIL -eq 0 ]]
}
