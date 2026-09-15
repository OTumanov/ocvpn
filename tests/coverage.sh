#!/usr/bin/env bash
# Покрытие ocvpn.sh по строкам без bashcov/kcov (они виснут на этом тесте).
# Трассируем выполнение через PS4='...BASH_SOURCE:LINENO...' и считаем
# уникальные исполненные строки ocvpn.sh относительно исполняемых строк файла.
#
# Прогоняет ocvpn-coverage.sh + все tests/cov-*.sh под единым трейсом,
# суммирует PASS/FAIL и проверяет порог OCVPN_COV_MIN (по умолчанию 95).
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

TESTS=("$HERE/ocvpn-coverage.sh")
while IFS= read -r f; do
    [[ -n "$f" ]] && TESTS+=("$f")
done < <(ls -1 "$HERE"/cov-*.sh 2>/dev/null || true)

echo "Запуск тестов с трассировкой (BASH_ENV shim, fd 19)…"
TOTAL_RC=0
for t in "${TESTS[@]}"; do
    name="$(basename "$t")"
    {
        echo ""
        echo "########## $name ##########"
    } >>"$LOG"
    OCVPN_TRACE_FILE="$TRACE" BASH_ENV="$SHIM" OCVPN_SCRIPT="$SRC" \
        bash "$t" >>"$LOG" 2>&1
    rc=$?
    [[ $rc -ne 0 ]] && TOTAL_RC=1
    res="$(grep -E '^Итог: PASS=' "$LOG" | tail -1)"
    echo "  $name → rc=$rc, ${res:-нет Итога}"
done

SUM_PASS="$(grep -E '^Итог: PASS=' "$LOG" | sed -n 's/.*PASS=\([0-9]*\).*/\1/p' | awk '{s+=$1} END{print s+0}')"
SUM_FAIL="$(grep -E '^Итог: PASS=' "$LOG" | sed -n 's/.*FAIL=\([0-9]*\).*/\1/p' | awk '{s+=$1} END{print s+0}')"
echo "Тесты суммарно: PASS=${SUM_PASS:-0} FAIL=${SUM_FAIL:-0}"

COV_OUT="$(python3 - "$SRC" "$TRACE" <<'PY'
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
    src_lines = f.read().splitlines()

STRUCT = {'fi', 'done', 'esac', 'else', 'then', 'do', ';;', '}', '{', 'elif', ';;&', ';&', '|', ')'}
FUNC_DEF = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{?\s*(#.*)?$')
ARR_DEF = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=\(\s*$')
CASE_LABEL = re.compile(r"^[A-Za-z0-9_*?|./\[\]-]+\)\s*;{0,2}\s*$")

struct_re = re.compile(r'^(done|fi|esac|else|elif|\})\b')

def _quote_state(l, state):
    """Состояние кавычек в конце строки. state: None | "'" | '"'.
    Корректно игнорирует кавычки внутри кавычек другого типа."""
    i = 0
    n = len(l)
    while i < n:
        c = l[i]
        if state is None:
            if c == '\\':
                i += 2
                continue
            if c == "'":
                state = "'"
            elif c == '"':
                state = '"'
        elif state == '"':
            if c == '\\':
                i += 2
                continue
            if c == '"':
                state = None
        else:  # "'"
            if c == "'":
                state = None
        i += 1
    return state

heredoc = None
qstate = None
in_array = False
in_cont = False
for i, l in enumerate(src_lines, 1):
    if heredoc is not None:
        # тело heredoc — данные, bash их не трассирует.
        if l.strip() == heredoc or l == heredoc:
            heredoc = None
        continue
    if qstate is not None:
        # продолжение многострочной строки (данные, не отдельная команда).
        qstate = _quote_state(l, qstate)
        continue
    if in_array:
        # элементы массива — литералы, не исполняемые строки.
        if re.match(r'^\)\s*;?\s*$', l.strip()):
            in_array = False
        continue
    if in_cont:
        # продолжение команды (перенос через \) — одна команда.
        if not l.rstrip().endswith('\\'):
            in_cont = False
        continue
    s = l.strip()
    if s.startswith('#'):
        # комментарий не влияет на состояние кавычек/heredoc
        continue
    if ARR_DEF.match(s):
        in_array = True
        continue
    if s and not s.startswith('#') and s not in STRUCT \
            and not struct_re.match(s) and not re.match(r'^;;(\s*#.*)?$', s) \
            and not CASE_LABEL.match(s) and not FUNC_DEF.match(s):
        coverable.add(i)
    # начало heredoc: <<WORD, <<-WORD, <<'WORD', <<"WORD"
    m = re.findall(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", l)
    if m:
        heredoc = m[-1][1]
        continue
    qstate = _quote_state(l, None)
    if qstate is None and l.rstrip().endswith('\\'):
        in_cont = True
hit = len(executed & coverable)
tot = len(coverable)
pct = 100.0 * hit / tot if tot else 0.0
print(f"COVERAGE ocvpn.sh: {hit}/{tot} = {pct:.1f}%")
missing = sorted(coverable - executed)
print(f"Непокрытых исполняемых строк: {len(missing)}")
if os.environ.get("OCVPN_COV_LIST"):
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
)"
printf '%s\n' "$COV_OUT"

PCT="$(printf '%s\n' "$COV_OUT" | sed -n 's/.* = \([0-9.]*\)%.*/\1/p' | tail -1)"
COV_MIN="${OCVPN_COV_MIN:-95}"
echo "Порог покрытия: ${COV_MIN}% (факт ${PCT:-0}%)"
if awk "BEGIN{exit !(( ${PCT:-0} ) < ( ${COV_MIN} ))}"; then
    echo "ПОРОГ ПОКРЫТИЯ НЕ ПРОЙДЕН: ${PCT:-0}% < ${COV_MIN}%"
    exit 3
fi
exit $TOTAL_RC
