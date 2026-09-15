# ocvpn TUI-меню без участия LLM — дизайн

Дата: 2026-09-15. Статус: утверждён пользователем (секции 1–5 + 2.1),
аудит субагента по исходникам apстрима — дыры залатаны (см. §7).

## 0. Контекст и цель

Команда `/ocvpn` (`opencode/ocvpn.md`) работает через LLM: промпт-шаблон интерпретируется
моделью. Требуется нативное меню в TUI opencode — как переключение сессий
(`session.list`) и модели (`model.list`): пункт палитры → диалог-пикер → действие
напрямую скриптами, без участия модели.

Исследование исходников: `sst/opencode` v1.18.30 (локально `/tmp/opencode/opencode-src`).

## 1. Архитектура: тонкий TUI-плагин

- Новый файл `opencode/ocvpn-tui.tsx` в репо ocvpn (рядом с `opencode/ocvpn.md`).
  Расширение строго `.tsx`: JSX в `.ts` ненадёжен, Solid-трансформ-loader
  регистрирует и `.tsx` (`packages/opencode/src/plugin/tui/runtime.ts:47`).
  Дефолт-экспорт ОБЯЗАН содержать `id` (file-плагины без `id` падают при загрузке —
  `packages/opencode/src/plugin/shared.ts:313-316`):
  `export default { id: "ocvpn", tui }`, где `tui(api, options)` вызывает
  `api.keymap.registerLayer({ commands: [{ name: "ocvpn.menu", title: "ocvpn",
  desc: "ocvpn", category: "ocvpn", namespace: "palette", run() {
  api.ui.dialog.replace(() => <OcvpnMenu/>) } }],
  bindings: [{ key: "ctrl+o", cmd: "ocvpn.menu", desc: "ocvpn" }] })` —
  по образцу встроенного `feature-plugins/system/plugins.tsx` (`plugins.list`).
- `ctrl+o` свободен в дефолтах (`packages/tui/src/config/keybind.ts:45-240` —
  совпадений нет). Пользовательский ребинд через `keybinds` конфига НЕВОЗМОЖЕН
  для команд плагинов (неизвестные ключи отбрасываются —
  `packages/opencode/src/config/tui.ts:72-82`; `parse()` бросает на неизвестных —
  `keybind.ts:450-451`). Поэтому: дефолт зашит литералом в коде; опциональный
  свой keybind — только через options плагина (`["file://…", { "key": "…" }]`,
  читается из второго аргумента `tui(api, options)` полностью внутри плагина).
- Bare-imports (`@opencode-ai/plugin/tui`, `solid-js`) из standalone-файла:
  шима резолва для file-плагинов в исходниках не найдено — план обязан включить
  smoke-тест импорта установленного файла из целевого каталога; фолбэк —
  относительные импорты или `package.json` рядом с плагином.
- Меню построено на `api.ui.DialogSelect` — том же пикере, что у session/model
  диалогов (`packages/tui/src/ui/dialog-select`). Цепочка «палитра → диалог →
  действие» — чистый UI-код, LLM нет ни на одном участке.
- Потолок API (адаптер прокидывает ровно 9 пропсов —
  `packages/tui/src/plugin/adapters.tsx:224-237`):
  `title/placeholder/options/flat/onMove/onFilter/onSelect/skipFilter/current`.
  НЕТ: `locked/actions/footerHints/emptyView/footer`. Следствия зафиксированы в §3.
  Опция имеет только `title/value/description/footer/category/disabled/onSelect`
  (`packages/plugin/src/tui.ts:161-170`) — этого хватает на planned-строки.
- Вся логика остаётся в bash: пункты меню запускают `ocvpn <subcommand>`
  дочерним процессом (`node:child_process` `execFile`/`spawn` — песочницы нет,
  TUI грузит плагин обычным Bun-`import()`; `$` из server-`PluginInput` в TUI
  НЕ инжектится, импортировать спавн должен сам плагин). TS не знает про VPN ничего.
- Привилегии: сначала проба `sudo -n true`; при отказе — `api.ui.DialogPrompt`
  для пароля → повтор через `sudo -S` (stdin, TTY не нужен; ограничение —
  sudoers с `requiretty`). Пароль: только в локальной переменной, никогда в лог/
  тост/историю, зануляется после использования, одна попытка; дальше — тост
  с готовой командой для ручного запуска. Маскирования ввода НЕТ — ни plugin-,
  ни внутренний `DialogPrompt` не имеют secure-пропа
  (`packages/plugin/src/tui.ts:150-159`): пароль виден при вводе, в `description`
  промпта так и написано.
- Результат: вывод — диалог-просмотр моноширинного текста + «Назад в меню»;
  короткий успех — `toast success`; ошибка — `toast error` + полный stderr,
  код возврата виден всегда.
- У команды нет `slashName`: в slash-список и промпт LLM она не попадает
  (`keymap.tsx:271-273` требует `slashName: string`). Существующая `/ocvpn`-команда
  остаётся для совместимости.
- Только не-deprecated API (`keymap.registerLayer`, `ui.*`). Минимум opencode 1.18.x.

## 2. Состав меню + 2.1. Два режима

Плоский `DialogSelect`. Ввод значений — `DialogPrompt`, опасные действия —
`DialogConfirm`. Данные живые: меню перестраивается при каждом открытии.

### Обычный режим (дефолт)

| Пункт | Действие |
|---|---|
| Статус VPN | `ocvpn --status` → просмотр |
| Сменить IP | confirm («сбросит соединения opencode») → `ocvpn --new-ip` → результат → назад в меню |
| Перезапустить (новый ключ + IP) | confirm → `ocvpn --restart` |
| Хвост лога | `spawn tail -n 100 /var/log/ocvpn.log` (стриминг, не `exec`) → просмотр |

### Продвинутый режим

Всё из обычного плюс:

| Пункт | Действие |
|---|---|
| Мои хосты: список | `ocvpn --hosts` → просмотр |
| Добавить хост | `DialogPrompt` (домен, валидация как в CLI) → `ocvpn --add-host` |
| Убрать хост | второй `DialogSelect` со списком из `ocvpn --hosts` → `ocvpn --rm-host` |
| Запустить в фоне | `ocvpn --daemon` |
| Запустить с вотчдогом | `ocvpn --daemon --watch` |
| Остановить, снять маршруты | confirm → `ocvpn --cleanup` |
| Сменить источник ключей | `DialogPrompt` (URL/файл) → `ocvpn --restart --subs …` |

Переключатель «Режим: обычный ⇄ продвинутый» — последний пункт меню.
Выбор хранится в `api.kv` под префиксом `ocvpn:` (`ocvpn:mode`) — kv глобально
общий для всех плагинов (`packages/tui/src/context/kv.tsx`, один `kv.json`).
Дефолт — обычный.

### Вне scope

Foreground-запуск (блокирует — бессмысленно из меню), `--help`/`--version`,
просмотр логов opencode (диагностика агента, остаётся в CLI). Будущие сабкоманды
CLI добавляются одной строкой в массив опций.

## 3. UX и состояния

- Открытие: палитра `ocvpn.menu` / `ctrl+o` → `dialog.replace(Menu)`, размер large.
- Долгие операции (`new-ip`/`restart`): `locked` у плагина НЕТ — busy guard
  на стороне плагина: сигнал `busy`, `run()` выходит раньше времени, все опции
  помечаются `disabled: true` на время выполнения. Таймаут 120 с реализуется
  в коде плагина (`AbortController` + kill), на уровне TUI лимитов нет.
- Пустой список хостов (удаление не из чего): дефолтный «No results found»
  (`dialog-select.tsx:603-607`), свой `emptyView` недоступен — приемлемо.
- Confirm-тексты честные: `new-ip`/`restart`/`cleanup` предупреждают про сброс
  соединений opencode на 443 (reset_opencode_conns) и смену exit IP.

## 4. Установка и жизнь плагина

- `ocvpn --install-opencode-command` расширяется: кладёт `ocvpn-tui.tsx` по
  стабильному абсолютному пути, идемпотентно дописывает
  `file:///abs/path/ocvpn-tui.tsx` в `plugin`-массив `opencode.jsonc`
  (абсолютный spec — иммунитет к резолву относительно декларирующего конфига;
  `plugin` принимает строки и `[spec, options]` —
  `packages/core/src/v1/config/plugin.ts`). Правка строго текстовая, НЕ через
  JSON-парсер (иначе слетят комментарии jsonc): идемпотентный инсерт в массив
  (создать ключ при отсутствии), бэкап с меткой времени, проверка
  `python3 -c` + баланс скобок. Автообнаружение без правки конфига тоже
  существует (`.opencode/plugin|plugins/*.ts` — `packages/opencode/src/config/plugin.ts:18-30`),
  но основной путь — явный spec. После установки ТРЕБУЕТСЯ рестарт TUI
  (хот-лоад только на сессию через `plugins.add` — отдельно не автоматизируем).
- Версия — в шапке файла, обновление = перезапись.
- `--rm-opencode-command` сносит md-команду, файл плагина и spec — идемпотентно.

## 5. Тестирование (без LLM)

- Bun на хосте НЕТ, `node_modules` апстрима пуст, `npx tsc` сломан (Bun-catalog).
  Поэтому статика двухуровневая: (1) обязательная структурная проверка под
  обычным node — форма дефолт-экспорта (`id`+`tui`), форма `registerLayer`,
  наличие всех пунктов меню/сабкоманд (runnable всегда); (2) `tsc --noEmit`
  против SDK — best-effort, только при сети + установке workspace.
- Установка: sh-тест на существующем харнессе — файл+spec ставятся идемпотентно,
  бэкап создаётся, jsonc-комментарии целы, удаление чистит оба артефакта.
- Функционал: стаб `ocvpn` в PATH (эхо argv + fixture-вывод) для проверки
  маппинга пунктов без трогания VPN + ручной чеклист загрузки в TUI (палитра,
  хоткей, оба режима, sudo-фолбэк).
- Регресс: bash-покрытие держит порог 95 (`tests/coverage.sh:171`); TS-плагин
  в метрику не входит, изменений харнесса не требуется.

## 6. Риски

- TUI plugin API — v1, `command-shim` deprecated: используем только актуальный путь.
- Дрейф API opencode: при поломке на новой версии — зафиксировать максимальную
  проверенную версию в README и чинить маппинг (тонкий плагин чинится быстро).
- MCP для LLM осознанно НЕ делаем: детерминированным операциям модель не нужна,
  агент уже работает через bash, а MCP-инструменты поверх iptables — лишняя
  поверхность атаки (решение зафиксировано в обсуждении 2026-09-15).

## 7. Аудит и залатанные дыры (2026-09-15, субагент по исходникам v1.18.30)

1. CRITICAL: дефолт-экспорт без `id` падает при загрузке → `export default { id: "ocvpn", tui }` (§1).
2. MAJOR: маскирования пароля нет ни на одном слое → честный немaskированный ввод + предупреждение (§1).
3. MAJOR: ребинд через `keybinds` невозможен → литеральный `ctrl+o` + опция `key` (§1).
4. MAJOR: только 9 пропсов `DialogSelect` → plugin-side busy guard (§3).
5. MAJOR: файл `.tsx`, не `.ts`; bare-imports проверить smoke-тестом (§1).
6. MAJOR: bun нет → двухуровневая статика (§5).
7. MINOR: общий `kv` → префикс `ocvpn:` (§2.1).
8. MINOR: правка jsonc только текстом + бэкап + рестарт TUI (§4).
