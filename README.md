# ocvpn

Прозрачная маршрутизация эндпоинтов [opencode](https://opencode.ai) и подключённых провайдеров моделей через VLESS-VPN. Весь остальной трафик хоста не затрагивается.

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
bash ocvpn.sh
```

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
| `bash ocvpn.sh` | Запустить VPN, найти рабочий ключ, настроить маршрутизацию |
| `bash ocvpn.sh --cleanup` | Снять iptables-правила, убрать форсировку IPv4 из `/etc/hosts` |

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
bash ocvpn-tests.sh    # ожидается PASS=5 FAIL=0
```

Покрывает:
- Парсинг всех типов VLESS-конфигов (reality, ws, tls, grpc, xhttp)
- Декодирование URL-encoded параметров (path, sni)
- Xray 26: `xhttpSettings` (host строкой, mode), а не устаревший `httpSettings`
- Логику отбора кандидатов (TCP-пинг, сортировка, отбрасывание мёртвых)
- Фильтр поддерживаемых ключей (`is_supported_key`)
- Индемпотентность `/etc/hosts` (не плодит дубликаты при повторных запусках)
- Парсинг 5 реальных ключей из живой подписки

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

`OCVPN_SUBS_URL` (env) > `~/.ocvpn-subs-url` (файл) > встроенный fallback-список.

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

- `curl`, `python3`, `unzip`, `iptables`
- Рут (для iptables и установки xray)
- Linux (проверено на Ubuntu и в Docker с `NET_ADMIN`)
- Ядро с поддержкой `owner` модуля iptables (рекомендуется; скрипт работает и без, но с небольшой оговоркой — смотрите раздел «Ограничения»)

## Лицензия

MIT
