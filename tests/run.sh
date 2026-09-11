#!/usr/bin/env bash
# Запуск тестов OCVPN батчами с жёсткими таймаутами, чтобы ничего не висело.
# Использование: bash tests/run.sh [секунд_на_батч]   (по умолчанию 180)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIMIT="${1:-180}"
RC_ALL=0

_kill_tree() { # добить дочерние процессы теста
    pkill -f 'sleep 12' 2>/dev/null || true
    pkill -f 'sleep 6' 2>/dev/null || true
    pkill -f 'fake-xray' 2>/dev/null || true
}

run_batch() { # name secs cmd...
    local name="$1" secs="$2"; shift 2
    local log rc
    log="$(mktemp)"
    echo ">>> [$name] timeout=${secs}s"
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 5 "$secs" "$@" >"$log" 2>&1
        rc=$?
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout -k 5 "$secs" "$@" >"$log" 2>&1
        rc=$?
    else
        "$@" >"$log" 2>&1 &
        local pid=$!
        ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) &
        local wd=$!
        wait "$pid"
        rc=$?
        kill "$wd" 2>/dev/null
        wait "$wd" 2>/dev/null
    fi
    if [[ $rc -eq 0 ]]; then
        echo "    OK: $(grep -E '^Итог' "$log" | tail -1)"
    else
        if [[ $rc -eq 124 || $rc -eq 137 ]]; then
            echo "    TIMEOUT (rc=$rc). Последний раздел:"
        else
            echo "    FAIL (rc=$rc). Хвост:"
        fi
        grep -E '^=== \[' "$log" | tail -1 | sed 's/^/      /'
        tail -5 "$log" | sed 's/^/      /'
        RC_ALL=1
    fi
    _kill_tree
    rm -f "$log"
}

if command -v getent >/dev/null 2>&1 && command -v md5sum >/dev/null 2>&1; then
    run_batch "functional (ocvpn-tests.sh)" "$LIMIT" bash "$REPO/ocvpn-tests.sh"
else
    echo ">>> [functional] пропуск: нужен Linux (getent/md5sum)"
fi
run_batch "coverage (tests/ocvpn-coverage.sh)" "$LIMIT" bash "$HERE/ocvpn-coverage.sh"

if [[ "$(uname -s)" == "Darwin" ]]; then
    run_batch "macOS app bundle (tests/macos-app-test.sh)" "$LIMIT" bash "$HERE/macos-app-test.sh"
fi

echo
if [[ $RC_ALL -eq 0 ]]; then
    echo "ВСЕ БАТЧИ: OK"
else
    echo "ЕСТЬ ПАДЕНИЯ/ТАЙМАУТЫ"
fi
exit $RC_ALL
