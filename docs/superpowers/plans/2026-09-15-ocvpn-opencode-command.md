# ocvpn × opencode `/ocvpn` + авторегистрация — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Установка ocvpn автоматически регистрирует в opencode команду `/ocvpn` (статус, подписка, смена IP, старт/стоп, очистка); смена IP применяется к работающему opencode без рестарта (сброс established-сокетов); установщики сами находят/предлагают поставить opencode; покрытие ocvpn.sh ≥ 90%.

**Architecture:** Вся логика остаётся в `ocvpn.sh` (bash). `/ocvpn` — обычная custom command opencode (markdown-промпт), которую `ocvpn --install-opencode-command` кладёт в `~/.config/opencode/commands/`; инсталляторы (deb `postinst`, macOS `install.sh`) вызывают её автоматически. Сброс соединений (`ss -K` / `pfctl -K`) — хук в `activate_current`. Тесты — table-driven в `tests/ocvpn-coverage.sh` (source-режим, изолированный HOME) + гейт `OCVPN_COV_MIN=90` в `tests/coverage.sh`.

**Tech Stack:** bash (портативно, без mapfile/associative arrays — совместимо с bash 3.2 macOS), systemd/LaunchDaemon, iptables/pf, opencode custom commands, `ss`/`pfctl`.

---

## File Structure

- Modify: `ocvpn.sh` — HOME default, `opencode_present`/`ensure_opencode`, `install_opencode_command`, `reset_opencode_conns`, хук в `activate_current`, ветки `main`, `print_help`, `OCVPN_VERSION`.
- Create: `opencode/ocvpn.md` — канонический текст команды (тест сверяет с тем, что пишет `install_opencode_command`).
- Create: `AGENTS.md` — инструкция установки для LLM-агентов.
- Modify: `packaging/debian/postinst` — вызвать `--install-opencode-command` и `--ensure-opencode`.
- Modify: `packaging/macos/install.sh` — то же.
- Modify: `tests/ocvpn-coverage.sh` — куча новых table-тестов.
- Modify: `ocvpn-tests.sh` — black-box тесты новых флагов.
- Modify: `tests/coverage.sh` — гейт `OCVPN_COV_MIN`.
- Modify: `packaging/macos/OCVPN.app/Contents/Resources/ocvpn.sh` — синхронизация из `ocvpn.sh`.
- Modify: `Makefile`, `README.md` — версия/чинджлог.
- Rebuild: `dist/ocvpn-1.5.5-all.deb`, `dist/ocvpn-1.5.5-macos.tar.gz`.

---

## Task 0: Baseline — зелёный прогон и зафиксировать цифры

**Files:**
- Test: `tests/ocvpn-coverage.sh`, `ocvpn-tests.sh`

- [ ] **Step 1: Прогнать функциональные тесты**

Run: `bash ocvpn-tests.sh`
Expected: `Итог: PASS=59 FAIL=0`

- [ ] **Step 2: Прогнать покрытие и найти падающие кейсы**

Run: `bash tests/coverage.sh 2>&1 | tee /tmp/cov-base.log`
Expected: строка `COVERAGE ocvpn.sh: X/Y = Z%`, в логе `Итог: PASS=168 FAIL=2` (baseline этого окружения: 932/1721 = 54.2%).
Найти 2 падения: `grep -n 'FAIL' /tmp/cov-base.log`.

- [ ] **Step 3: Исправить 2 падающих кейса (если они не связаны с сетью/правами)**

Если падение из-за отсутствия `getent`/записи в `/etc` — привести кейс к изоляции (использовать `$WORK`, env-override). Если падение сетевое (реальный `curl`) — пометить кейс как skip при недоступности сети через `command -v`/таймаут.
Expected: `Итог: PASS=170 FAIL=0`.

- [ ] **Step 4: Commit**

```bash
git add tests/ocvpn-coverage.sh
git commit -m "test: чиним 2 падающих кейса покрытия (изоляция env/сети)"
```

---

## Task 1: HOME под systemd (крэш сервиса)

**Files:**
- Modify: `ocvpn.sh:1-8`
- Test: `tests/ocvpn-coverage.sh` (секция `[Z] HOME`)

- [ ] **Step 1: Написать падающий тест**

Добавить в `tests/ocvpn-coverage.sh` перед блоком `echo "=== [X] main-ветки ...`:

```bash
echo "=== [Z] HOME default (systemd без HOME) ==="
hdef="$(env -u HOME bash -c 'source "$1"; printf "%s" "$HOME"' _ "$SCRIPT" 2>/dev/null)"
check "HOME default при пустом HOME" "/root" "$hdef"
```

- [ ] **Step 2: Прогнать — тест падает**

Run: `bash tests/ocvpn-coverage.sh 2>&1 | grep -A1 '\[Z\] HOME'`
Expected: FAIL (HOME пустой/`unbound variable`).

- [ ] **Step 3: Реализация**

В `ocvpn.sh` после строки `export PATH="/usr/sbin:/sbin:$PATH"` (строка 6) добавить:

```bash
# systemd/launchd system-сервис не задаёт HOME — иначе set -u роняет на $HOME.
export HOME="${HOME:-/root}"
```

- [ ] **Step 4: Прогнать — тест проходит**

Run: `bash tests/ocvpn-coverage.sh 2>&1 | grep '\[Z\] HOME'`
Expected: `PASS=... FAIL=0` (кейс `HOME default` не в FAIL).

- [ ] **Step 5: Проверить, что сервис поднимается**

```bash
bash packaging/debian/build.sh 1.5.5 && dpkg -i dist/ocvpn-1.5.5-all.deb
systemctl restart ocvpn; sleep 5; systemctl is-active ocvpn
```
Expected: `active` (а не `activating/auto-restart`).

- [ ] **Step 6: Commit**

```bash
git add ocvpn.sh tests/ocvpn-coverage.sh
git commit -m "fix(v1.5.5): HOME default под systemd — сервис больше не падает (HOME: unbound variable)"
```

---

## Task 2: Сброс established-соединений opencode при смене IP

**Files:**
- Modify: `ocvpn.sh` (новая функция рядом с `activate_current`, ~1585; хук в конце `activate_current`)
- Test: `tests/ocvpn-coverage.sh`

- [ ] **Step 1: Написать падающие тесты (со стабами `ss`/`pfctl`)**

Добавить в `tests/ocvpn-coverage.sh`:

```bash
echo "=== [Y] reset_opencode_conns ==="
mkdir -p "$WORK/stubs"
cat > "$WORK/stubs/ss" <<'SS'
#!/usr/bin/env bash
printf 'SS:%s\n' "$*" >> "${SS_LOG:-/dev/null}"
exit 0
SS
cat > "$WORK/stubs/pfctl" <<'PF'
#!/usr/bin/env bash
printf 'PF:%s\n' "$*" >> "${PF_LOG:-/dev/null}"
exit 0
PF
chmod +x "$WORK/stubs/ss" "$WORK/stubs/pfctl"

# Linux-ветка: ss -K по каждому IP из override
export SS_LOG="$WORK/ss.log"; : > "$SS_LOG"
OCVPN_RESET_IPS="10.1.1.1 10.1.1.2" PATH="$WORK/stubs:$PATH" OCVPN_OS=Linux reset_opencode_conns >/dev/null 2>&1
check "reset ss calls" "2" "$(grep -c '^SS:-K dst' "$SS_LOG")"
check_true "reset ss dst1" grep -q 'SS:-K dst 10.1.1.1' "$SS_LOG"
check_true "reset ss dst2" grep -q 'SS:-K dst 10.1.1.2' "$SS_LOG"

# macOS-ветка: pfctl -K
export PF_LOG="$WORK/pf.log"; : > "$PF_LOG"
OCVPN_RESET_IPS="10.2.2.2" PATH="$WORK/stubs:$PATH" OCVPN_OS=Darwin reset_opencode_conns >/dev/null 2>&1
check_true "reset pfctl -K" grep -q 'PF:-K 10.2.2.2' "$PF_LOG"
OCVPN_OS="$(uname -s)"

# нет инструмента: не падаем, возвращаем 0
PATH="/nonexistent" OCVPN_RESET_IPS="10.3.3.3" reset_opencode_conns >/dev/null 2>&1
check "reset без инструмента rc" 0 $?

# хук: activate_current вызывает reset
reset_opencode_conns() { echo CALLED >> "$WORK/reset.log"; }
setup_routes() { :; }
: > "$WORK/reset.log"
ACTIVE_HOST=h; ACTIVE_PORT=443; ACTIVE_LABEL=L; ACTIVE_EXIT_IP=1.2.3.4; XRAY_PID=999
activate_current >/dev/null 2>&1
check "activate_current зовёт reset" "1" "$(grep -c CALLED "$WORK/reset.log")"
```

- [ ] **Step 2: Прогнать — падает**

Run: `bash tests/ocvpn-coverage.sh 2>&1 | grep '\[Y\]'`
Expected: FAIL (функция не определена / нет вызовов).

- [ ] **Step 3: Реализация — функция**

Добавить в `ocvpn.sh` перед `activate_current` (перед строкой 1585):

```bash
# Закрыть established-соединения opencode к IP эндпоинтов: iptables/pf ловят
# только NEW, поэтому после смены exit IP старые keep-alive сокеты надо порвать.
# OCVPN_RESET_IPS (space-separated) — override для тестов; иначе резолвим домены.
reset_opencode_conns() {
    local ips ip
    if [[ -n "${OCVPN_RESET_IPS:-}" ]]; then
        ips=($OCVPN_RESET_IPS)
    else
        ips=()
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && ips+=("$ip")
        done < <(for d in "${OPENCODE_DOMAINS[@]}"; do resolve_ipv4 "$d"; done | sort -u)
    fi
    [[ ${#ips[@]} -eq 0 ]] && return 0
    if is_macos; then
        command -v pfctl >/dev/null 2>&1 || { warn "pfctl нет — перезапустите opencode, чтобы применить новый IP"; return 0; }
        for ip in "${ips[@]}"; do
            pfctl -K "$ip" >/dev/null 2>&1 \
                && log "Сброшены соединения opencode к $ip (pfctl -K)" \
                || warn "pfctl -K $ip не сработал — при необходимости перезапустите opencode"
        done
    else
        command -v ss >/dev/null 2>&1 || { warn "ss нет — перезапустите opencode, чтобы применить новый IP"; return 0; }
        for ip in "${ips[@]}"; do
            ss -K dst "$ip" >/dev/null 2>&1 \
                && log "Сброшены соединения opencode к $ip (ss -K)" \
                || warn "ss -K $ip: нет соединений/не поддержано — при необходимости перезапустите opencode"
        done
    fi
    return 0
}
```

- [ ] **Step 4: Реализация — хук**

В конце `activate_current`, после `mv "$tmp" "$ACTIVE_FILE"` (строка 1605), добавить:

```bash
    reset_opencode_conns
```

- [ ] **Step 5: Прогнать — проходит**

Run: `bash tests/ocvpn-coverage.sh 2>&1 | grep '\[Y\]'`
Expected: все `[Y]`-кейсы PASS, `FAIL=0`.

- [ ] **Step 6: Commit**

```bash
git add ocvpn.sh tests/ocvpn-coverage.sh
git commit -m "feat(v1.5.5): сброс established-сокетов opencode (ss -K/pfctl -K) — новый IP без рестарта opencode"
```

---

## Task 3: `--install-opencode-command` + `opencode/ocvpn.md`

**Files:**
- Modify: `ocvpn.sh` (новая функция + ветка `main` + `print_help`)
- Create: `opencode/ocvpn.md`
- Test: `tests/ocvpn-coverage.sh`, `ocvpn-tests.sh`

- [ ] **Step 1: Написать падающий тест (coverage)**

```bash
echo "=== [W] install_opencode_command ==="
export OCVPN_OPENCODE_CMD_DIR="$WORK/oc-cmd"
install_opencode_command >/dev/null 2>&1
check "cmd md создан" "yes" "$([[ -f "$OCVPN_OPENCODE_CMD_DIR/ocvpn.md" ]] && echo yes || echo no)"
check_true "cmd md description" grep -q '^description: .*ocvpn' "$OCVPN_OPENCODE_CMD_DIR/ocvpn.md"
check_true "cmd md menu ip" grep -q 'ocvpn --new-ip' "$OCVPN_OPENCODE_CMD_DIR/ocvpn.md"
# идемпотентность: повторный вызов не плодит файлы
install_opencode_command >/dev/null 2>&1
check "cmd md идемпотентно" "1" "$(ls "$OCVPN_OPENCODE_CMD_DIR" | grep -c '^ocvpn\.md$')"
# сверка с каноническим файлом репо
check "cmd md == opencode/ocvpn.md" "same" \
    "$(diff -q "$OCVPN_OPENCODE_CMD_DIR/ocvpn.md" "$(dirname "$SCRIPT")/opencode/ocvpn.md" >/dev/null 2>&1 && echo same || echo diff)"
unset OCVPN_OPENCODE_CMD_DIR
```

- [ ] **Step 2: Прогнать — падает**

Run: `bash tests/ocvpn-coverage.sh 2>&1 | grep '\[W\]'`
Expected: FAIL.

- [ ] **Step 3: Создать канонический `opencode/ocvpn.md`**

```markdown
---
description: Управление ocvpn — статус VPN, подписка, смена IP, старт/стоп
---
Ты — менеджер службы ocvpn (прозрачный VPN между opencode и эндпоинтами opencode/провайдеров).

Сначала ВСЕГДА покажи состояние:
1. `ocvpn --status` (и `systemctl is-active ocvpn.service`, если Linux).
2. Кратко: сервис запущен? exit IP? какой источник подписки?

Затем предложи меню:
1. Сменить IP — `ocvpn --new-ip`. При root/passwordless-sudo соединения сбрасываются автоматически (новый IP применяется сразу). Если прав нет — сообщи: «Перезапустите opencode (закрыть и открыть заново)» — терминал не нужен.
2. Подписка — спроси URL и выполни `ocvpn --subs <URL>`. При root продублируй: `printf '%s\n' '<URL>' > /etc/ocvpn/subs-url && chmod 600 /etc/ocvpn/subs-url`.
3. Старт/стоп сервиса — Linux: `systemctl start|stop ocvpn`; macOS: `launchctl kickstart -k system/ai.opencode.ocvpn` / `launchctl bootout system/ai.opencode.ocvpn`.
4. Очистка — `ocvpn --cleanup`.

Правила:
- Никогда не запускай интерактивный `sudo` (зависнет). Сначала `id -u`; если не root — `sudo -n true`.
  Есть права → команды напрямую или через `sudo -n`. Нет → только `ocvpn --status`/`--subs` и инструкция «перезапустите opencode».
- Подкоманды: `/ocvpn ip|new-ip`, `/ocvpn subs <URL>`, `/ocvpn start|stop`, `/ocvpn cleanup`, `/ocvpn status`.
- Ничего сверх перечисленного не делай.
```

- [ ] **Step 4: Реализация функции**

Добавить в `ocvpn.sh` рядом с `ensure_opencode` (см. Task 4) — прим. перед `print_help` (строка 1815):

```bash
# Установить команду /ocvpn в конфиг opencode. Идемпотентно. Целевой
# пользователь: $SUDO_USER (при sudo-установке) либо $HOME.
install_opencode_command() {
    no_cleanup
    local tgt_home cfg
    if [[ -n "${OCVPN_OPENCODE_CMD_DIR:-}" ]]; then
        cfg="$OCVPN_OPENCODE_CMD_DIR"
    else
        if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
            if is_macos; then
                tgt_home="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
            else
                tgt_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
            fi
            [[ -n "${tgt_home:-}" ]] || tgt_home="/home/$SUDO_USER"
        else
            tgt_home="$HOME"
        fi
        [[ -n "${tgt_home:-}" ]] || tgt_home="/root"
        cfg="${XDG_CONFIG_HOME:-$tgt_home/.config}/opencode/commands"
    fi
    mkdir -p "$cfg" || { err "Не удалось создать $cfg"; return 1; }
    cat > "$cfg/ocvpn.md" <<'OCVPN_CMD_MD'
<ВСТАВИТЬ СЮДА ТЕКСТ opencode/ocvpn.md БЕЗ ТЕРМИНАТОРНОЙ СТРОКИ>
OCVPN_CMD_MD
    log "Команда /ocvpn установлена: $cfg/ocvpn.md"
    return 0
}
```

> При реализации: скопировать содержимое `opencode/ocvpn.md` (шаг 3) в heredoc буква-в-букву (тест сверяет `diff`).

- [ ] **Step 5: Ветка `main` + help**

В `main` добавить ветку (после `--version|-V`, до `--status`):

```bash
        --install-opencode-command)
            install_opencode_command
            exit $?
            ;;
```

В `print_help` после строки `ocvpn --rotate [why]   то же, что --new-ip (алиас)`:

```
  ocvpn --install-opencode-command
                         установить команду /ocvpn в конфиг opencode
```

- [ ] **Step 6: Black-box тесты в `ocvpn-tests.sh`**

Добавить в секцию `[6] Перезапуск и --subs`:

```bash
TMPHOME="$(mktemp -d)"
env -u SUDO_USER HOME="$TMPHOME" bash "$SCRIPT" --install-opencode-command >/dev/null 2>&1
[[ -f "$TMPHOME/.config/opencode/commands/ocvpn.md" ]] && { PASS=$((PASS+1)); echo "  ▸ cmd install: OK"; } || { FAIL=$((FAIL+1)); echo "  ▸ cmd install: FAIL"; }
bash "$SCRIPT" --help | grep -q -- '--install-opencode-command' && { PASS=$((PASS+1)); echo "  ▸ help cmd: OK"; } || { FAIL=$((FAIL+1)); echo "  ▸ help cmd: FAIL"; }
rm -rf "$TMPHOME"
```

- [ ] **Step 7: Прогнать всё**

Run: `bash ocvpn-tests.sh && bash tests/ocvpn-coverage.sh 2>&1 | grep '\[W\]'`
Expected: functional `FAIL=0`; `[W]`-кейсы PASS.

- [ ] **Step 8: Commit**

```bash
git add ocvpn.sh opencode/ocvpn.md tests/ocvpn-coverage.sh ocvpn-tests.sh
git commit -m "feat(v1.5.5): --install-opencode-command — команда /ocvpn сама появляется в opencode"
```

---

## Task 4: `--ensure-opencode` — детект/установка opencode

**Files:**
- Modify: `ocvpn.sh` (функции + ветка `main` + help)
- Test: `tests/ocvpn-coverage.sh`

- [ ] **Step 1: Написать падающие тесты**

```bash
echo "=== [V] ensure_opencode ==="
check_true "opencode_present нет" bash -c '! OCVPN_OPENCODE_BIN= opencode_present >/dev/null 2>&1'
check "opencode_present bin" "/bin/true" "$(OCVPN_OPENCODE_BIN=/bin/true opencode_present)"
# non-interactive без opencode → подсказка, rc 0
ensure_opencode no >/dev/null 2>&1; check "ensure no rc" 0 $?
# yes с фейковым инсталлятором
OCVPN_OPENCODE_BIN=/bin/true OCVPN_OPENCODE_INSTALL_CMD="true" ensure_opencode yes >/dev/null 2>&1
check "ensure yes rc" 0 $?
# установка провалилась
OCVPN_OPENCODE_INSTALL_CMD="false" ensure_opencode yes >/dev/null 2>&1; check "ensure fail rc" 1 $?
```

- [ ] **Step 2: Прогнать — падает**

Run: `bash tests/ocvpn-coverage.sh 2>&1 | grep '\[V\]'`
Expected: FAIL.

- [ ] **Step 3: Реализация**

Добавить перед `install_opencode_command`:

```bash
# Найти opencode: override, бинарь в PATH, либо конфиг. Печатает путь.
opencode_present() {
    if [[ -n "${OCVPN_OPENCODE_BIN:-}" && -x "${OCVPN_OPENCODE_BIN}" ]]; then
        printf '%s' "$OCVPN_OPENCODE_BIN"; return 0
    fi
    local b
    b="$(command -v opencode 2>/dev/null || true)"
    [[ -n "$b" ]] && { printf '%s' "$b"; return 0; }
    if [[ -d "$HOME/.config/opencode" || -d "$HOME/.local/share/opencode" ]]; then
        printf '%s' "(конфиг найден, бинарь не в PATH)"; return 0
    fi
    return 1
}

# ensure_opencode [auto|ask|yes|no]: найти opencode; если нет — предложить
# установку официальным инсталлятором. auto: ask при tty, иначе no.
ensure_opencode() {
    no_cleanup
    local mode="${1:-auto}" where
    if where="$(opencode_present)"; then
        log "opencode найден: $where"
        return 0
    fi
    if [[ "$mode" == auto ]]; then
        if [[ -t 0 && -t 1 ]]; then mode=ask; else mode=no; fi
    fi
    if [[ "$mode" == ask ]]; then
        local ans
        read -r -p "opencode не найден. Установить сейчас? [Y/n]: " ans || ans=y
        case "${ans:-y}" in y|Y|yes|Yes|"") mode=yes ;; *) mode=no ;; esac
    fi
    if [[ "$mode" == yes ]]; then
        local cmd="${OCVPN_OPENCODE_INSTALL_CMD:-curl -fsSL https://opencode.ai/install | bash}"
        log "Ставлю opencode…"
        if bash -c "$cmd"; then
            if where="$(opencode_present)"; then log "opencode установлен: $where"; return 0; fi
            warn "opencode установлен, но не виден в PATH — перезапустите терминал."
            return 0
        fi
        warn "Не удалось установить opencode: https://opencode.ai/docs/"
        return 1
    fi
    warn "opencode не найден. Установите: curl -fsSL https://opencode.ai/install | bash (https://opencode.ai/docs/)"
    return 0
}
```

- [ ] **Step 4: Ветка `main` + help**

```bash
        --ensure-opencode)
            ensure_opencode "${2:-auto}"
            exit $?
            ;;
```

В `print_help`:
```
  ocvpn --ensure-opencode [auto|yes|no]
                         найти opencode; если нет — предложить установку
```

- [ ] **Step 5: Прогнать**

Run: `bash tests/ocvpn-coverage.sh 2>&1 | grep '\[V\]'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ocvpn.sh tests/ocvpn-coverage.sh
git commit -m "feat(v1.5.5): --ensure-opencode — детект и предложение установки opencode"
```

---

## Task 5: Авто-вызов из инсталляторов

**Files:**
- Modify: `packaging/debian/postinst`
- Modify: `packaging/macos/install.sh`
- Test: `ocvpn-tests.sh` (статическая проверка)

- [ ] **Step 1: Падающий тест (статический)**

```bash
grep -q 'install-opencode-command' packaging/debian/postinst && { PASS=$((PASS+1)); echo "  ▸ postinst cmd: OK"; } || { FAIL=$((FAIL+1)); echo "  ▸ postinst cmd: FAIL"; }
grep -q 'ensure-opencode' packaging/debian/postinst && { PASS=$((PASS+1)); echo "  ▸ postinst ensure: OK"; } || { FAIL=$((FAIL+1)); echo "  ▸ postinst ensure: FAIL"; }
grep -q 'install-opencode-command' packaging/macos/install.sh && { PASS=$((PASS+1)); echo "  ▸ mac install cmd: OK"; } || { FAIL=$((FAIL+1)); echo "  ▸ mac install cmd: FAIL"; }
```

- [ ] **Step 2: Прогнать — падает**

Run: `bash ocvpn-tests.sh 2>&1 | grep -E 'postinst|mac install'`
Expected: FAIL.

- [ ] **Step 3: postinst**

В `packaging/debian/postinst` после `systemctl enable ocvpn.service || true` добавить:

```sh
    # Команда /ocvpn в opencode (для пользователя установки) + детект opencode.
    /usr/local/bin/ocvpn --install-opencode-command >/dev/null 2>&1 || true
    /usr/local/bin/ocvpn --ensure-opencode auto >/dev/null 2>&1 || true
```

- [ ] **Step 4: macOS install.sh**

Перед строкой `/usr/local/bin/ocvpn --version` (строка 84) добавить:

```bash
# Команда /ocvpn в opencode + детект opencode (интерактивно, если терминал)
/usr/local/bin/ocvpn --install-opencode-command || true
/usr/local/bin/ocvpn --ensure-opencode auto || true
```

- [ ] **Step 5: Прогнать**

Run: `bash ocvpn-tests.sh 2>&1 | grep -E 'postinst|mac install'`
Expected: OK.

- [ ] **Step 6: Commit**

```bash
git add packaging/debian/postinst packaging/macos/install.sh ocvpn-tests.sh
git commit -m "feat(v1.5.5): инсталляторы сами регистрируют /ocvpn и проверяют opencode"
```

---

## Task 6: `AGENTS.md` — установка для LLM-агентов

**Files:**
- Create: `AGENTS.md`
- Test: `ocvpn-tests.sh`

- [ ] **Step 1: Падающий тест**

```bash
[[ -f AGENTS.md ]] && { PASS=$((PASS+1)); echo "  ▸ AGENTS.md есть: OK"; } || { FAIL=$((FAIL+1)); echo "  ▸ AGENTS.md есть: FAIL"; }
grep -q 'ocvpn' AGENTS.md && { PASS=$((PASS+1)); echo "  ▸ AGENTS.md ocvpn: OK"; } || { FAIL=$((FAIL+1)); echo "  ▸ AGENTS.md ocvpn: FAIL"; }
```

- [ ] **Step 2: Прогнать — падает**

Run: `bash ocvpn-tests.sh 2>&1 | grep 'AGENTS.md'`
Expected: FAIL.

- [ ] **Step 3: Создать `AGENTS.md`**

```markdown
# ocvpn — инструкция для AI-агента (установка «под ключ»)

Если пользователь просит установить ocvpn по ссылке на этот репозиторий — выполни шаги ниже сам, без вопросов, если явно не требуется иное.

## 1. Клонировать и определить ОС

```bash
git clone https://github.com/OTumanov/ocvpn.git && cd ocvpn
uname -s   # Linux | Darwin
```

## 2. Установить

- **Linux (Debian/Ubuntu):**
  ```bash
  make deb && sudo dpkg -i dist/ocvpn-*-all.deb
  sudo systemctl start ocvpn
  ```
- **macOS:**
  ```bash
  make macos-tar
  tar -xzf dist/ocvpn-*-macos.tar.gz -C /tmp
  cd /tmp/ocvpn-*-macos && sudo ./install.sh
  ```

## 3. Что произойдёт автоматически

- Ставится сервис ocvpn (systemd/LaunchDaemon), запускается в фоне.
- В конфиг opencode кладётся команда `/ocvpn` (`--install-opencode-command`).
- Если opencode не найден — установщик предложит поставить его (или подскажет команду).

## 4. Проверить

```bash
ocvpn --status
ls ~/.config/opencode/commands/ocvpn.md
```

## 5. Если opencode не установлен

```bash
curl -fsSL https://opencode.ai/install | bash
```

Затем перезапусти opencode — появится `/ocvpn`.
```

- [ ] **Step 4: Прогнать**

Run: `bash ocvpn-tests.sh 2>&1 | grep 'AGENTS.md'`
Expected: OK.

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md ocvpn-tests.sh
git commit -m "docs(v1.5.5): AGENTS.md — установка ocvpn для LLM-агентов под ключ"
```

---

## Task 7: Гейт покрытия ≥90%

**Files:**
- Modify: `tests/coverage.sh`
- Modify: `tests/run.sh`

- [ ] **Step 1: Тест-гейт (падает на текущих 54%)**

В `tests/coverage.sh` в python-блоке заменить финальный вывод так, чтобы он возвращал код по порогу:

```python
import sys, re, os
# ... существующий подсчёт hit/tot/pct ...
pct_min = float(os.environ.get("OCVPN_COV_MIN", "90"))
print(f"COVERAGE ocvpn.sh: {hit}/{tot} = {pct:.1f}% (min {pct_min:.0f}%)")
# ... список missing ...
sys.exit(0 if pct >= pct_min else 3)
```

И в конце bash-обёртки пробросить код python (заменить `exit $RC` на учёт обоих):

```bash
python3 - "$SRC" "$TRACE" <<'PY'
...
PY
COV_RC=$?
if [[ $RC -ne 0 ]]; then exit $RC; fi
exit $COV_RC
```

- [ ] **Step 2: Прогнать — падает на гейте**

Run: `OCVPN_COV_MIN=90 bash tests/coverage.sh; echo rc=$?`
Expected: `rc=3` (54% < 90%).

- [ ] **Step 3: Пробросить в `tests/run.sh`**

Изменить строку запуска coverage-батча:

```bash
run_batch "coverage (tests/ocvpn-coverage.sh)" "$LIMIT" env OCVPN_COV_MIN=90 bash "$HERE/coverage.sh"
```

- [ ] **Step 4: Commit**

```bash
git add tests/coverage.sh tests/run.sh
git commit -m "test(v1.5.5): жёсткий гейт покрытия OCVPN_COV_MIN (90%)"
```

---

## Task 8: Насыщение покрытия ocvpn.sh до ≥90%

**Files:**
- Modify: `tests/ocvpn-coverage.sh`

- [ ] **Step 1: Получить список непокрытых строк**

Run: `OCVPN_COV_LIST=1 bash tests/coverage.sh 2>&1 | sed -n '/Непокрытых/,$p' > /tmp/uncovered.txt; head -40 /tmp/uncovered.txt`

- [ ] **Step 2: Добавить table-тесты по регионам (примеры)**

Дописать в `tests/ocvpn-coverage.sh` (примеры — расширять по списку непокрытых):

```bash
echo "=== [COV] парсеры/конвертеры/карантин ==="
# url_host_port: граничные случаи
check "hp без порта" "h 443" "$(url_host_port 'vless://u@h#x')"
check "hp мусор" "" "$(url_host_port 'not-a-url' 2>/dev/null || true)"
# normalize_subs_url: blob→raw, уже raw, невалид
check "normalize blob" "https://raw.githubusercontent.com/a/b/refs/heads/main/x" \
  "$(normalize_subs_url 'https://github.com/a/b/blob/main/x')"
check "normalize raw as-is" "https://raw.githubusercontent.com/a/b/main/x" \
  "$(normalize_subs_url 'https://raw.githubusercontent.com/a/b/main/x')"
# parse_reset_hours: мин/часы/дни/дефолт/потолок
check "reset min" 1 "$(parse_reset_hours 'reset in 30 minutes')"
check "reset hours" 6 "$(parse_reset_hours 'reset in 6 hours')"
check "reset days cap" 168 "$(parse_reset_hours 'reset in 30 days')"
check "reset default" 6 "$(parse_reset_hours 'без хинта')"
# карантин: add/lookup/expiry
qfile="$WORK/q.tsv"; : > "$qfile"
QUARANTINE_FILE="$qfile" quarantine_add "1.2.3.4" 443 "5.6.7.8" "test" 1
check_true "quarantine есть" bash -c "QUARANTINE_FILE='$qfile' quarantine_has '1.2.3.4' 443"
check_true "quarantine ip есть" bash -c "QUARANTINE_FILE='$qfile' quarantine_ip_has '5.6.7.8'"
# is_supported_key: все схемы и мусор
for s in vless vmess trojan ss http https socks socks5; do
  is_supported_key "$s://u@h:443?type=tcp#x" 2>/dev/null; check "sup $s" 0 $?
done
is_supported_key 'garbage'; check "sup мусор" 1 $?
# is_rotatable_limit: да/нет по паттернам
is_rotatable_limit 'AI_APICallError: Rate limit exceeded. Please try again later.'; check "limit zen" 0 $?
is_rotatable_limit 'Insufficient balance'; check "limit баланс" 1 $?
is_rotatable_limit 'not available in your country'; check "limit гео" 1 $?
is_rotatable_limit 'ollama.com/upgrade'; check "limit ollama" 1 $?
```

> Продолжать по списку `/tmp/uncovered.txt`, пока `OCVPN_COV_MIN=90 bash tests/coverage.sh` не станет `rc=0`. Каждый регион — table-тесты; не мокать сеть, где возможно.

- [ ] **Step 3: Гейт зелёный**

Run: `OCVPN_COV_MIN=90 bash tests/coverage.sh; echo rc=$?`
Expected: `COVERAGE ocvpn.sh: ... >= 90%` и `rc=0`.

- [ ] **Step 4: Полный прогон**

Run: `bash tests/run.sh`
Expected: `ВСЕ БАТЧИ: OK`.

- [ ] **Step 5: Commit**

```bash
git add tests/ocvpn-coverage.sh
git commit -m "test(v1.5.5): насыщение покрытия ocvpn.sh до ≥90%"
```

---

## Task 9: Синхронизация .app-копии, версия, артефакты

**Files:**
- Modify: `packaging/macos/OCVPN.app/Contents/Resources/ocvpn.sh`
- Modify: `ocvpn.sh:8`, `Makefile:1`, `README.md`
- Rebuild: `dist/`

- [ ] **Step 1: Синхронизировать встроенную копию**

```bash
cp ocvpn.sh packaging/macos/OCVPN.app/Contents/Resources/ocvpn.sh
chmod 0644 packaging/macos/OCVPN.app/Contents/Resources/ocvpn.sh
```

- [ ] **Step 2: Бамп версии**

`ocvpn.sh` строка 8: `OCVPN_VERSION="1.5.5"`.
`Makefile` строка 1: `VERSION ?= 1.5.5`.

- [ ] **Step 3: README — чинджлог**

В начало списка изменений (после строки `**v1.4.0:** ...`) добавить абзац:

```
**v1.5.5:** команда `/ocvpn` в opencode (статус, подписка, смена IP, старт/стоп,
очистка) ставится автоматически инсталлятором; смена IP применяется к работающему
opencode без рестарта (сброс established-сокетов `ss -K`/`pfctl -K`); `--ensure-opencode`
находит/предлагает установить opencode; фикс HOME под systemd; покрытие тестов ≥90%.
```

- [ ] **Step 4: Пересобрать артефакты**

```bash
make clean
make test
make deb
make macos-tar
ls -la dist/
```
Expected: `dist/ocvpn-1.5.5-all.deb`, `dist/ocvpn-1.5.5-macos.tar.gz`, тесты `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add ocvpn.sh packaging/macos/OCVPN.app/Contents/Resources/ocvpn.sh Makefile README.md dist/
git commit -m "chore(v1.5.5): версия 1.5.5, синхронизация .app, пересборка deb/tar"
```

---

## Task 10: Установка на этот хост и end-to-end проверка

**Files:** — (только проверка)

- [ ] **Step 1: Установить свежий deb**

```bash
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
dpkg -i dist/ocvpn-1.5.5-all.deb
```

- [ ] **Step 2: Сервис живой**

```bash
systemctl restart ocvpn; sleep 6; systemctl is-active ocvpn; tail -3 /var/log/ocvpn.log
```
Expected: `active`; в логе «Готово… exit IP …».

- [ ] **Step 3: Команда /ocvpn установлена**

```bash
ls -la /root/.config/opencode/commands/ocvpn.md && head -3 /root/.config/opencode/commands/ocvpn.md
```
Expected: файл есть, `description: … ocvpn …`.

- [ ] **Step 4: Смена IP без рестарта opencode**

```bash
ocvpn --status | grep -i 'exit'
ocvpn --new-ip; sleep 3; ocvpn --status | grep -i 'exit'
```
Expected: новый exit IP; в логе есть строка «Сброшены соединения opencode к … (ss -K)».

- [ ] **Step 5: Не ломает остальной хост**

```bash
iptables -t nat -L OPENCODE_VPN -n | head
ocvpn --cleanup && ocvpn --status
```

---

## Task 11: Пуш и релиз

- [ ] **Step 1: Проверить состояние**

```bash
git -C /tmp/ocvpn status
git -C /tmp/ocvpn log --oneline -8
```

- [ ] **Step 2: Push (SSH)**

```bash
git -C /tmp/ocvpn remote set-url origin git@github.com:OTumanov/ocvpn.git
git -C /tmp/ocvpn push origin main
```

- [ ] **Step 3: Тег и релиз**

```bash
git -C /tmp/ocvpn tag -a v1.5.5 -m "v1.5.5: /ocvpn command, сброс сокетов, ensure-opencode, HOME fix, coverage 90%"
git -C /tmp/ocvpn push origin v1.5.5
```
Релиз на GitHub: если есть `gh` — `gh release create v1.5.5 dist/ocvpn-1.5.5-all.deb dist/ocvpn-1.5.5-macos.tar.gz --notes-file <(git log -1 --format=%b)`. Если `gh`/токена нет — сообщить пользователю, что нужно создать релиз вручную (ассеты из `dist/`).

---

## Self-Review

- **Spec coverage:** п.1 регистрация → Task 3/5; п.2 команда → Task 3; п.3 HOME → Task 1; п.4 сброс соединений → Task 2; п.5 права/фоллбеки → Task 3 (текст md) + Task 4; п.6 синхронизация/версия → Task 9; п.7 тесты → Tasks 0,1–8; детект opencode → Task 4/5; AGENTS.md → Task 6. Гейт ≥90% → Task 7/8.
- **Placeholders:** в Task 3 шаг 4 явно помечено вставить текст `opencode/ocvpn.md` буква-в-букву (тест `diff` это гарантирует). Остальные шаги с полным кодом.
- **Type consistency:** `OCVPN_RESET_IPS`, `OCVPN_OPENCODE_BIN`, `OCVPN_OPENCODE_INSTALL_CMD`, `OCVPN_OPENCODE_CMD_DIR`, `OCVPN_COV_MIN` — используются согласованно во всех задачах.
- **Риск:** достижение 90% по всему файлу — объёмная работа (Task 8); гейт честно падает, пока цель не достигнута.
