#!/usr/bin/env bash
# Тесты фичи ocvpn --update и проверки обновлений при старте.
# API: _ver_gt, gh_resolve/gh_latest_version(_cached), do_update, check_update_offer.
. "$(dirname "$0")/lib.sh"

# ===========================================================================
echo "=== [1] _ver_gt ==="
check "_ver_gt 1.5.5>1.5.4" "0" "$(_ver_gt 1.5.5 1.5.4; echo $?)"
check "_ver_gt 1.5.4>1.5.5" "1" "$(_ver_gt 1.5.4 1.5.5; echo $?)"
check "_ver_gt 1.6>1.5.9" "0" "$(_ver_gt 1.6 1.5.9; echo $?)"
check "_ver_gt 2.0.0>1.9.9" "0" "$(_ver_gt 2.0.0 1.9.9; echo $?)"
check "_ver_gt равно" "1" "$(_ver_gt 1.5.5 1.5.5; echo $?)"
check "_ver_gt 1.5.10>1.5.9" "0" "$(_ver_gt 1.5.10 1.5.9; echo $?)"

# ===========================================================================
echo "=== [2] _needs_root --update ==="
check_true "_needs_root --update" _needs_root --update

# ===========================================================================
echo "=== [3] gh_resolve / gh_latest_version (curl-стаб) ==="
FAKE_SCRIPT='#!/usr/bin/env bash
OCVPN_VERSION="9.9.9"
echo fake'
REL_JSON='{"tag_name":"v9.9.9"}'
TAGS_JSON='[{"name":"v9.9.9"}]'
SAVE_CURL="$(declare -f curl)"
curl() {
    local out="" url="" a
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o) out="$2"; shift 2 ;;
            -*) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    local body=""
    case "$url" in
        *releases/latest*) body="$REL_JSON" ;;
        */tags) body="$TAGS_JSON" ;;
        *main/ocvpn.sh*|*"v9.9.9"/ocvpn.sh*) body="$FAKE_SCRIPT" ;;
        *) return 1 ;;
    esac
    if [[ -n "$out" ]]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
    return 0
}
check "gh_latest_version" "9.9.9" "$(gh_latest_version test/repo)"
check "gh_resolve version+ref" "9.9.9"$'\t'"main" "$(gh_resolve test/repo)"
# тег новее main -> ref=тег
FAKE_SCRIPT='#!/usr/bin/env bash
OCVPN_VERSION="1.0.0"'
TAGS_JSON='[{"name":"v9.9.9"}]'
REL_JSON='{"tag_name":""}'
check "gh_resolve tag > main" "9.9.9"$'\t'"v9.9.9" "$(gh_resolve test/repo)"

# ===========================================================================
echo "=== [4] do_update: новая версия ==="
FAKE_SCRIPT='#!/usr/bin/env bash
OCVPN_VERSION="9.9.9"
echo fake'
REL_JSON='{"tag_name":"v9.9.9"}'
TAGS_JSON='[{"name":"v9.9.9"}]'
BIN="$WORK/installed-ocvpn"
APP="$WORK/app-ocvpn.sh"
rm -f "$BIN"; : > "$APP"
OCVPN_BIN="$BIN" OCVPN_APP_SCRIPT="$APP" OCVPN_REPO="test/repo" OCVPN_UPDATE_TTL=0 \
    do_update >/dev/null 2>&1
check "do_update rc=0" "0" "$?"
check "do_update поставил bin" "1" "$(grep -c 'OCVPN_VERSION="9.9.9"' "$BIN" 2>/dev/null || true)"
check "do_update обновил app-бандл" "1" "$(grep -c 'OCVPN_VERSION="9.9.9"' "$APP" 2>/dev/null || true)"
check "bin исполняемый" "1" "$([[ -x "$BIN" ]] && echo 1 || echo 0)"

# ===========================================================================
echo "=== [5] do_update: уже последняя ==="
FAKE_SCRIPT='#!/usr/bin/env bash
OCVPN_VERSION="1.5.5"'
REL_JSON='{"tag_name":"v1.5.5"}'
TAGS_JSON='[{"name":"v1.5.5"}]'
rm -f "$BIN"
out="$( OCVPN_BIN="$BIN" OCVPN_APP_SCRIPT="$APP" OCVPN_REPO="test/repo" \
    OCVPN_UPDATE_TTL=0 do_update 2>&1 )"
check "do_update same rc=0" "0" "$?"
check "do_update same не ставит" "0" "$([[ -f "$BIN" ]] && echo 1 || echo 0)"
check_true "do_update same сообщает" grep -q 'последняя' <<<"$out"

# ===========================================================================
echo "=== [6] do_update: ошибка сети ==="
curl() { return 1; }
rm -f "$BIN"
OCVPN_BIN="$BIN" OCVPN_APP_SCRIPT="$APP" OCVPN_REPO="test/repo" OCVPN_UPDATE_TTL=0 \
    do_update >/dev/null 2>&1
check "do_update curl fail rc=1" "1" "$?"
check "do_update curl fail не ставит" "0" "$([[ -f "$BIN" ]] && echo 1 || echo 0)"

# ===========================================================================
echo "=== [7] do_update: битый скачанный файл ==="
FAKE_SCRIPT='not a script'
REL_JSON='{"tag_name":"v9.9.9"}'
TAGS_JSON='[{"name":"v9.9.9"}]'
eval "$SAVE_CURL"
curl() {
    local out="" url="" a
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o) out="$2"; shift 2 ;;
            -*) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    local body=""
    case "$url" in
        *releases/latest*) body="$REL_JSON" ;;
        */tags) body="$TAGS_JSON" ;;
        *main/ocvpn.sh*|*"v9.9.9"/ocvpn.sh*) body="$FAKE_SCRIPT" ;;
        *) return 1 ;;
    esac
    if [[ -n "$out" ]]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
    return 0
}
rm -f "$BIN"
OCVPN_BIN="$BIN" OCVPN_APP_SCRIPT="$APP" OCVPN_REPO="test/repo" OCVPN_UPDATE_TTL=0 \
    do_update >/dev/null 2>&1
check "do_update битый файл rc=1" "1" "$?"
check "do_update битый файл не ставит" "0" "$([[ -f "$BIN" ]] && echo 1 || echo 0)"

# ===========================================================================
echo "=== [8] check_update_offer ==="
FAKE_SCRIPT='#!/usr/bin/env bash
OCVPN_VERSION="9.9.9"
echo fake'
REL_JSON='{"tag_name":"v9.9.9"}'
TAGS_JSON='[{"name":"v9.9.9"}]'
rm -f "$BIN"
out="$( OCVPN_BIN="$BIN" OCVPN_APP_SCRIPT="$APP" OCVPN_REPO="test/repo" \
    OCVPN_UPDATE_TTL=0 check_update_offer 2>&1 )"
check "offer non-TTY не ставит" "0" "$([[ -f "$BIN" ]] && echo 1 || echo 0)"
check_true "offer non-TTY подсказывает --update" grep -q -- '--update' <<<"$out"

out="$( OCVPN_NO_UPDATE_CHECK=1 check_update_offer 2>&1 )"
check "offer NO_UPDATE_CHECK молчит" "" "$out"

out="$( printf 'y\n' | OCVPN_ASSUME_TTY=1 OCVPN_BIN="$BIN" OCVPN_APP_SCRIPT="$APP" \
    OCVPN_REPO="test/repo" OCVPN_UPDATE_TTL=0 check_update_offer 2>&1 )"
check "offer y: установил" "1" "$(grep -c 'OCVPN_VERSION="9.9.9"' "$BIN" 2>/dev/null || true)"
check_true "offer y: запустил новую версию" grep -q '^fake' <<<"$out"

rm -f "$BIN"
out="$( printf 'n\n' | OCVPN_ASSUME_TTY=1 OCVPN_BIN="$BIN" OCVPN_APP_SCRIPT="$APP" \
    OCVPN_REPO="test/repo" OCVPN_UPDATE_TTL=0 check_update_offer 2>&1 )"
check "offer n: не ставит" "0" "$([[ -f "$BIN" ]] && echo 1 || echo 0)"

# ===========================================================================
echo "=== [9] do_update: ошибка установки ==="
FAKE_SCRIPT='#!/usr/bin/env bash
OCVPN_VERSION="9.9.9"'
REL_JSON='{"tag_name":"v9.9.9"}'
TAGS_JSON='[{"name":"v9.9.9"}]'
# curl-стаб из [7] ещё активен; bin — в несуществующем каталоге
OCVPN_BIN="$WORK/no-such-dir/ocvpn" OCVPN_APP_SCRIPT="$APP" OCVPN_REPO="test/repo" \
    OCVPN_UPDATE_TTL=0 do_update >/dev/null 2>&1
check "do_update install fail rc=1" "1" "$?"

eval "$SAVE_CURL"

finish
