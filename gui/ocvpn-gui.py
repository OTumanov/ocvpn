#!/usr/bin/env python3
"""OCVPN — macOS GUI: одна кнопка + логи.

Только стандартная библиотека (tkinter). Привилегии для pf//etc/hosts
запрашиваются через штатный диалог macOS (osascript, administrator privileges).
"""
import os
import queue
import re
import socket
import subprocess
import sys
import threading
import time

os.environ.setdefault("TK_SILENCE_DEPRECATION", "1")
import tkinter as tk
from tkinter import messagebox

APP_NAME = "OCVPN"
VERSION = "1.4.0"

STATE_DIR = os.environ.get(
    "OCVPN_STATE_DIR", os.path.expanduser("~/.local/share/ocvpn")
)
WATCH_PIDFILE = os.path.join(STATE_DIR, "watch.pid")

ERROR_LOG = os.path.join(
    os.path.expanduser("~/Library/Logs/ocvpn-gui.log")
    if sys.platform == "darwin"
    else os.path.expanduser("~/.ocvpn-gui.log")
)


def _log(msg):
    """Всегда пишем старт/ошибки в ERROR_LOG — чтобы пустое окно было диагностируемо."""
    try:
        with open(ERROR_LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except Exception:
        pass


def _log_error(exc):
    _log(exc)

CANDIDATE_BINS = [
    "/usr/local/bin/ocvpn",
    "/opt/ocvpn/bin/ocvpn",
    os.path.expanduser("~/.local/bin/ocvpn"),
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ocvpn.sh"),
]

SOCKS_PORT = 10808
LOG_FILES = [
    os.environ.get("OCVPN_LOG", ""),
    "/var/log/ocvpn.log",
    os.path.expanduser("~/.ocvpn.log"),
]
SYS_SUBS_FILE = "/etc/ocvpn/subs-url"
USER_SUBS_FILE = os.path.expanduser("~/.ocvpn-subs-url")


def _read_first_line(path):
    try:
        with open(path) as f:
            return f.readline().strip()
    except Exception:
        return ""


def subs_status():
    """Какой источник ключей увидит ROOT-backend (osascript). Возвращает (ok, текст).
    ok=True только если подписку увидит и root: env самого GUI root не видит."""
    if _read_first_line(USER_SUBS_FILE):
        return True, "подписка: ~/.ocvpn-subs-url"
    if os.path.exists(SYS_SUBS_FILE):
        if _read_first_line(SYS_SUBS_FILE):
            return True, "подписка: системная /etc/ocvpn/subs-url"
        return True, "подписка: системная (есть, содержимое скрыто)"
    if os.environ.get("OCVPN_SUBS_URL", "").strip():
        return False, "подписка: только env GUI (root её НЕ видит!) — нажми «Подписка»"
    return False, "подписки НЕТ — будет чужой публичный fallback"


def _env_prefix():
    """Если GUI запущен из терминала с OCVPN_SUBS_URL — пробросить её явно
    в admin-команду (env GUI до root через osascript не доходит)."""
    url = os.environ.get("OCVPN_SUBS_URL", "").strip()
    if url:
        return "OCVPN_SUBS_URL=%s " % _shq(url)
    return ""


def _shq(s):
    """Экранировать строку для sh внутри одинарных кавычек."""
    return "'" + s.replace("'", "'\\''") + "'"


def find_backend():
    for p in CANDIDATE_BINS:
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
        if p and p.endswith(".sh") and os.path.isfile(p):
            return p
    return None


def find_log():
    for p in LOG_FILES:
        if p and os.path.isfile(p):
            return p
    return LOG_FILES[1]


def watch_alive():
    try:
        with open(WATCH_PIDFILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return pid
    except Exception:
        return None


def last_rotation(log_path):
    if not log_path or not os.path.isfile(log_path):
        return ""
    try:
        with open(log_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 65536))
            data = f.read().decode("utf-8", "replace")
        data = re.sub(r"\x1b\[[0-9;]*m", "", data)
        for line in reversed(data.splitlines()):
            if "РОТАЦИЯ:" in line:
                return line.strip()[-120:]
        return ""
    except Exception:
        return ""


def port_open(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.5)
    try:
        s.connect(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def run_admin(cmd):
    """Выполнить команду с правами администратора (macOS-диалог)."""
    if sys.platform == "darwin":
        script = 'do shell script %s with administrator privileges' % (
            '"%s"' % cmd.replace('"', '\\"'),
        )
        return subprocess.run(
            ["osascript", "-e", script], capture_output=True, text=True, timeout=180
        )
    # Linux-запасной вариант (для разработки)
    return subprocess.run(
        ["sudo", "-n", "bash", "-c", cmd], capture_output=True, text=True, timeout=180
    )


def run_plain(args, timeout=15):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("%s %s" % (APP_NAME, VERSION))
        self.geometry("580x660")
        self.minsize(520, 500)
        self.resizable(True, True)
        self.backend = find_backend()
        self.log_path = find_log()
        self.busy = False
        _log(
            "start ver=%s os=%s python=%s tk=%s backend=%s subs=%s"
            % (
                VERSION,
                sys.platform,
                sys.version.split()[0],
                getattr(tk, "TkVersion", "?"),
                self.backend or "NOT-FOUND",
                subs_status()[1],
            )
        )
        self.withdraw()
        self._build()
        # Очередь результатов фоновых admin-команд. На Tk 8.5 из потока НЕЛЬЗЯ
        # вызывать self.after() («main thread is not in main loop»), поэтому
        # поток только кладёт результат в очередь, а главный поток забирает её
        # в _tick (каждые 3 с) + по событию <<OcvpnAdminDone>> (event_generate
        # потокобезопасен).
        self._admin_queue = queue.Queue()
        self.bind("<<OcvpnAdminDone>>", self._on_admin_event)
        self._reveal()
        self._tick()

    def _reveal(self):
        """Показать окно и дать Tk отрисоваться (принудительно)."""
        try:
            self.deiconify()
            self.update_idletasks()
            self.update()
            self.lift()
            self.focus_force()
        except Exception as e:
            _log("reveal: %s" % e)

    def _build(self):
        # Секция «Состояние»: индикатор + подпись + главная кнопка.
        state = tk.LabelFrame(
            self, text="Состояние", padx=8, pady=8, bg="#ffffff", fg="#424242"
        )
        state.pack(fill=tk.X, padx=12, pady=(12, 0))
        head = tk.Frame(state, bg="#ffffff")
        head.pack(fill=tk.X)
        self.dot = tk.Canvas(
            head, width=18, height=18, highlightthickness=0, bg="#ffffff"
        )
        self.dot.pack(side=tk.LEFT, padx=(0, 8))
        self.dot_id = self.dot.create_oval(2, 2, 16, 16, fill="#9e9e9e", outline="")

        self.status_var = tk.StringVar(value="Проверка…")
        tk.Label(
            head, textvariable=self.status_var, font=("", 13, "bold"), bg="#ffffff"
        ).pack(side=tk.LEFT)

        self.toggle_btn = tk.Button(
            head, text="Подключить", command=self.on_toggle, width=14
        )
        self.toggle_btn.pack(side=tk.RIGHT)

        self.info_var = tk.StringVar(value="")
        tk.Label(
            state,
            textvariable=self.info_var,
            fg="#616161",
            bg="#ffffff",
            anchor=tk.W,
            justify=tk.LEFT,
            wraplength=520,
        ).pack(fill=tk.X, pady=(4, 0))

        # Секция «Подписка»: видимое поле ввода + Сохранить (инлайн, без popup).
        subs = tk.LabelFrame(
            self, text="Подписка", padx=8, pady=8, bg="#ffffff", fg="#424242"
        )
        subs.pack(fill=tk.X, padx=12, pady=(8, 0))
        row = tk.Frame(subs, bg="#ffffff")
        row.pack(fill=tk.X)
        self.subs_entry_var = tk.StringVar(value="")
        self.subs_entry = tk.Entry(row, textvariable=self.subs_entry_var, width=44)
        self.subs_entry.pack(side=tk.LEFT, fill=tk.X, expand=True)
        tk.Button(row, text="Сохранить", command=self.on_subs_save, width=10).pack(
            side=tk.LEFT, padx=(6, 0)
        )
        self.subs_var = tk.StringVar(value="")
        self.subs_label = tk.Label(
            subs,
            textvariable=self.subs_var,
            fg="#9e9e9e",
            bg="#ffffff",
            anchor=tk.W,
            justify=tk.LEFT,
            wraplength=520,
        )
        self.subs_label.pack(fill=tk.X, pady=(4, 0))
        self._refresh_subs(prefill=True)

        auto = tk.Frame(self, bg="#ffffff")
        auto.pack(fill=tk.X, padx=12, pady=(8, 0))
        self.auto_var = tk.BooleanVar(value=False)
        self.auto_changing = False
        self.auto_box = tk.Checkbutton(
            auto,
            text="Авторотация при лимитах (вотчдог)",
            variable=self.auto_var,
            command=self.on_auto,
            bg="#ffffff",
            anchor=tk.W,
        )
        self.auto_box.pack(side=tk.LEFT)
        self.watch_var = tk.StringVar(value="")
        tk.Label(
            auto, textvariable=self.watch_var, fg="#9e9e9e", bg="#ffffff"
        ).pack(side=tk.LEFT, padx=(8, 0))

        log_frame = tk.LabelFrame(
            self, text="Логи", padx=6, pady=6, bg="#ffffff", fg="#424242"
        )
        log_frame.pack(fill=tk.BOTH, expand=True, padx=12, pady=8)
        self.log = tk.Text(log_frame, wrap=tk.WORD, state=tk.DISABLED, height=14)
        scroll = tk.Scrollbar(log_frame, orient=tk.VERTICAL, command=self.log.yview)
        self.log.configure(yscrollcommand=scroll.set)
        self.log.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scroll.pack(side=tk.RIGHT, fill=tk.Y)

        bot = tk.Frame(self, bg="#ffffff")
        bot.pack(fill=tk.X, padx=12, pady=(0, 12))
        tk.Button(bot, text="Обновить", command=self._tick).pack(side=tk.RIGHT)
        tk.Button(bot, text="Новый IP", command=self.on_newip).pack(
            side=tk.RIGHT, padx=(0, 6)
        )
        self.hint_var = tk.StringVar(
            value="Лог: %s" % self.log_path if self.log_path else ""
        )
        tk.Label(
            bot,
            textvariable=self.hint_var,
            fg="#9e9e9e",
            bg="#ffffff",
            anchor=tk.W,
            justify=tk.LEFT,
            wraplength=380,
        ).pack(side=tk.LEFT)

    # --- состояние ---
    def query_state(self):
        """('on'|'off'|'busy', detail). Только чтение, без привилегий."""
        if self.busy:
            return "busy", "выполняется операция…"
        if self.backend and self.backend.endswith(".sh"):
            pass
        if port_open(SOCKS_PORT):
            return "on", "SOCKS 127.0.0.1:%d отвечает" % SOCKS_PORT
        if self.backend:
            try:
                r = run_plain(["bash", self.backend, "--status"])
                if r.returncode == 0:
                    return "on", "все проверки --status в норме"
            except Exception:
                pass
        return "off", "прокси не отвечает"

    def _tick(self):
        try:
            self._drain_admin_queue()
            state, detail = self.query_state()
            colors = {"on": "#2e7d32", "off": "#9e9e9e", "busy": "#ff6600"}
            labels = {
                "on": "Подключено",
                "off": "Отключено",
                "busy": "Работаю…",
            }
            self.dot.itemconfig(self.dot_id, fill=colors[state])
            self.status_var.set(labels[state])
            rot = last_rotation(self.log_path)
            self.info_var.set(detail + (" | " + rot if rot else ""))
            self.toggle_btn.configure(
                text="Отключить" if state == "on" else "Подключить",
                state=tk.DISABLED if state == "busy" else tk.NORMAL,
            )
            if not self.auto_changing:
                wpid = watch_alive()
                self.auto_var.set(wpid is not None)
                self.watch_var.set(
                    "вотчдог: pid %d" % wpid if wpid else "вотчдог выключен"
                )
            self._load_log()
        except tk.TclError:
            # Окно уже закрыто (гонка after-колбэка с destroy) — молча уходим.
            return
        try:
            self.after(3000, self._tick)
        except tk.TclError:
            pass

    def _drain_admin_queue(self):
        """Забрать готовые результаты фоновых команд (только главный поток)."""
        while True:
            try:
                done, ok, msg = self._admin_queue.get_nowait()
            except queue.Empty:
                return
            self.busy = False
            try:
                done(ok, msg)
            except tk.TclError:
                return
            except Exception as e:
                _log("admin done: %s" % e)

    def _on_admin_event(self, _evt=None):
        try:
            self._drain_admin_queue()
            self._tick()
        except tk.TclError:
            pass

    def _load_log(self):
        path = self.log_path
        if not path or not os.path.isfile(path):
            return
        try:
            with open(path, "rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - 32768))
                data = f.read().decode("utf-8", "replace")
            # убрать ANSI-цвета
            data = re.sub(r"\x1b\[[0-9;]*m", "", data)
            lines = data.splitlines()[-120:]
            self.log.configure(state=tk.NORMAL)
            self.log.delete("1.0", tk.END)
            self.log.insert(tk.END, "\n".join(lines) + "\n")
            self.log.see(tk.END)
            self.log.configure(state=tk.DISABLED)
        except Exception as e:
            self.hint_var.set("Не читается лог: %s" % e)

    # --- одна кнопка + авторотация (всё тяжёлое — в фоновых потоках,
    # --- иначе окно виснет на время --daemon/--new-ip) ---
    def _refresh_subs(self, prefill=False):
        ok, text = subs_status()
        self.subs_var.set(text)
        try:
            self.subs_label.configure(fg="#2e7d32" if ok else "#c62828")
        except Exception:
            pass
        if prefill:
            try:
                cur = (
                    os.environ.get("OCVPN_SUBS_URL", "").strip()
                    or _read_first_line(USER_SUBS_FILE)
                    or ""
                )
                self.subs_entry_var.set(cur)
            except Exception:
                pass
        return ok

    def on_subs_save(self):
        """Сохранить URL из поля ввода: сразу в ~/.ocvpn-subs-url (без пароля)
        + системно в /etc/ocvpn/subs-url (через admin — видно и root/daemon)."""
        url = self.subs_entry_var.get().strip()
        if not url:
            self._show_error(
                "Подписка", "Поле пустое — вставь URL подписки (https://…) и нажми «Сохранить»."
            )
            return
        if not url.startswith("http"):
            self._show_error(
                "Подписка", "Похоже, это не URL подписки: должно начинаться с https://"
            )
            return
        try:
            with open(USER_SUBS_FILE, "w") as f:
                f.write(url + "\n")
            _log("subs: saved %s" % USER_SUBS_FILE)
        except Exception as e:
            self._show_error("Подписка", "Не записать %s: %s" % (USER_SUBS_FILE, e))
            return
        cmd = (
            "mkdir -p /etc/ocvpn && printf '%%s' %s > /etc/ocvpn/subs-url"
            " && chmod 600 /etc/ocvpn/subs-url && echo SAVED" % _shq(url)
        )
        self._do_admin_async(
            cmd, "подписка", lambda ok, msg: self._finish_subs_save(ok, msg, url)
        )

    def _finish_subs_save(self, ok, msg, url):
        if not ok:
            self._show_error(
                "Подписка",
                "В ~/.ocvpn-subs-url сохранено, а системно — нет (%s). "
                "Кнопки GUI (от root) будут без подписки." % msg,
            )
        else:
            self.info_var.set("Подписка сохранена (файл + системно).")
            _log("subs: saved /etc/ocvpn/subs-url")
        try:
            self.subs_entry_var.set(url)
        except Exception:
            pass
        self._refresh_subs()

    def on_toggle(self):
        if self.busy:
            return
        state, _ = self.query_state()
        if state == "on":
            self._do("stop")
        else:
            self._do("start")

    def on_auto(self):
        if self.auto_changing or not self.backend:
            return
        self.auto_changing = True
        want = self.auto_var.get()
        if want:
            cmd = _env_prefix() + "bash '%s' --daemon --watch" % self.backend
        else:
            cmd = "pkill -f 'ocvpn --watch'"
        self._do_admin_async(
            cmd, "вотчдог", lambda ok, msg: self._finish_auto(ok, msg)
        )

    def _finish_auto(self, ok, msg):
        self.auto_changing = False
        if not ok:
            self._show_error("Вотчдог", msg)
        self._tick()

    def on_newip(self):
        if self.busy or not self.backend:
            return
        self._do("newip")

    def _do(self, action):
        if not self.backend:
            self._show_error("OCVPN", "Не найден backend ocvpn (установите пакет)")
            return
        if action == "start":
            cmd = _env_prefix() + "bash '%s' --daemon" % self.backend
        elif action == "newip":
            cmd = _env_prefix() + "bash '%s' --new-ip" % self.backend
        else:
            cmd = "bash '%s' --cleanup" % self.backend
        self._do_admin_async(cmd, action, lambda ok, msg: self._finish_action(ok, msg))

    def _finish_action(self, ok, msg):
        if not ok:
            self._show_error("OCVPN", msg)
        self._tick()

    def _show_error(self, title, msg):
        _log("%s: %s" % (title, msg))
        self.info_var.set("Ошибка: %s" % msg)
        try:
            messagebox.showerror(title, "%s\n\nПодробности: %s" % (msg, ERROR_LOG))
        except Exception:
            pass

    def _do_admin_async(self, cmd, label, done):
        """Выполнить admin-команду в фоне (GUI не виснет). done(ok, msg)
        вызывается в главном потоке Tk через очередь (на Tk 8.5 из потока
        нельзя вызывать даже self.after — только event_generate)."""
        if self.busy:
            return
        self.busy = True
        try:
            self._tick()
        except tk.TclError:
            self.busy = False
            return

        def worker():
            try:
                _log("action %s: %s" % (label, cmd[:200]))
                r = run_admin(cmd)
                out = ((r.stderr or "") + "\n" + (r.stdout or "")).strip()
                tail = "\n".join(out.splitlines()[-5:]) if out else ""
                _log("action %s: rc=%s tail=%r" % (label, r.returncode, tail[-300:]))
                if r.returncode != 0:
                    msg = tail.splitlines()[0] if tail else "отмена/ошибка"
                    self._admin_queue.put((done, False, msg))
                else:
                    self._admin_queue.put((done, True, tail))
            except Exception as e:
                _log("action %s: EXC %s" % (label, e))
                try:
                    self._admin_queue.put((done, False, str(e)))
                except Exception:
                    pass
            # Сигнал главному потоку (потокобезопасно). Если не сработает —
            # результат всё равно подберёт _tick в ближайший цикл (3 с).
            try:
                self.event_generate("<<OcvpnAdminDone>>", when="tail")
            except Exception as e:
                _log("event_generate: %s" % e)

        threading.Thread(target=worker, daemon=True).start()


if __name__ == "__main__":
    try:
        App().mainloop()
    except Exception as e:
        _log_error("startup: %s" % e)
        try:
            messagebox.showerror(
                "OCVPN: ошибка запуска",
                "Не удалось запустить GUI:\n%s\n\nПодробности: %s" % (e, ERROR_LOG),
            )
        except Exception:
            pass
        sys.exit(1)
