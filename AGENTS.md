# AGENTS.md — как агенту установить ocvpn

Этот репозиторий — **ocvpn**: прозрачный VPN, который заворачивает через туннель
ТОЛЬКО трафик к эндпоинтам opencode и провайдеров моделей (opencode.ai,
openrouter.ai, chatgpt/openai, gemini, grok, …). Остальной хост не трогается.

Если пользователь просит «поставить ocvpn», «сделать VPN для opencode» или
«настроить обход», действуй по этому файлу. Репозиторий:
`https://github.com/OTumanov/ocvpn`.

## 0. Сначала проверь окружение (не запускай интерактивный sudo!)
```sh
uname -s                 # Linux | Darwin
id -u                    # 0 = root
command -v systemctl
command -v opencode      # opencode уже стоит?
```
Правило прав: если `id -u` = 0 — работай напрямую; иначе проверь `sudo -n true`
(passwordless). Если и того нет — выполни только read-only команды и передай
пользователю инструкции, интерактивный `sudo` не вызывай (зависнет).

## 1. Установка

### Linux (Debian/Ubuntu, systemd)
```sh
sudo dpkg -i dist/ocvpn-*-all.deb      # или собери: bash packaging/debian/build.sh
sudo systemctl enable --now ocvpn      # запустить сервис
```
`postinst` сам:
- включит сервис (но не стартует, чтобы не конфликтовать с ручным запуском);
- поставит команду `/ocvpn` в конфиг opencode;
- предложит установить opencode, если его нет.

### macOS
```sh
sudo bash packaging/macos/install.sh
```
Скрипт ставит CLI `/usr/local/bin/ocvpn`, GUI `/Applications/OCVPN.app`, plist и
команду `/ocvpn` в opencode.

### Из исходников без пакета
```sh
sudo cp ocvpn.sh /usr/local/bin/ocvpn && sudo chmod 755 /usr/local/bin/ocvpn
sudo ocvpn --install-opencode-command
sudo ocvpn --ensure-opencode auto
```

## 2. Подписка (иначе публичный fallback — чужой)
```sh
# пользовательская:
printf '%s\n' '<URL-подписки>' > ~/.ocvpn-subs-url
# системная (для сервиса под root):
sudo sh -c 'printf "%s\n" "<URL-подписки>" > /etc/ocvpn/subs-url && chmod 600 /etc/ocvpn/subs-url'
```

## 3. Запуск и проверка
```sh
sudo systemctl start ocvpn          # Linux
ocvpn --status                      # состояние, exit IP, источник подписки
ocvpn --hosts                       # список доменов, идущих через VPN
```
Критерий успеха: `ocvpn --status` показывает живой xray и exit IP; трафик к
эндпоинтам opencode идёт через VPN, остальной хост не затронут.

## 4. Команда `/ocvpn` в opencode
После установки в opencode доступна команда `/ocvpn` (меню): статус, смена IP,
подписка, свои хосты (`--add-host`/`--rm-host`/`--hosts`), старт/стоп, очистка.
Она лежит в `~/.config/opencode/commands/ocvpn.md`.

## 5. Частые команды
```sh
ocvpn                      # foreground: поднять VPN (Ctrl-C — стоп)
ocvpn --daemon             # в фоне (лог: $HOME/.local/share/ocvpn/ocvpn.log)
ocvpn --new-ip             # сменить exit IP
ocvpn --add-host DOMAIN    # завести свой домен через VPN (сразу, если активно)
ocvpn --rm-host DOMAIN     # убрать домен
ocvpn --hosts              # список доменов
ocvpn --cleanup            # снять маршруты и записи /etc/hosts
```

## 6. Важно
- Не вызывай интерактивный `sudo` — только `sudo -n` после проверки прав.
- Тесты: `bash ocvpn-tests.sh` и `bash tests/coverage.sh` (порог покрытия 95%).
- При смене IP на живом opencode без root соединения не переоткрываются —
  попроси пользователя перезапустить opencode (закрыть и открыть).
