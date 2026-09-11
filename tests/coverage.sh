#!/usr/bin/env bash
# Покрытие ocvpn.sh по строкам без bashcov/kcov (они виснут на этом тесте).
# Трассируем выполнение через PS4='...BASH_SOURCE:LINENO...' и считаем
# уникальные исполненные строки ocvpn.sh относительно исполняемых строк файла.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="$REPO/ocvpn.sh"
TRACE="$(mktemp)"
LOG="$(mktemp)"
SHIM="$(mktemp)"
trap 'rm -f "$TRACE" "$LOG" "$SHIM"' EXIT

cat > "$SHIM" <<'SHIM_EOF'
if [[ -n "${OCVPN_TRACE_FILE:-}" ]]; then
    exec 19>>"$OCVPN_TRACE_FILE"
    export BASH_XTRACEFD=19
    PS4='+@${BASH_SOURCE}:${LINENO}@'
    export PS4
    set -x
fi
SHIM_EOF

echo "Запуск тестов с трассировкой (BASH_ENV shim, fd 19)…"
OCVPN_TRACE_FILE="$TRACE" BASH_ENV="$SHIM" bash "$HERE/ocvpn-coverage.sh" >"$LOG" 2>&1
RC=$?
echo "Тесты: rc=$RC, $(grep -E '^Итог' "$LOG" | tail -1)"

python3 - "$SRC" "$TRACE" <<'PY'
import sys, re, os
src, trace = sys.argv[1], sys.argv[2]
real = os.path.realpath(src)
executed = set()
pat = re.compile(r'@([^:@]*):(\d+)@')
with open(trace, errors='replace') as f:
    for line in f:
        m = pat.search(line)
        if not m:
            continue
        fname, lno = m.group(1), int(m.group(2))
        if os.path.realpath(fname) == real:
            executed.add(lno)
coverable = set()
with open(src, errors='replace') as f:
    for i, l in enumerate(f, 1):
        s = l.strip()
        if not s or s.startswith('#'):
            continue
        coverable.add(i)
hit = len(executed & coverable)
tot = len(coverable)
pct = 100.0 * hit / tot if tot else 0.0
print(f"COVERAGE ocvpn.sh: {hit}/{tot} = {pct:.1f}%")
missing = sorted(coverable - executed)
print(f"Непокрытых исполняемых строк: {len(missing)}")
if os.environ.get("OCVPN_COV_LIST"):
    src_lines = open(src, errors='replace').read().splitlines()
    groups = []
    for n in missing:
        if groups and n == groups[-1][-1] + 1:
            groups[-1].append(n)
        else:
            groups.append([n])
    for g in groups:
        a, b = g[0], g[-1]
        print(f"--- {a}-{b} ---")
        for n in range(a, b + 1):
            if n <= len(src_lines):
                print(f"{n}: {src_lines[n-1]}")
PY
exit $RC
