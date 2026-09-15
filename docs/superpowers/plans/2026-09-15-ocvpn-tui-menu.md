# ocvpn TUI-меню без LLM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TUI-плагин opencode с меню ocvpn (палитра `ocvpn.menu` + `ctrl+o`, два режима) — все действия прямыми вызовами `ocvpn` CLI, без LLM.

**Architecture:** Тонкий плагин: чистая JS-модель меню (`opencode/ocvpn-tui-model.mjs`, тестируется node) + `.tsx`-точка входа (только UI-проводка к `DialogSelect`/prompt/confirm/toast) + расширение bash-инсталлера (heredoc по образцу `ocvpn.md`, text-level правка jsonc). Источник правды — файлы в `opencode/`, инсталлер сверяется diff-тестом.

**Tech Stack:** bash (ocvpn.sh, харнесс tests/lib.sh), Node 18 (`node --test`), Solid JSX под Bun-рантаймом opencode 1.18.x, `node:child_process` (execFile/spawn).

---

## File Structure

- Create: `opencode/ocvpn-tui-model.mjs` — константы, дескрипторы пунктов, `visibleItems`, `argvFor`, `parseHostsList`, `pluginSpecLine`. Ноль UI, ноль Node-специфики (кроме `export`).
- Create: `opencode/ocvpn-tui.tsx` — `export default { id: "ocvpn", tui }`; `registerLayer` (`ocvpn.menu`, `ctrl+o`, опция `key`); компоненты `OcvpnMenu`/`HostsRemoveMenu`/`ResultView`; exec-хелперы (`execFile`, `spawn` для лога, `sudo -n` проба, `sudo -S` фолбэк, таймаут 120000); busy-guard; kv `ocvpn:mode`.
- Create: `tests/tui-plugin.test.mjs` — `node:test`: модель + argv-маппинг через стаб-`ocvpn` в PATH + структурные ассёрты исходника `.tsx`.
- Create: `tests/cov-tui.sh` — харнесс lib.sh: install (файл=canon, spec идемпотентно, бэкап, комментарии целы, нотис про рестарт), rm (чистит оба артефакта), help содержит флаги.
- Modify: `ocvpn.sh` — `ocvpn_opencode_home()` (выделить из `install_opencode_command`, строки 2001-2019); heredoc `OCVPN_TUI_TSX`; `install_ocvpn_tui_plugin`/`rm_ocvpn_tui_plugin`; расширение `install_opencode_command` (ставит и md, и плагин); dispatch `--rm-opencode-command`; help-строки после строки 2069.
- Modify: `ocvpn.sh:10` + `Makefile:1` → `1.6.0`; `README.md` — подсекция про TUI-меню; пересборка `dist`.

---

### Task 1: Модель меню + node-тесты

**Files:**
- Create: `opencode/ocvpn-tui-model.mjs`
- Create: `tests/tui-plugin.test.mjs`

- [ ] **Step 1: Write the failing test** (финальный файл целиком):

```js
// tests/tui-plugin.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, chmodSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  PLUGIN_ID, DEFAULT_KEY, KV_MODE, MODES,
  visibleItems, argvFor, parseHostsList, pluginSpecLine, itemById,
} from "../opencode/ocvpn-tui-model.mjs";

test("константы плагина", () => {
  assert.equal(PLUGIN_ID, "ocvpn");
  assert.equal(DEFAULT_KEY, "ctrl+o");
  assert.equal(KV_MODE, "ocvpn:mode");
});

test("обычный режим: 4 пункта, без продвинутых", () => {
  const ids = visibleItems("normal").map((i) => i.id);
  assert.deepEqual(ids, ["status", "new-ip", "restart", "log"]);
});

test("продвинутый режим: 11 пунктов", () => {
  const ids = visibleItems("advanced").map((i) => i.id);
  assert.deepEqual(ids, ["status", "new-ip", "restart", "log", "hosts", "add-host", "rm-host", "daemon", "watchdog", "cleanup", "subs"]);
});

test("argvFor маппит пункты на сабкоманды", () => {
  assert.deepEqual(argvFor(itemById("status")), ["--status"]);
  assert.deepEqual(argvFor(itemById("new-ip")), ["--new-ip"]);
  assert.deepEqual(argvFor(itemById("watchdog")), ["--daemon", "--watch"]);
  assert.deepEqual(argvFor(itemById("add-host"), "example.com"), ["--add-host", "example.com"]);
  assert.deepEqual(argvFor(itemById("subs"), "https://x/y"), ["--restart", "--subs", "https://x/y"]);
});

test("parseHostsList: только домены, мусор отбрасывается", () => {
  const out = parseHostsList("api.openai.com\n\n  bad host \nchatgpt.com\n");
  assert.deepEqual(out, ["api.openai.com", "chatgpt.com"]);
});

test("pluginSpecLine: абсолютный file-spec", () => {
  assert.equal(pluginSpecLine("/root/.config/opencode/plugins/ocvpn-tui.tsx"), "file:///root/.config/opencode/plugins/ocvpn-tui.tsx");
});

test("argv реально уходят стабу ocvpn без изменений", () => {
  const dir = mkdtempSync(join(tmpdir(), "ocvpn-stub-"));
  const stub = join(dir, "ocvpn");
  const argvFile = join(dir, "argv");
  writeFileSync(stub, '#!/bin/bash\nprintf "%s\\n" "$@" > "' + argvFile + '"\n');
  chmodSync(stub, 0o755);
  const argv = argvFor(itemById("add-host"), "example.com");
  execFileSync(stub, argv);
  const got = readFileSync(argvFile, "utf8").trim().split("\n");
  assert.deepEqual(got, ["--add-host", "example.com"]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test tests/tui-plugin.test.mjs`
Expected: FAIL with `Cannot find module '../opencode/ocvpn-tui-model.mjs'`

- [ ] **Step 3: Write minimal implementation**

```js
// opencode/ocvpn-tui-model.mjs — чистая модель меню, ноль UI-зависимостей.
export const PLUGIN_ID = "ocvpn";
export const DEFAULT_KEY = "ctrl+o";
export const KV_MODE = "ocvpn:mode";
export const MODES = { normal: "normal", advanced: "advanced" };

const BOTH = ["normal", "advanced"];
const ADV = ["advanced"];

export const MENU = [
  { id: "status", modes: BOTH, title: "Статус VPN", description: "xray, порты, маршруты, exit IP", category: "Состояние", kind: "run", argv: ["--status"] },
  { id: "new-ip", modes: BOTH, title: "Сменить IP", description: "другой exit IP, сброс соединений", category: "Управление", kind: "confirm", argv: ["--new-ip"],
    confirm: { title: "Сменить IP?", message: "Соединения opencode на 443 будут сброшены, exit IP сменится." } },
  { id: "restart", modes: BOTH, title: "Перезапустить", description: "новый ключ + (обычно) новый IP", category: "Управление", kind: "confirm", argv: ["--restart"],
    confirm: { title: "Перезапустить VPN?", message: "Соединения opencode на 443 будут сброшены." } },
  { id: "log", modes: BOTH, title: "Хвост лога", description: "последние 100 строк /var/log/ocvpn.log", category: "Диагностика", kind: "log" },
  { id: "hosts", modes: ADV, title: "Мои хосты: список", description: "встроенные + свои", category: "Хосты", kind: "run", argv: ["--hosts"] },
  { id: "add-host", modes: ADV, title: "Добавить хост", description: "домен для обхода через VPN", category: "Хосты", kind: "prompt",
    argvOf: (input) => ["--add-host", input], prompt: { title: "Добавить хост", placeholder: "example.com" } },
  { id: "rm-host", modes: ADV, title: "Убрать хост", description: "выбор из списка", category: "Хосты", kind: "hosts-rm" },
  { id: "daemon", modes: ADV, title: "Запустить в фоне", description: "xray daemon", category: "Управление", kind: "run", argv: ["--daemon"] },
  { id: "watchdog", modes: ADV, title: "Запустить с вотчдогом", description: "фон + ротация при лимитах", category: "Управление", kind: "run", argv: ["--daemon", "--watch"] },
  { id: "cleanup", modes: ADV, title: "Остановить, снять маршруты", description: "стоп + cleanup", category: "Управление", kind: "confirm", argv: ["--cleanup"],
    confirm: { title: "Остановить VPN?", message: "Маршрутизация будет снята, соединения opencode на 443 сброшены." } },
  { id: "subs", modes: ADV, title: "Сменить источник ключей", description: "URL или файл, затем рестарт", category: "Подписка", kind: "prompt",
    argvOf: (input) => ["--restart", "--subs", input], prompt: { title: "Источник ключей", placeholder: "https://… или /path/to/subs.txt" } },
];

export function itemById(id) {
  const found = MENU.find((m) => m.id === id);
  if (!found) throw new Error("unknown menu item: " + id);
  return found;
}

export function visibleItems(mode) {
  return MENU.filter((m) => m.modes.includes(mode));
}

export function argvFor(item, input) {
  if (typeof item.argvOf === "function") {
    if (!input) throw new Error("input required for " + item.id);
    return item.argvOf(String(input).trim());
  }
  return [...item.argv];
}

const DOMAIN_LINE = /^[A-Za-z0-9_.*-]+(\.[A-Za-z0-9_.*-]+)+$/;

export function parseHostsList(text) {
  return String(text ?? "")
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => DOMAIN_LINE.test(l));
}

export function pluginSpecLine(absPath) {
  return "file://" + absPath;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test tests/tui-plugin.test.mjs`
Expected: `pass 7, fail 0`

- [ ] **Step 5: Commit**

```bash
git add opencode/ocvpn-tui-model.mjs tests/tui-plugin.test.mjs
git commit -m "feat(tui): модель меню ocvpn + node-тесты (режимы, argv, hosts-парсинг)"
```

---

### Task 2: Точка входа `.tsx`

**Files:**
- Create: `opencode/ocvpn-tui.tsx`
- Modify: `tests/tui-plugin.test.mjs` (append structural asserts)

- [ ] **Step 1: Write the failing structural test (append to test file)**

```js
import { readFileSync, existsSync } from "node:fs";

test("entry .tsx: форма, команда, keybind, все пункты", () => {
  const p = new URL("../opencode/ocvpn-tui.tsx", import.meta.url);
  assert.ok(existsSync(p), "opencode/ocvpn-tui.tsx существует");
  const src = readFileSync(p, "utf8");
  assert.match(src, /id:\s*["']ocvpn["']/);
  assert.match(src, /registerLayer/);
  assert.match(src, /ocvpn\.menu/);
  assert.match(src, /ctrl\+o/);
  assert.match(src, /DialogSelect/);
  assert.match(src, /DialogPrompt/);
  assert.match(src, /DialogConfirm/);
  assert.match(src, /sudo\s+-S/);
  for (const id of ["status", "new-ip", "restart", "log", "hosts", "add-host", "rm-host", "daemon", "watchdog", "cleanup", "subs"]) {
    assert.match(src, new RegExp(`["']${id}["']`), `пункт ${id} упомянут в entry`);
  }
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test tests/tui-plugin.test.mjs`
Expected: FAIL with `opencode/ocvpn-tui.tsx существует` (файла нет)

- [ ] **Step 3: Write minimal implementation** (полный файл `opencode/ocvpn-tui.tsx`, шапка `// ocvpn TUI plugin, version 1.6.0`):

```tsx
// ocvpn TUI plugin, version 1.6.0.
// Тонкое меню поверх `ocvpn` CLI: палитра ocvpn.menu + ctrl+o, два режима.
// Вся логика — в bash; здесь только UI-проводка. Без LLM.
import { execFile, spawn } from "node:child_process";
import { createSignal } from "solid-js";
import type { TuiPlugin, TuiPluginApi } from "@opencode-ai/plugin/tui";
import {
  PLUGIN_ID,
  DEFAULT_KEY,
  KV_MODE,
  MODES,
  visibleItems,
  itemById,
  argvFor,
  parseHostsList,
  type MenuItem,
} from "./ocvpn-tui-model.mjs";

const PALETTE_CMD = "ocvpn.menu";
const EXEC_TIMEOUT_MS = 120000;

type RunResult = { code: number; out: string; err: string };

function execOcvpn(argv: string[], password?: string): Promise<RunResult> {
  return new Promise((resolve) => {
    const cmd = password === undefined ? "ocvpn" : "sudo";
    const args = password === undefined ? argv : ["-S", "--", "ocvpn", ...argv];
    const child = execFile(
      cmd,
      args,
      { timeout: EXEC_TIMEOUT_MS, maxBuffer: 4 * 1024 * 1024 },
      (error, stdout, stderr) => {
        const code = error && typeof (error as { code?: unknown }).code === "number"
          ? ((error as { code: number }).code as number)
          : error
            ? 1
            : 0;
        resolve({ code, out: String(stdout ?? ""), err: String(stderr ?? "") });
      },
    );
    if (password !== undefined) child.stdin?.end(password + "\n");
    else child.stdin?.end();
  });
}

function deniedByRoot(err: string, code: number): boolean {
  return code !== 0 && /permission denied|operation not permitted|must be root|are you root|effective uid|sudo/i.test(err);
}

function OcvpnMenu(props: { api: TuiPluginApi }) {
  const { api } = props;
  const DS = api.ui.DialogSelect;
  const [busy, setBusy] = createSignal(false);
  const [mode, setMode] = createSignal<string>(api.kv.get(KV_MODE, MODES.normal));
  api.ui.dialog.setSize("large");

  const back = () => api.ui.dialog.replace(() => <OcvpnMenu api={api} />);

  const showResult = (title: string, body: string) => {
    api.ui.dialog.replace(() => {
      const A = api.ui.DialogAlert;
      return <A title={title} message={body.slice(0, 4000)} onConfirm={back} />;
    });
  };

  async function runItem(item: MenuItem, input?: string) {
    if (busy()) return;
    setBusy(true);
    try {
      let password: string | undefined;
      let res = await execOcvpn(argvFor(item, input));
      if (deniedByRoot(res.err, res.code)) {
        const pw: string | undefined = await new Promise((done) => {
          const P = api.ui.DialogPrompt;
          api.ui.dialog.replace(() => (
            <P
              title="Нужен sudo"
              description={() => <>{"Пароль будет виден при вводе. Один запрос, нигде не сохраняется."}</>}
              placeholder="пароль sudo"
              onConfirm={(v: string) => done(v)}
              onCancel={() => done(undefined)}
            />
          ));
        });
        back();
        if (pw) {
          password = pw;
          res = await execOcvpn(argvFor(item, input), password);
          password = undefined;
        }
      }
      if (res.code === 0) {
        const body = (res.out.trim() || "OK").slice(0, 4000);
        if (item.id === "status" || item.id === "hosts" || item.id === "log") showResult(item.title, body);
        else {
          api.ui.toast({ variant: "success", title: item.title, message: body.slice(0, 200) });
          back();
        }
      } else {
        api.ui.toast({ variant: "error", title: item.title, message: (res.err.trim() || `код ${res.code}`).slice(0, 300) });
        showResult(item.title + " — ошибка", `код: ${res.code}\n${res.err}\n${res.out}`.slice(0, 4000));
      }
    } finally {
      setBusy(false);
    }
  }

  function activate(id: string) {
    if (busy()) return;
    if (id === "rm-host") return removeHostFlow();
    const item = itemById(id);
    if (item.kind === "confirm" && item.confirm) {
      const C = api.ui.DialogConfirm;
      api.ui.dialog.replace(() => (
        <C title={item.confirm!.title} message={item.confirm!.message} onConfirm={() => { back(); void runItem(item); }} onCancel={back} />
      ));
      return;
    }
    if (item.kind === "prompt" && item.prompt) {
      const P = api.ui.DialogPrompt;
      api.ui.dialog.replace(() => (
        <P
          title={item.prompt!.title}
          placeholder={item.prompt!.placeholder}
          onConfirm={(v: string) => { back(); void runItem(item, v); }}
          onCancel={back}
        />
      ));
      return;
    }
    if (item.kind === "log") return tailLog();
    void runItem(item);
  }

  function tailLog() {
    if (busy()) return;
    setBusy(true);
    const chunks: string[] = [];
    const child = spawn("tail", ["-n", "100", "/var/log/ocvpn.log"]);
    child.stdout.on("data", (d) => chunks.push(String(d)));
    child.stderr.on("data", (d) => chunks.push(String(d)));
    child.on("close", () => {
      setBusy(false);
      showResult("Хвост лога", chunks.join("").trim() || "(пусто)");
    });
    child.on("error", (e) => {
      setBusy(false);
      api.ui.toast({ variant: "error", title: "Хвост лога", message: String(e).slice(0, 300) });
      back();
    });
  }

  async function removeHostFlow() {
    if (busy()) return;
    setBusy(true);
    try {
      const res = await execOcvpn(["--hosts"]);
      if (res.code !== 0) {
        api.ui.toast({ variant: "error", title: "Убрать хост", message: res.err.trim().slice(0, 300) || "не удалось получить список" });
        back();
        return;
      }
      const hosts = parseHostsList(res.out);
      const item = itemById("rm-host");
      api.ui.dialog.replace(() => {
        const DS2 = api.ui.DialogSelect;
        return (
          <DS2
            title="Убрать хост"
            options={hosts.map((h) => ({
              title: h,
              value: h,
              onSelect: () => {
                back();
                void runItem({ ...item, kind: "run", argv: ["--rm-host", h] });
              },
            }))}
          />
        );
      });
    } finally {
      setBusy(false);
    }
  }

  const toggle = () => {
    if (busy()) return;
    const next = mode() === MODES.normal ? MODES.advanced : MODES.normal;
    api.kv.set(KV_MODE, next);
    setMode(next);
  };

  return (
    <DS
      title="ocvpn"
      options={[
        ...visibleItems(mode()).map((item) => ({
          title: item.title,
          description: item.description,
          category: item.category,
          value: item.id,
          disabled: busy(),
          onSelect: () => activate(item.id),
        })),
        {
          title: mode() === MODES.normal ? "Режим: обычный → продвинутый" : "Режим: продвинутый → обычный",
          category: "Меню",
          value: "__toggle__",
          disabled: busy(),
          onSelect: toggle,
        },
      ]}
    />
  );
}

const tui: TuiPlugin = async (api, options) => {
  const key = typeof (options as { key?: unknown } | undefined)?.key === "string"
    && ((options as { key: string }).key as string).length > 0
    ? ((options as { key: string }).key as string)
    : DEFAULT_KEY;
  api.keymap.registerLayer({
    commands: [
      {
        name: PALETTE_CMD,
        title: "ocvpn",
        desc: "меню ocvpn без LLM",
        category: "ocvpn",
        namespace: "palette",
        run() {
          api.ui.dialog.replace(() => <OcvpnMenu api={api} />);
        },
      },
    ],
    bindings: [{ key, cmd: PALETTE_CMD, desc: "ocvpn" }],
  });
};

export default { id: PLUGIN_ID, tui };
```

NOTE: `MenuItem` импортирован как тип из `.mjs` — типов там нет; перед шагом заменить
`type MenuItem` на локальный тип в `.tsx`:

```tsx
type MenuItem = { id: string; title: string; description?: string; category?: string; kind: string; argv?: string[]; argvOf?: (input: string) => string[]; confirm?: { title: string; message: string }; prompt?: { title: string; placeholder?: string } };
```

(Используй этот локальный тип вместо `type MenuItem` из импорта; из `.mjs` импортируются только значения.)

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test tests/tui-plugin.test.mjs`
Expected: `pass 8, fail 0`

- [ ] **Step 5: Commit**

```bash
git add opencode/ocvpn-tui.tsx tests/tui-plugin.test.mjs
git commit -m "feat(tui): точка входа ocvpn-tui.tsx (палитра, ctrl+o, DialogSelect, sudo-фолбэк)"
```

---

### Task 3: Инсталлер плагина в `ocvpn.sh` + `tests/cov-tui.sh`

**Files:**
- Modify: `ocvpn.sh` (хелпер home, heredoc, install/rm, dispatch, help)
- Create: `tests/cov-tui.sh`

- [ ] **Step 1: Confirm test discovery**

Run: `rg -n "cov-.*\.sh|for .* in" tests/coverage.sh | head -5`
Expected: строка с glob `cov-*.sh` (новый `tests/cov-tui.sh` подхватится автоматически). Если glob другой — назови файл по найденному шаблону и поправь шаги ниже.

- [ ] **Step 2: Write the failing test** `tests/cov-tui.sh`:

```bash
#!/usr/bin/env bash
# TUI-плагин ocvpn: установка/удаление без участия LLM.
. "$(dirname "$0")/lib.sh"

CANON_TUI="$(cd "$(dirname "$0")/.." && pwd)/opencode/ocvpn-tui.tsx"
PLUGIN_FILE="$WORK/plugins/ocvpn-tui.tsx"
CFG="$WORK/cfg/opencode.jsonc"
mkdir -p "$WORK/plugins" "$WORK/cfg"
printf '{\n  // комментарий должен выжить\n  "theme": "x"\n}\n' > "$CFG"

# установка в изолированные пути (override)
OCVPN_OPENCODE_PLUGIN_FILE="$PLUGIN_FILE" OCVPN_OPENCODE_CONFIG="$CFG" install_ocvpn_tui_plugin >/dev/null 2>&1
check "tui install rc" "0" "$?"
check_true "файл плагина создан" test -f "$PLUGIN_FILE"
check_true "содержимое = opencode/ocvpn-tui.tsx" diff -q "$PLUGIN_FILE" "$CANON_TUI"
check_true "spec в plugin-массиве" grep -q "ocvpn-tui.tsx" "$CFG"
check_true "комментарий jsonc цел" grep -q "комментарий должен выжить" "$CFG"

# идемпотентность: повтор не дублирует spec
OCVPN_OPENCODE_PLUGIN_FILE="$PLUGIN_FILE" OCVPN_OPENCODE_CONFIG="$CFG" install_ocvpn_tui_plugin >/dev/null 2>&1
check "spec один" "1" "$(grep -c "ocvpn-tui.tsx" "$CFG")"
check_true "бэкап создан" ls "$CFG".bak-* >/dev/null 2>&1

# удаление чистит оба артефакта
OCVPN_OPENCODE_PLUGIN_FILE="$PLUGIN_FILE" OCVPN_OPENCODE_CONFIG="$CFG" rm_ocvpn_tui_plugin >/dev/null 2>&1
check "tui rm rc" "0" "$?"
check_true "файл плагина удалён" test ! -f "$PLUGIN_FILE"
check_true "spec удалён" bash -c '! grep -q "ocvpn-tui.tsx" "$0"' "$CFG"

# --install-opencode-command ставит и md, и плагин
CMD_DIR="$WORK/oc-cmds"
OCVPN_OPENCODE_CMD_DIR="$CMD_DIR" OCVPN_OPENCODE_PLUGIN_FILE="$PLUGIN_FILE" OCVPN_OPENCODE_CONFIG="$CFG" install_opencode_command >/dev/null 2>&1
check "общий install rc" "0" "$?"
check_true "md на месте" test -f "$CMD_DIR/ocvpn.md"
check_true "tsx на месте" test -f "$PLUGIN_FILE"

# help содержит новые флаги
check_true "help содержит --rm-opencode-command" bash -c '
    OCVPN_SUBS_URL=x bash "$0" --help 2>/dev/null | grep -q -- "--rm-opencode-command"
' "$OCVPN_SCRIPT"

finish
```

- [ ] **Step 3: Run test to verify it fails**

Run: `OCVPN_SCRIPT="$PWD/ocvpn.sh" bash tests/cov-tui.sh 2>&1 | tail -5`
Expected: FAIL (`install_ocvpn_tui_plugin: command not found` — функций ещё нет)

- [ ] **Step 4: Write minimal implementation** в `ocvpn.sh`:
  a) Выделить `ocvpn_opencode_home()` из тела `install_opencode_command` (строки 2004-2018) — та же логика SUDO_USER/getent/dscl/HOME, `printf '%s'` результата; `install_opencode_command` вызывает её вместо инлайн-блока.
  b) После heredoc `OCVPN_CMD_MD` (строка 2043) добавить heredoc `OCVPN_TUI_TSX` — побайтовая копия `opencode/ocvpn-tui.tsx` (генерация: сам файл — источник правды, в heredoc вставляется его содержимое один в один).
  c) Новые функции (после `install_opencode_command`, перед `# === Main ===`):

```bash
install_ocvpn_tui_plugin() {
    no_cleanup
    local home cfg plugin_file spec
    home="$(ocvpn_opencode_home)"
    cfg="${OCVPN_OPENCODE_CONFIG:-${XDG_CONFIG_HOME:-$home/.config}/opencode/opencode.jsonc}"
    plugin_file="${OCVPN_OPENCODE_PLUGIN_FILE:-${XDG_CONFIG_HOME:-$home/.config}/opencode/plugins/ocvpn-tui.tsx}"
    mkdir -p "$(dirname "$plugin_file")" "$(dirname "$cfg")" || { err "Не удалось создать каталоги"; return 1; }
    printf '%s\n' "$OCVPN_TUI_TSX" > "$plugin_file" || { err "Не удалось записать $plugin_file"; return 1; }
    spec="file://$plugin_file"
    [[ -f "$cfg" ]] || printf '{\n}\n' > "$cfg"
    cp -p "$cfg" "$cfg.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    OCVPN_PLUGIN_SPEC="$spec" OCVPN_PLUGIN_CFG="$cfg" python3 - <<'PYEOF'
import io, os, re
cfg = os.environ["OCVPN_PLUGIN_CFG"]
spec = os.environ["OCVPN_PLUGIN_SPEC"]
with io.open(cfg, encoding="utf-8") as f:
    text = f.read()
if spec in text:
    raise SystemExit(0)
m = re.search(r'"plugin"\s*:\s*\[(?P<body>[^\]]*)\]', text)
entry = '\n    "%s"\n  ' % spec
if m:
    body = m.group("body")
    sep = "" if body.strip() == "" else ","
    text = text[:m.start("body")] + body + sep + entry + text[m.end("body"):]
else:
    m2 = re.search(r'\{\s*\n', text)
    if m2:
        text = text[:m2.end()] + '  "plugin": [%s],\n' % entry + text[m2.end():]
    else:
        text = '{\n  "plugin": [%s]\n}\n' % entry
with io.open(cfg, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    log "TUI-плагин ocvpn установлен: $plugin_file (перезапустите TUI opencode)"
    return 0
}

rm_ocvpn_tui_plugin() {
    no_cleanup
    local home cfg plugin_file
    home="$(ocvpn_opencode_home)"
    cfg="${OCVPN_OPENCODE_CONFIG:-${XDG_CONFIG_HOME:-$home/.config}/opencode/opencode.jsonc}"
    plugin_file="${OCVPN_OPENCODE_PLUGIN_FILE:-${XDG_CONFIG_HOME:-$home/.config}/opencode/plugins/ocvpn-tui.tsx}"
    rm -f "$plugin_file"
    if [[ -f "$cfg" ]] && grep -q "ocvpn-tui.tsx" "$cfg" 2>/dev/null; then
        cp -p "$cfg" "$cfg.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        OCVPN_PLUGIN_CFG="$cfg" python3 - <<'PYEOF'
import io, os, re
cfg = os.environ["OCVPN_PLUGIN_CFG"]
with io.open(cfg, encoding="utf-8") as f:
    text = f.read()
text = re.sub(r'\s*"file://[^"]*ocvpn-tui\.tsx"\s*,?', "", text)
text = re.sub(r'"plugin"\s*:\s*\[\s*\]', '"plugin": []', text)
with io.open(cfg, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
    fi
    log "TUI-плагин ocvpn удалён"
    return 0
}
```

  d) `install_opencode_command`: перед `return 0` (строка 2045) добавить вызов `install_ocvpn_tui_plugin || return 1`.
  e) Dispatch в main после блока `--install-opencode-command` (строки 2193-2196):

```bash
        --rm-opencode-command)
            rm_ocvpn_tui_plugin
            exit $?
            ;;
```

  f) Help после строки 2069:

```
  ocvpn --rm-opencode-command
                         удалить команду /ocvpn и TUI-плагин из конфига opencode
```

  g) help-строку `--install-opencode-command` расширить: `установить команду /ocvpn и TUI-плагин в конфиг opencode`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `OCVPN_SCRIPT="$PWD/ocvpn.sh" bash tests/cov-tui.sh 2>&1 | tail -3`
Expected: `Итог` с `FAIL=0` (формат финиша — как в lib.sh `finish`)
Run: `node --test tests/tui-plugin.test.mjs`
Expected: `pass 8, fail 0`

- [ ] **Step 6: Commit**

```bash
git add ocvpn.sh tests/cov-tui.sh opencode/ocvpn-tui.tsx
git commit -m "feat(tui): установка/удаление TUI-плагина, heredoc canon, jsonc текстом"
```

---

### Task 4: Ворота покрытия и регресс

**Files:** (правка только при падениях)

- [ ] **Step 1: Run coverage gate**

Run: `bash tests/coverage.sh 2>&1 | tail -5`
Expected: `COVERAGE … ≥95%`, `FAIL=0` (порог `OCVPN_COV_MIN=95`). Новые строки инсталлера покрыты `cov-tui.sh`; при недоборе — дописать кейсы в `tests/cov-tui.sh` (бэкап-ветка, отсутствие cfg, повторный rm).

- [ ] **Step 2: Run functional tests**

Run: `bash ocvpn-tests.sh 2>&1 | tail -3`
Expected: `PASS=… FAIL=0` без изменений поведения (рефактор `ocvpn_opencode_home` не ломает `cov-command.sh`)

- [ ] **Step 3: Commit** (только если были правки)

```bash
git add -A && git commit -m "test(tui): добить покрытие/регресс до зелёного"
```

---

### Task 5: Best-effort tsc + ручной чеклист TUI

**Files:** none (проверка, не код)

- [ ] **Step 1: Best-effort typecheck (не блокирует)**

Run: `npx -y -p typescript tsc --noEmit --jsx react-jsx --jsxImportSource @opentui/solid --allowJs --skipLibCheck opencode/ocvpn-tui.tsx 2>&1 | head -20`
Expected: либо чисто, либо ошибки резолва `@opencode-ai/plugin/tui`/`solid-js` (сети/зависимостей нет) — зафиксировать вывод в коммит-месседже чеклиста как `tsc-best-effort: <кратко>`. Не чинить вслепую.

- [ ] **Step 2: Ручной чеклист в живом TUI** (хост, opencode ≥1.18, VPN НЕ трогать destructive без нужды):
  1. `ocvpn --install-opencode-command` → файл `~/.config/opencode/plugins/ocvpn-tui.tsx` = `opencode/ocvpn-tui.tsx` (diff пуст), spec в `opencode.jsonc`, бэкап создан.
  2. Рестарт TUI → палитра содержит `ocvpn`, `ctrl+o` открывает меню «ocvpn».
  3. Обычный режим: 4 пункта + переключатель; Статус показывает вывод `--status`.
  4. Переключатель → продвинутый: 11 пунктов; назад — обычный (пережить рестарт TUI: режим помнится через kv).
  5. Добавить хост `tui-probe-<дата>.example.com` → тост успеха; Убрать хост → виден в списке → удаление → повторный `--hosts` его не показывает. (Хвост очистить: `ocvpn --rm-host`.)
  6. `sudo -n true` сломать (тест под non-root невозможен на этом хосте — пропустить с пометкой, либо `alias sudo` в отдельной shell-сессии; зафиксировать).
  7. `ocvpn --rm-opencode-command` → оба артефакта удалены, рестарт TUI — пункта нет.

- [ ] **Step 3: Commit** (фикс по итогам чеклиста, если нужен; иначе пустой шаг — только отметка)

---

### Task 6: Релиз 1.6.0

**Files:**
- Modify: `ocvpn.sh:10` (`OCVPN_VERSION="1.5.5"` → `"1.6.0"`), `Makefile:1` (`VERSION ?= 1.5.5` → `VERSION ?= 1.6.0`), `README.md` (подсекция), `opencode/ocvpn-tui.tsx:1` (шапка `1.6.0` — уже)
- Rebuild: `dist/ocvpn-1.6.0-all.deb`, `dist/ocvpn-1.6.0-macos.tar.gz`

- [ ] **Step 1: Bump version**

Run: `sed -i 's/^OCVPN_VERSION="1.5.5"$/OCVPN_VERSION="1.6.0"/' ocvpn.sh && sed -i 's/^VERSION ?= 1.5.5$/VERSION ?= 1.6.0/' Makefile && rg -n 'OCVPN_VERSION="1.6.0"|VERSION \?= 1.6.0' ocvpn.sh Makefile`
Expected: две строки `10:OCVPN_VERSION="1.6.0"` и `1:VERSION ?= 1.6.0`

- [ ] **Step 2: README — подсекция TUI-меню**

Run: `rg -n "^#" README.md | head -20`
Expected: увидеть заголовок раздела установки (по прошлой практике — `## Установка`). Вставить после него подсекцию:

```markdown
### TUI-меню без LLM

`ocvpn --install-opencode-command` ставит TUI-плагин (`ocvpn.menu`, хоткей `ctrl+o`):
пункт палитры → меню → прямые вызовы `ocvpn`, модель не участвует. Два режима —
обычный (статус, смена IP, рестарт, лог) и продвинутый (хосты, daemon, cleanup,
источник ключей); переключатель — последний пункт меню.
```

- [ ] **Step 3: Rebuild artifacts + full gate**

Run: `bash packaging/debian/build.sh 1.6.0 && bash packaging/macos/build-tar.sh 1.6.0 && ls dist | rg "1.6.0"`
Expected: `ocvpn-1.6.0-all.deb`, `ocvpn-1.6.0-macos.tar.gz`
Run: `bash tests/coverage.sh 2>&1 | tail -2 && bash ocvpn-tests.sh 2>&1 | tail -2 && node --test tests/tui-plugin.test.mjs 2>&1 | tail -3`
Expected: покрытие ≥95% FAIL=0; функционалка FAIL=0; node pass 8 fail 0

- [ ] **Step 4: Commit + tag**

```bash
git add -A && git commit -m "release(v1.6.0): TUI-меню ocvpn без LLM (палитра, ctrl+o, два режима)" && git tag v1.6.0
```

---

## Self-Review (прогон автора плана)

1. **Spec coverage:** §1 (тонкий плагин, id, .tsx, keybind, sudo) → Task 2; bare-imports smoke → Task 5 п.2 (загрузка в живом TUI покажет); §2/2.1 (состав, режимы, kv-префикс) → Task 1+2; §3 (busy-guard, confirm, 120с, emptyView) → Task 2 код; §4 (heredoc, jsonc текстом, бэкап, рестарт-нотис, rm) → Task 3; §5 (двухуровневая статика, стаб, порог 95) → Task 1/3/4/5; §7 дыры — все 8 отражены. MCP — вне scope по решению.
2. **Placeholder scan:** нет TBD/TODO; все команды точные; версии/пути/имена — литералы; SYS-зависимости (`python3`, `node --test`, `rg`) проверены на хосте (python3 — из аудита, node v18.20.4, rg — использовался).
3. **Type consistency:** поля дескрипторов (`id/modes/title/description/category/kind/argv/argvOf/prompt/confirm`) одинаковы в модели, `.tsx` и тестах; `MenuItem` — локальный тип в `.tsx` (импорт типов из `.mjs` запрещён — указано в NOTE Task 2); kv-ключ `ocvpn:mode` везде литералом из `KV_MODE`.
