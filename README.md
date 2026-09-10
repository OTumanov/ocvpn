# ocvpn

Прозрачная маршрутизация эндпоинтов [opencode](https://opencode.ai) и подключённых провайдеров моделей через VLESS-VPN. Весь остальной трафик хоста не затрагивается.

**v1.3.4:** фикс «ввёл пароль — ничего не происходит»: admin-команды GUI выполняются
в фоновом потоке (окно больше не виснет), каждое действие пишется в лог GUI,
ошибки показываются диалогом; системная подписка `/etc/ocvpn/subs-url`
(backend под root из osascript не видит env терминала и `~` пользователя) +
кнопка «Подписка» в GUI сохраняет URL туда; `install.sh` сохраняет
`OCVPN_SUBS_URL` из окружения установки.
**v1.3.3:** GUI macOS: виджеты переведены на классические `tk.*` — системный Tk 8.5 от Apple не
рисует ttk (белое окно без кнопок), теперь всегда рисуются; лог старта пишется всегда
(`~/Library/Logs/ocvpn-gui.log`); принудительная отрисовка/активация окна; отключён
Tk DEPRECATION warning.
**v1.3.2:** GUI macOS: понятные
диалоги в лаунчере при отсутствии python3/tkinter, лог ошибок `~/Library/Logs/ocvpn-gui.log`.
**v1.3.1:** фикс macOS-инсталлятора (поиск `ocvpn.sh` рядом с `install.sh` — заработал из распакованного архива).
**v1.3.0:** запуск в фоне (`--daemon`, терминал свободен), вотчдог лимитов — сам ловит
IP-лимиты opencode/zen/go в логе opencode и переключается на ключ с **другим**
exit IP, исчерпанные IP уходят в карантин. При подключении **проверяется
доступность моделей opencode из региона**: если все free-модели отдают
геоблок — exit IP в карантин на 12 ч. `--restart` (новый ключ в фоне),
`--new-ip` (сменить IP сейчас), `--subs URL|ФАЙЛ` (разовый источник ключей).
Для macOS есть GUI: одна кнопка + логи + авторотация.

## Зачем

free-тариф opencode лимитирует по IP (без device_id). Смена IP сбрасывает лимиты. Скрипт каждый запуск выбирает случайный рабочий сервер из твоей подписки — новый выходной IP.

## Как работает

1. Скачивает подписку с VLESS-ключами (plain-text и **base64** — V2Board/Marzban)
2. Берёт `BATCH_SIZE` случайных поддерживаемых серверов, параллельно пингует (TCP-connect)
3. `MAX_TRIES` лучших по пингу — кандидаты; пробует реальное подключение через xray (HTTP 204 на `google.com/generate_204`)
4. Первый рабочий ключ → прозрачный прокси (iptables REDIRECT)
5. **Только** трафик к эндпоинтам opencode и провайдеров на порту 443 идёт через VPN
6. Всё остальное на хосте — напрямую

Каждый запуск = новая случайная выборка → новый ключ → новый выходной IP.

## Эндпоинты (v1.18.30)

Список определён анализом исходников `sst/opencode` v1.18.30. Все домены прибиваются в `/etc/hosts` (форсировка IPv4, отключение AAAA) и попадают в цепочку iptables NAT REDIRECT → xray → VPN.

### Инфраструктура OpenCode

| Домен | Назначение |
|---|---|
| `opencode.ai` | console auth (`/console/auth/device/code\|token`), remote-config (`/console/api/config\|user\|orgs`), **Zen API** (`/zen/v1`), **Go API** (`/zen/go/v1`), changelog, config schema |
| `models.opencode.ai` | каталог моделей (`/api.json`, загружается при старте, TTL 5 мин) |
| `api.opencode.ai` | интеграция GitHub App |
| `app.opencode.ai` | upstream веб-UI сервера |
| `opncd.ai` | сервис share (публикация сессий) |

### Провайдеры моделей

Провайдеры определяются из `~/.local/share/opencode/auth.json`. Скрипт туннелирует все настроенные:

| Провайдер | Домен(ы) |
|---|---|
| `opencode` | `opencode.ai` (Zen) |
| `opencode-go` | `opencode.ai` (Go) |
| `deepseek` | `api.deepseek.com` |
| `ollama-cloud` | `ollama.com`, `api.ollama.com` |
| `openrouter` | `openrouter.ai` |
| `zenmux` | `zenmux.ai` |
| OpenAI (OAuth) | `auth.openai.com` |

> Если добавишь нового провайдера (Anthropic, xAI, Groq и т.д.), его домен нужно будет вручную добавить в `OPENCODE_DOMAINS` в начале скрипта.

## Быстрый старт

```bash
git clone git@github.com:OTumanov/ocvpn.git
cd ocvpn
ocvpn --daemon          # в фон, терминал свободен (лог /var/log/ocvpn.log)
ocvpn --daemon --watch  # фон + вотчдог: сам ловит лимиты и ротирует IP
ocvpn --new-ip          # сменить exit IP сейчас
ocvpn --restart         # перезапустить в фоне: новый ключ + (обычно) новый IP
ocvpn --subs https://… # разовый источник ключей (URL подписки или txt с vless://)
```

На macOS — GUI: распаковать `dist/ocvpn-*-macos.tar.gz`, `sudo ./install.sh`,
открыть `/Applications/OCVPN.app`: одна кнопка + логи + чекбокс авторотации.

Скрипт автоматически:
- Установит xray (если не найден) в `~/.local/opt/xray`
- Скачает список ключей
- Найдёт рабочий сервер
- Поднимет прозрачный прокси

**После успешного запуска** — открой новую сессию/вкладку и запусти `opencode`. Маршрутизация работает на уровне ядра (iptables nat), переменные окружения не нужны.

> Важно: скрипт должен быть запущен **до** opencode. `iptables nat OUTPUT` перехватывает только новые TCP-соединения. Если opencode уже запущен до скрипта — его существующие соединения останутся прямыми.

## Команды

| Команда | Описание |
|---------|----------|
| `ocvpn` | Запустить VPN в foreground (Ctrl-C = стоп + cleanup) |
| `ocvpn --daemon [--watch]` | Запустить в фоне, терминал свободен (лог `/var/log/ocvpn.log`) |
| `ocvpn --watch` | Вотчдог: следит за логом opencode, ловит IP-лимиты, дёргает `--rotate` |
| `ocvpn --new-ip` | Сменить exit IP сейчас (сигнал держателю) |
| `ocvpn --rotate [why]` | То же, что `--new-ip` (алиас) |
| `ocvpn --restart` | Перезапустить в фоне: прибить держателя, поднять новый ключ + (обычно) новый IP |
| `ocvpn --status` | Состояние: xray, порты, маршруты, ключ, exit IP, карантин, вотчдог |
| `ocvpn --cleanup` | Снять iptables/pf-правила, убрать форсировку IPv4 из `/etc/hosts` |

`--subs URL|ФАЙЛ` можно передать в любом месте командной строки — это разовый
источник ключей для запуска/рестарта: URL подписки или готовый txt с `vless://`
(например `ocvpn --subs https://provider/sub --restart`). Постоянный источник —
`OCVPN_SUBS_URL`/`~/.ocvpn-subs-url` (см. «Подписка»).

## Вотчдог лимитов и ротация

Free-tier opencode/zen/go лимитируется **по IP**: смена выходного IP сбрасывает лимит.
Вотчдог (`ocvpn --watch`, обычно вместе с `--daemon`) хвостом читает лог opencode
(`~/.local/share/opencode/log/opencode.log`) и при строках вида:

- `AI_APICallError: Rate limit exceeded. Please try again later.`
- `Error from provider (Console): Rate limit exceeded…`
- `… usage limit reached. It will reset in N minutes/hours …`
- `Too many requests` / `429` от zen

шлёт держателю сигнал — тот кладёт исчерпанный IP в карантин и поднимает ключ
с **другим** exit IP. Старый ключ гасится только после проверки нового — обрыва нет.
Новый opencode-переподключать не надо: `iptables nat OUTPUT` / `pf rdr` ловят только
новые соединения, следующие запросы сами уйдут через новый IP (in-flight запрос упадёт).

**Не триггерят** (смена IP не поможет, ollama вообще игнорируется):

- `ollama.com/upgrade`, `ollama.com/settings` — лимиты аккаунта ollama
- `Insufficient balance`, `/billing` — деньги, а не IP
- `not available in your country` — геоблок
- `Forbidden`, `Model is disabled`, `Cannot connect`, `Task cancelled`

Защита от флэппинга: cooldown 600 сек (`OCVPN_ROTATE_COOLDOWN`) + максимум 6 ротаций
в час (`OCVPN_ROTATE_MAX_PER_HOUR`).

## Geo-check: доступность моделей из региона

При каждом подключении/ротации проверяется, что из текущего exit IP **действительно
доступны модели opencode** (геоблок детектится не по IP-гео, а по ответу API).
`check_model_available()` пробует 5 free-моделей через `api.opencode.ai`
(SOCKS-прокси ropического ключа):

- HTTP **200/201/429** — модель отвечает → регион рабочий → подключение принято
- HTTP **403/451** (или geo-паттерн в ответе) — геоблок модели
- **500/timeout** — трактуется как «неизвестно», не карантинится (не хочется
  убивать рабочие IP из-за шума сети)

Если **все** free-модели вернули геоблок — exit IP бесполезен: ключ уходит в
карантин на **12 часов** (`geo-block: модели не доступны из региона`),
подключение отменяется и пробуется следующий кандидат. Достаточно одной
доступной модели, чтобы IP приняли за рабочий.

## Карантин

Исчерпанный сервер (`host:port`) и его exit IP помечаются и не выбираются до истечения
срока. Сколько часов — по хинту из строки лимита (`reset in N minutes/hours/days`,
проверено по исходникам opencode: фиксированного N там нет, сервер присылает
динамический reset через `x-ratelimit-reset`/`retry-after`, клиент показывает
«Usage limit reached. It will reset in …»). Нет хинта — дефолт 6 часов
(`OCVPN_QUARANTINE_HOURS`), потолок 168. Гео-заблокированные IP (все free-модели
недоступны) карантинятся на **12 часов** с reason `geo-block: модели не доступны
из региона`. Хранилище: `~/.local/share/ocvpn/quarantine.tsv`.

## Проверка, что VPN работает

```bash
# 1. Exit IP через SOCKS5 прокси (должен отличаться от прямого)
curl -s https://ipinfo.io/ip                            # IP хоста
curl -s --proxy socks5h://127.0.0.1:10808 https://ipinfo.io/ip   # IP через VPN

# 2. Проверить, что конкретный эндпоинт идёт через туннель
#    (счётчик в iptables растёт)
iptables -t nat -L OPENCODE_VPN -n -v | grep 172.65.90.20  # opencode.ai
curl -s -o /dev/null https://opencode.ai/ && iptables -t nat -L OPENCODE_VPN -n -v | grep 172.65.90.20

# 3. Проверить, что opencode видит туннель (ss покажет соединение opencode → IP в списке)
ss -tnp | grep opencode
# Должно быть: opencode → 172.65.90.20:443 (opencode.ai) или 3.173.21.63:443 (deepseek)
```

## Тесты

```bash
bash ocvpn-tests.sh    # ожидается PASS=59 FAIL=0
```

 Покрывает:
- Парсинг всех типов VLESS-конфигов (reality, ws, tls, grpc, xhttp)
- Декодирование URL-encoded параметров (path, sni)
- Xray 26: `xhttpSettings` (host строкой, mode), а не устаревший `httpSettings`
- Логику отбора кандидатов (TCP-пинг, сортировка, отбрасывание мёртвых)
- Фильтр поддерживаемых ключей (`is_supported_key`)
- Индемпотентность `/etc/hosts` (не плодит дубликаты при повторных запусках)
- Парсинг 5 реальных ключей из живой подписки
- CLI (`--help/--version/--status`) и macOS-ветку (резолв, pf-якорь, диспетчер — на стабах)
- Вотчдог: 15 +/-кейсов лимитов (zen/console — да; ollama/биллинг/гео/сеть — нет)
- Парсинг `reset in N` → часы карантина (мин/часы/дни, дефолт, потолок 168)
- Карантин: блок host:port и exit IP, expiry, count
- Регрессия EXIT-trap: `--help/--version/--status` не пишут в iptables и не трогают `/etc/hosts`
- `--new-ip` без держателя: чистая ошибка без побочек; `--help` анонсирует новые флаги
- `parse_subs_flag`: файл / http(s)-URL / флаг после команды / мусор / пусто
- `download_subscription`: с vless-ключами / нет файла / нет vless
- Geo-check: наличие `check_model_available`/`FREE_MODELS`/`GEO_BLOCK_PATTERNS`,
  карантин geo-заблокированного IP, пустой `auth.json` → пропуск проверки

## Установка пакетами

```bash
make deb        # dist/ocvpn-1.3.2-all.deb  (Debian/Ubuntu, systemd-юнит ocvpn.service)
make macos-tar  # dist/ocvpn-1.3.2-macos.tar.gz (macOS: ocvpn + OCVPN.app + LaunchDaemon)
```

Debian: `sudo dpkg -i dist/ocvpn-*.deb` (сервис включается, но не стартует сам —
старт: `systemctl start ocvpn`). macOS: распаковать архив, `sudo ./install.sh`;
`.pkg` собирается на самом Mac: `bash packaging/macos/build-pkg.sh`.
Нативный SwiftUI-GUI: `bash gui-swift/build.sh` (только на Mac).

## Конфигурация

Параметры в начале скрипта:

```bash
BATCH_SIZE=10    # сколько случайных ключей пинговать
MAX_TRIES=5      # сколько лучших кандидатов пробовать
PING_TIMEOUT=3   # таймаут TCP-пинга (сек)
TIMEOUT=5        # таймаут теста generate_204 (сек)
```

### Список эндпоинтов

Если нужно добавить/убрать домены — редактируй массив `OPENCODE_DOMAINS` в начале скрипта:

```bash
OPENCODE_DOMAINS=(
    # --- Инфраструктура OpenCode ---
    "opencode.ai"
    "api.opencode.ai"
    "models.opencode.ai"
    "app.opencode.ai"
    "opncd.ai"
    # --- Провайдеры моделей ---
    "api.deepseek.com"
    "ollama.com"
    "api.ollama.com"
    "openrouter.ai"
    "zenmux.ai"
    "auth.openai.com"
)
```

При добавлении домена скрипт автоматически:
- Добавит IPv4-запись в `/etc/hosts` (форсировка IPv4)
- Зарезолвит IP и добавит iptables REDIRECT правило
- При `--cleanup` всё удалит

## Подписка

Поддерживаются plain-text и **base64** подписки (V2Board/Marzban). Приоритет URL:

`--subs URL|ФАЙЛ` (разово, из командной строки) > `OCVPN_SUBS_URL` (env) >
`~/.ocvpn-subs-url` (файл) > встроенный fallback-список.

`--subs` с **файлом** берёт готовый txt с `vless://` без скачивания — удобно
тестировать конкретную подписку.

```bash
printf '%s\n' 'https://provider.example/sub/TOKEN' > ~/.ocvpn-subs-url
chmod 600 ~/.ocvpn-subs-url
```

Учитываются только ключи `vless://` типов `tcp`(raw)/`ws`/`grpc`/`xhttp`, которые умеет генерить xray-конфиг скрипта. Типы, которые xray не потянет (например sing-box xhttp packet-up с `extra=`), отфильтровываются.

## Порты

| Порт | Назначение |
|------|------------|
| `10808` | SOCKS5 прокси (localhost) |
| `10809` | HTTP прокси (localhost) |
| `12345` | Прозрачный прокси (iptables REDIRECT) |

SOCKS5 и HTTP прокси слушают только на `127.0.0.1` — наружу не публикуются. Прозрачный порт `12345` (dokodemo-door) слушает на всех интерфейсах, но трафик на него попадает только через iptables REDIRECT.

## Ограничения и заметки

- **Существующие соединения** — `iptables nat OUTPUT` перехватывает только новые TCP-соединения. Если opencode запущен до скрипта — его активные соединения останутся прямыми. Перезапусти opencode после скрипта.
- **`owner --pid-owner`** — исключение трафика самого xray работает не на всех ядрах (iptables-nft). Если не поддержан — пропускается. Петли не будет, т.к. REDIRECT ловит только эндпоинты из списка, а xray ходит на IP VPN-сервера.
- **Латентность** — трафик идёт через VPN-сервер (Россия/Казахстан и т.д.), задержка к эндпоинтам opencode увеличивается. Для проверки👃 это обычно не критично.
- **Время жизни ключей** — ключи могут умирать. Если скрипт не находит рабочий — просто запусти ещё раз (выборка случайная).
- **Нет IPv6** — скрипт принудительно форсирует IPv4 через `/etc/hosts`. Если на хосте есть глобальный IPv6 — трафик пойдёт через IPv4-записи из `/etc/hosts`.
- **Коллатеральный трафик** — если домен из списка разделяет IP с другими сервисами (Cloudflare CDN), их трафик тоже попадёт в туннель. Обычно это не критично.

## Что не трогает

- Nginx / проксируемые сайты (80, 443 входящие)
- SSH (22)
- Приватные подсети (10.0.0.0/8, 192.168.0.0/16, 172.16.0.0/12)
- Docker-сети
- Существующие TCP-соединения (iptables nat OUTPUT работает только на новые)

## Зависимости

- `curl`, `python3`, `unzip` + `iptables` (Linux) / `pfctl`, `dig` (macOS)
- Рут (для iptables/pf и установки xray)
- Linux (iptables REDIRECT) или macOS (pf rdr через якорь `com.otumanov.ocvpn`)
- Ядро с поддержкой `owner` модуля iptables (рекомендуется; скрипт работает и без, но с небольшой оговоркой — смотрите раздел «Ограничения»)

## Лицензия

MIT
