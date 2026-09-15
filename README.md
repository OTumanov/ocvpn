# ocvpn

Прозрачная маршрутизация эндпоинтов [opencode](https://opencode.ai) и провайдеров
моделей через VLESS-VPN. Весь остальной трафик хоста не затрагивается.

**Текущая версия: v1.5.5.**

## Что нового в v1.5.5

- **Команда `/ocvpn` в opencode** (`~/.config/opencode/commands/ocvpn.md`) — меню:
  статус, смена IP, подписка, **свой хост** (`--add-host` / `--rm-host` / `--hosts`),
  старт/стоп, очистка. Ставится автоматически инсталляторами
  (`--install-opencode-command`) + детект/предложение установки opencode
  (`--ensure-opencode`).
- **Свои домены через VPN** — `ocvpn --add-host example.com`. Список в
  `~/.config/ocvpn/hosts`, применяется сразу на активном соединении.
- **Сброс активных соединений при активации** (`ss -K` / `pfctl -K`) — новый exit IP
  применяется сразу, без «подождать, пока отвалится сам». Без root — подсказка
  перезапустить opencode.
- В обход добавлены **OpenRouter, ChatGPT/OpenAI, Gemini, Grok/xAI** (плюс
  пользовательские домены).
- **Фикс `HOME` под systemd** — сервис больше не падает с `HOME: unbound variable`
  и не чистит xray у ручного запуска.
- **Покрытие тестами ≥95%** (по факту 96%) и исправленные по их результатам баги:
  валидация `vless://`, `Host` для ws, декод `alpn` у trojan, `url_host_port` без
  userinfo, потеря stderr, дубли при `--add-host`, устаревшие записи в `/etc/hosts`.

<details>
<summary>История (v1.4.0 и ранее)</summary>

- **v1.4.0** — нативный SwiftUI-GUI вместо tkinter (Tk 8.5 тёк по памяти): секции
  «Состояние» / «Подписка» / «Логи», поле URL + «Сохранить», «Новый IP», блокировка
  в фоне, чтение лога хвостом.
- **v1.3.0** — `--daemon`, вотчдог лимитов (сам ротирует IP), гео-чек моделей,
  карантин, `--restart` / `--new-ip` / `--subs`, macOS-GUI.
- **v1.3.1–v1.3.6** — доработки macOS-GUI и инсталлятора.

</details>

## Зачем

Free-тариф opencode/zen/go лимитируется **по IP**. Смена выходного IP сбрасывает
лимит. ocvpn при каждом запуске выбирает случайный рабочий сервер из подписки —
новый выходной IP — и заворачивает через него **только** трафик к эндпоинтам
opencode и провайдеров.

## Как работает

1. Скачивает подписку с ключами (plain-text и **base64**, V2Board/Marzban).
2. Берёт `BATCH_SIZE` случайных поддерживаемых серверов, параллельно пингует (TCP-connect).
3. `MAX_TRIES` лучших по пингу — кандидаты; пробует реальное подключение через xray
   (`HTTP 204` на `google.com/generate_204`).
4. Первый рабочий ключ → прозрачный прокси (`iptables nat OUTPUT` / macOS `pf rdr`).
5. **Сбрасывает уже открытые соединения** к эндпоинтам (`ss -K` / `pfctl -K`), чтобы
   новый IP подхватился немедленно.
6. **Только** трафик к эндпоинтам из списка на порту 443 идёт через VPN, всё
   остальное — напрямую.

Каждый запуск = новая случайная выборка → новый ключ → новый exit IP.

## Эндпоинты

Домены форсируются в `/etc/hosts` (IPv4, без AAAA) и попадают в цепочку iptables
NAT `REDIRECT` → xray → VPN. По умолчанию туннелируются:

**Инфраструктура opencode:** `opencode.ai` (auth/console, Zen `/zen/v1`, Go
`/zen/go/v1`), `api.opencode.ai`, `models.opencode.ai`, `app.opencode.ai`, `opncd.ai`.

**Провайдеры моделей:**

| Провайдер | Домены |
|---|---|
| OpenRouter | `openrouter.ai`, `www.openrouter.ai` |
| OpenAI / ChatGPT | `api.openai.com`, `chatgpt.com`, `chat.openai.com`, `platform.openai.com`, `auth.openai.com` |
| Google Gemini | `generativelanguage.googleapis.com`, `gemini.google.com`, `aistudio.google.com`, `ai.google.dev` |
| xAI / Grok | `api.x.ai`, `grok.com`, `x.ai` |
| ZenMux | `zenmux.ai` |

> **Не** туннелируются (ходят напрямую, `DIRECT`): `api.deepseek.com`, `ollama.com`,
> `api.ollama.com`.

### Свой хост

Любой домен можно добавить в обход через VPN (сохраняется в
`~/.config/ocvpn/hosts`, применяется сразу, если VPN активен):

```bash
ocvpn --add-host example.com   # завести домен через VPN
ocvpn --hosts                  # показать итоговый список доменов
ocvpn --rm-host example.com    # убрать домен
```

Часть CLI из `/ocvpn` в opencode: просто напиши «добавь example.com через впн».

## Быстрый старт

```bash
git clone git@github.com:OTumanov/ocvpn.git
cd ocvpn
ocvpn --daemon          # в фон (лог ~/.local/share/ocvpn/ocvpn.log)
ocvpn --daemon --watch  # фон + вотчдог: сам ловит лимиты и ротирует IP
ocvpn --new-ip          # сменить exit IP сейчас
ocvpn --restart         # перезапустить в фоне: новый ключ (+ обычно новый IP)
ocvpn --subs https://…  # разовый источник ключей (URL подписки или txt с vless://)
```

На macOS — GUI: распаковать `dist/ocvpn-*-macos.tar.gz`, `sudo ./install.sh`,
открыть `/Applications/OCVPN.app`.

Скрипт автоматически установит xray (если нет) в `~/.local/opt/xray`, скачает
ключи, найдёт рабочий сервер и поднимет прокси.

**После запуска** открой сессию opencode. Маршрутизация — на уровне ядра, env не нужны.

> Скрипт запускай **до** opencode: `iptables nat OUTPUT` ловит только новые
> TCP-соединения. Если opencode уже работал до подключения — при смене IP сброс
> соединений (`ss -K`) применяется автоматически; при первом подключении просто
> перезапусти opencode один раз.

## Команда `/ocvpn` в opencode

Инсталляторы ставят команду сами. Вручную:

```bash
ocvpn --install-opencode-command   # положить ~/.config/opencode/commands/ocvpn.md
ocvpn --ensure-opencode auto       # найти opencode; если нет — предложить установку
```

После установки в opencode появится `/ocvpn` (нужен перезапуск opencode — команды
читаются при старте). Команда показывает статус и предлагает меню.

Для LLM-агентов есть [`AGENTS.md`](AGENTS.md) — пошаговая инструкция установки.

## Команды

| Команда | Описание |
|---------|----------|
| `ocvpn` | Запустить VPN в foreground (Ctrl-C = стоп + cleanup) |
| `ocvpn --daemon [--watch]` | Запустить в фоне, терминал свободен |
| `ocvpn --watch` | Вотчдог: следит за логом opencode, ловит IP-лимиты, ротирует |
| `ocvpn --new-ip` / `--rotate [why]` | Сменить exit IP сейчас (новый применяется сразу) |
| `ocvpn --restart` | Перезапустить в фоне: новый ключ (+ обычно новый IP) |
| `ocvpn --status` | Состояние: xray, порты, маршруты, ключ, exit IP, карантин, вотчдог |
| `ocvpn --cleanup` | Снять маршруты и убрать IPv4-записи из `/etc/hosts` |
| `ocvpn --add-host ДОМЕН` | Добавить свой домен в обход через VPN (сразу, если активен) |
| `ocvpn --rm-host ДОМЕН` | Убрать домен из пользовательского списка |
| `ocvpn --hosts` | Показать итоговый список доменов (встроенные + свои) |
| `ocvpn --install-opencode-command` | Установить команду `/ocvpn` в конфиг opencode |
| `ocvpn --ensure-opencode [auto\|yes\|no]` | Найти opencode; если нет — предложить установку |

`--subs URL|ФАЙЛ` можно передать в любом месте командной строки — разовый источник
ключей (URL подписки или готовый txt с `vless://`), например
`ocvpn --subs https://provider/sub --restart`.

## Вотчдог лимитов и ротация

Free-tier opencode/zen/go лимитируется **по IP**: смена exit IP сбрасывает лимит.
Вотчдог (`ocvpn --watch`, обычно с `--daemon`) хвостом читает лог opencode
(`~/.local/share/opencode/log/opencode.log`) и при строках вида:

- `AI_APICallError: Rate limit exceeded. Please try again later.`
- `Error from provider (Console): Rate limit exceeded…`
- `… usage limit reached. It will reset in N minutes/hours …`
- `Too many requests` / `429` от zen

шлёт держателю сигнал — тот кладёт исчерпанный IP в карантин и поднимает ключ с
**другим** exit IP. Старый ключ гасится только после проверки нового — обрыва нет.
Существующие соединения не переоткрываются сами по себе, но при активации нового
ключа ocvpn сбрасывает установленные сокеты к эндпоинтам (`ss -K` / `pfctl -K`),
так что новый IP применяется сразу (нужен root; без root — перезапусти opencode).

**Не триггерят** (смена IP не поможет): `ollama.com/upgrade`, `/settings`
(лимиты аккаунта ollama), `Insufficient balance`/`/billing` (деньги),
`not available in your country` (геоблок), `Forbidden`, `Model is disabled`,
`Cannot connect`, `Task cancelled`.

Защита от флэппинга: cooldown 600 сек (`OCVPN_ROTATE_COOLDOWN`) + максимум 6 ротаций
в час (`OCVPN_ROTATE_MAX_PER_HOUR`).

## Geo-check: доступность моделей из региона

При подключении/ротации проверяется, что из текущего exit IP **доступны модели
opencode** (геоблок детектится не по IP-гео, а по ответу API).
`check_model_available()` пробует 5 free-моделей через `api.opencode.ai`:

- HTTP **200/201/429** — модель отвечает → регион рабочий;
- HTTP **403/451** (или geo-паттерн в ответе) — геоблок;
- **500/timeout** — «неизвестно», не карантинится (шум сети).

Если **все** free-модели отдали геоблок — exit IP в карантин на **12 часов**,
подключение отменяется и пробуется следующий кандидат.

## Карантин

Исчерпанный сервер (`host:port`) и его exit IP не выбираются до истечения срока.
Число часов — по хинту из строки лимита (`reset in N minutes/hours/days`). Нет
хинта — дефолт 6 часов (`OCVPN_QUARANTINE_HOURS`), потолок 168.
Гео-заблокированные IP — 12 часов (`geo-block: модели не доступны из региона`).
Хранилище: `~/.local/share/ocvpn/quarantine.tsv`.

## Проверка, что VPN работает

```bash
# 1. Exit IP через SOCKS5 (должен отличаться от прямого)
curl -s https://ipinfo.io/ip
curl -s --proxy socks5h://127.0.0.1:10808 https://ipinfo.io/ip

# 2. Счётчик маршрута растёт
iptables -t nat -L OPENCODE_VPN -n -v | grep 172.65.90.20   # opencode.ai

# 3. opencode видит туннель
ss -tnp | grep opencode
```

## Тесты

```bash
bash ocvpn-tests.sh      # функциональные: ожидается PASS=70 FAIL=0
bash tests/coverage.sh   # покрытийные + гейт OCVPN_COV_MIN (по умолчанию 95)
```

`tests/coverage.sh` прогоняет `ocvpn-coverage.sh` + кластеры `tests/cov-*.sh` под
трассировкой и считает покрытие **исполняемых** строк `ocvpn.sh` (тела heredoc,
структурные строки и многострочные литералы исключаются). Текущее покрытие —
**96%** (`OCVPN_COV_LIST=1` печатает непокрытые строки). Порог: `OCVPN_COV_MIN=95`,
при недоборе — код выхода 3.

Кластеры: `cov-converters` (конвертеры протоколов), `cov-keys` (отбор/ротация),
`cov-subs-routes` (подписки/маршруты/hosts), `cov-status` (CLI/статус/main),
`cov-cli` (управление хостами), `cov-command` (`/ocvpn`, `--ensure-opencode`),
`cov-edge` (граничные ветки), `cov-source` (top-level), `cov-regress` (регрессы
исправленных багов), `cov-final`.

> `tests/lib.sh` **жёстко изолирует** тесты: `iptables`/`pfctl`/`ss`/`ip`/`pkill`
> заглушены, `HOME`/`/etc/hosts`/state — во временных файлах, а `_kill_matching`
> убивает только тестовые фейки. Прогон тестов не влияет на рабочий VPN хоста.

## Установка пакетами

```bash
make deb        # dist/ocvpn-1.5.5-all.deb        (Debian/Ubuntu, systemd-юнит)
make macos-tar  # dist/ocvpn-1.5.5-macos.tar.gz  (macOS: ocvpn + OCVPN.app + LaunchDaemon)
```

Debian: `sudo dpkg -i dist/ocvpn-*.deb` — сервис **включается, но не стартует сам**
(старт: `systemctl start ocvpn`); `postinst` ставит команду `/ocvpn` и вызывает
`--ensure-opencode auto`. macOS: распаковать архив, `sudo ./install.sh`; `.pkg`
собирается на самом Mac: `bash packaging/macos/build-pkg.sh`. SwiftUI-GUI:
`bash gui-swift/build.sh` (только на Mac).

## Конфигурация

Параметры в начале `ocvpn.sh`:

```bash
BATCH_SIZE=10    # сколько случайных ключей пинговать
MAX_TRIES=5      # сколько лучших кандидатов пробовать
PING_TIMEOUT=3   # таймаут TCP-пинга (сек)
TIMEOUT=5        # таймаут теста generate_204 (сек)
```

### Список эндпоинтов

Встроенный список — массив `OPENCODE_DOMAINS` в начале скрипта. Свои домены удобнее
добавлять через `ocvpn --add-host` (файл `~/.config/ocvpn/hosts`), они подмешиваются
к встроенным при старте.

При добавлении домена скрипт автоматически добавит IPv4-запись в `/etc/hosts`,
зарезолвит IP и добавит `REDIRECT`; при `--cleanup` всё удалит.

### Переменные окружения

| Переменная | Назначение |
|---|---|
| `OCVPN_SUBS_URL` | источник подписки (высший приоритет) |
| `OCVPN_SUBS_FILE` | локальный файл с ключами/списком |
| `OCVPN_SYS_SUBS_FILE` | системный файл подписки (по умолчанию `/etc/ocvpn/subs-url`) |
| `OCVPN_USER_HOSTS_FILE` | файл своих доменов (по умолчанию `~/.config/ocvpn/hosts`) |
| `OCVPN_HOSTS_FILE` | hosts-файл (по умолчанию `/etc/hosts`) |
| `OCVPN_STATE_DIR` | каталог состояния (по умолчанию `~/.local/share/ocvpn`) |
| `OCVPN_RESET_IPS` | явный список IP для сброса соединений (для тестов/скриптов) |
| `OCVPN_OPENCODE_CMD_DIR` | каталог установки команды `/ocvpn` |
| `OCVPN_OPENCODE_BIN` / `OCVPN_OPENCODE_INSTALL_CMD` | override детекта/установки opencode |
| `OCVPN_COV_MIN` | порог покрытия в `tests/coverage.sh` (по умолчанию 95) |

## Подписка

Поддерживаются plain-text и **base64** подписки. Приоритет источника:

`--subs URL|ФАЙЛ` (разово) > `OCVPN_SUBS_URL` (env) > `~/.ocvpn-subs-url` (файл) >
`/etc/ocvpn/subs-url` (системная) > встроенный публичный fallback.

```bash
# пользовательская
printf '%s\n' 'https://provider.example/sub/TOKEN' > ~/.ocvpn-subs-url && chmod 600 ~/.ocvpn-subs-url
# системная (для сервиса под root)
sudo sh -c 'printf "%s\n" "<URL>" > /etc/ocvpn/subs-url && chmod 600 /etc/ocvpn/subs-url'
```

`--subs` с **файлом** берёт готовый txt с `vless://` без скачивания. Учитываются
ключи `vless`/`vmess`/`trojan`/`ss`/`http(s)`/`socks` типов, которые умеет
преобразовать генератор xray-конфига; неподдерживаемые отфильтровываются.

## Порты

| Порт | Назначение |
|------|------------|
| `10808` | SOCKS5 прокси (localhost) |
| `10809` | HTTP прокси (localhost) |
| `12345` | Прозрачный прокси (iptables REDIRECT) |

SOCKS5/HTTP слушают только `127.0.0.1`. Порт `12345` (dokodemo-door) слушает на всех
интерфейсах, но трафик на него попадает только через iptables REDIRECT.

## Ограничения и заметки

- **Существующие соединения.** `iptables nat OUTPUT` ловит только новые соединения.
  При активации нового ключа ocvpn сам сбрасывает уже открытые сокеты к эндпоинтам
  (`ss -K` / `pfctl -K`, нужен root). Без root — перезапусти opencode.
- **`owner --pid-owner`** — исключение трафика самого xray работает не на всех ядрах
  (iptables-nft). Если не поддержано — пропускается; петли не будет, т.к. REDIRECT
  ловит только эндпоинты из списка.
- **Латентность** — трафик идёт через VPN-сервер, задержка к эндпоинтам растёт.
- **Время жизни ключей** — ключи умирают; если рабочий не найден — запусти ещё раз.
- **Нет IPv6** — принудительный IPv4 через `/etc/hosts`.
- **Коллатеральный трафик** — домен из списка может делить IP с другими сервисами
  (Cloudflare CDN); их трафик тоже пойдёт в туннель.

## Что не трогает

- Nginx/проксируемые сайты (80/443 входящие), SSH (22)
- Приватные подсети (`10/8`, `192.168/16`, `172.16/12`), Docker-сети
- Трафик к провайдерам из «DIRECT» (deepseek, ollama)

## Зависимости

- `curl`, `python3`, `unzip`; Linux: `iptables` (+ `iproute2`/`ss` для сброса
  соединений); macOS: `pfctl`, `dig`
- Root — для iptables/pf, установки xray и сброса соединений `ss -K`
- Linux (iptables REDIRECT) или macOS (pf rdr через якорь)

## Лицензия

MIT
