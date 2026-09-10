#!/usr/bin/env python3
"""OCVPN — macOS GUI: одна кнопка + логи.

Только стандартная библиотека (tkinter). Привилегии для pf//etc/hosts
запрашиваются через штатный диалог macOS (osascript, administrator privileges).
"""
import os
import re
import socket
import subprocess
import sys
import time

os.environ.setdefault("TK_SILENCE_DEPRECATION", "1")
import tkinter as tk
from tkinter import messagebox

APP_NAME = "OCVPN"
VERSION = "1.3.3"

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
        self.geometry("560x480")
        self.resizable(True, True)
        self.backend = find_backend()
        self.log_path = find_log()
        self.busy = False
        _log(
            "start ver=%s os=%s python=%s tk=%s backend=%s"
            % (
                VERSION,
                sys.platform,
                sys.version.split()[0],
                getattr(tk, "TkVersion", "?"),
                self.backend or "NOT-FOUND",
            )
        )
        self.withdraw()
        self._build()
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
        top = tk.Frame(self, bg="#ffffff")
        top.pack(fill=tk.X, padx=12, pady=12)

        self.dot = tk.Canvas(
            top, width=18, height=18, highlightthickness=0, bg="#ffffff"
        )
        self.dot.pack(side=tk.LEFT, padx=(0, 8))
        self.dot_id = self.dot.create_oval(2, 2, 16, 16, fill="#9e9e9e", outline="")

        self.status_var = tk.StringVar(value="Проверка…")
        tk.Label(
            top, textvariable=self.status_var, font=("", 13, "bold"), bg="#ffffff"
        ).pack(side=tk.LEFT)

        self.toggle_btn = tk.Button(
            top, text="Подключить", command=self.on_toggle, width=12
        )
        self.toggle_btn.pack(side=tk.RIGHT)

        mid = tk.Frame(self, bg="#ffffff")
        mid.pack(fill=tk.X, padx=12)
        self.info_var = tk.StringVar(value="")
        tk.Label(mid, textvariable=self.info_var, fg="#616161", bg="#ffffff").pack(
            side=tk.LEFT
        )

        auto = tk.Frame(self, bg="#ffffff")
        auto.pack(fill=tk.X, padx=12, pady=(4, 0))
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
        self.log = tk.Text(log_frame, wrap=tk.WORD, state=tk.DISABLED, height=16)
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
        tk.Label(bot, textvariable=self.hint_var, fg="#9e9e9e", bg="#ffffff").pack(
            side=tk.LEFT
        )

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
        self.after(3000, self._tick)

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

    # --- одна кнопка + авторотация ---
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
        self.after(100, lambda: self._run_auto(want))

    def on_newip(self):
        if self.busy or not self.backend:
            return
        self.busy = True
        self._tick()
        self.after(100, lambda: self._run_action("newip"))

    def _run_auto(self, want):
        try:
            if want:
                cmd = "bash '%s' --daemon --watch" % self.backend
            else:
                cmd = "pkill -f 'ocvpn --watch'"
            r = run_admin(cmd)
            if r.returncode != 0:
                err = (r.stderr or r.stdout or "отмена/ошибка").strip().splitlines()
                self.info_var.set("Ошибка: %s" % (err[0] if err else "?"))
        except Exception as e:
            self.info_var.set("Ошибка: %s" % e)
        finally:
            self.auto_changing = False
            self._tick()

    def _do(self, action):
        if not self.backend:
            self.info_var.set("Не найден backend ocvpn (установите пакет)")
            return
        self.busy = True
        self._tick()
        self.after(100, lambda: self._run_action(action))

    def _run_action(self, action):
        try:
            if action == "start":
                cmd = "bash '%s' --daemon" % self.backend
            elif action == "newip":
                cmd = "bash '%s' --new-ip" % self.backend
            else:
                cmd = "bash '%s' --cleanup" % self.backend
            r = run_admin(cmd)
            if r.returncode != 0:
                err = (r.stderr or r.stdout or "отмена/ошибка").strip().splitlines()
                self.info_var.set("Ошибка: %s" % (err[0] if err else "?"))
        except Exception as e:
            self.info_var.set("Ошибка: %s" % e)
        finally:
            self.busy = False
            self._tick()


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
