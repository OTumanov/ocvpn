import Foundation
import Darwin

// Юнит-тесты функций приложения OCVPN (ContentView.swift / MenuBarView.swift).
// Собирается вместе с исходниками (см. tests/swift-run.sh), без SwiftUI-окна.

var PASS = 0
var FAIL = 0
func check(_ name: String, _ cond: Bool) {
    if cond { PASS += 1 } else { FAIL += 1; print("FAIL: \(name)") }
}

let tmp = NSTemporaryDirectory() + "ocvpn-swift-tests-\(getpid())"
try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
// лог-путь приложения читается через static let — задаём env до первого доступа.
setenv("OCVPN_LOG", tmp + "/ocvpn.log", 1)

// --- versionOf ---
let vf = tmp + "/v.sh"
try? "#!/bin/bash\nOCVPN_VERSION=\"9.9.9\"\n".write(toFile: vf, atomically: true, encoding: .utf8)
check("versionOf парсит версию", ContentView.versionOf(vf) == "9.9.9")
check("versionOf нет файла -> пусто", ContentView.versionOf(tmp + "/nope.sh") == "")

// --- firstLine / opError ---
check("firstLine первая непустая", firstLine("a\n\nb\n") == "a")
check("opError с выводом", opError("подключить", "boom\nmore").contains("boom"))
check("opError без вывода", opError("подключить", "").contains("отмена"))

// --- readFirstLine ---
let rf = tmp + "/first.txt"
try? "hello\nworld\n".write(toFile: rf, atomically: true, encoding: .utf8)
check("readFirstLine", readFirstLine(rf) == "hello")

// --- envPrefix ---
setenv("OCVPN_SUBS_URL", "https://example.com/sub", 1)
check("envPrefix с URL", envPrefix().contains("OCVPN_SUBS_URL='https://example.com/sub'"))
unsetenv("OCVPN_SUBS_URL")
check("envPrefix без URL -> пусто", envPrefix().isEmpty)

// --- tcpOpen: живой и мёртвый порт ---
let port = 34567
let listener = Process()
listener.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
listener.arguments = ["-c", """
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", \(port)))
s.listen(1)
time.sleep(5)
"""]
try? listener.run()
usleep(600_000)
check("tcpOpen живой порт", tcpOpen(port: port))
check("tcpOpen мёртвый порт", !tcpOpen(port: 1))
listener.terminate()

// --- tailLog: файл >32КБ с многобайтовыми символами (регресс: пустой лог) ---
setenv("OCVPN_LOG", tmp + "/ocvpn.log", 1)
var big = "A" // один ASCII-байт, чтобы границы символов были на нечётных смещениях
big += String(repeating: "я", count: 20000) // 2 байта на символ -> >32КБ
try? big.write(toFile: tmp + "/ocvpn.log", atomically: true, encoding: .utf8)
let tail = tailLog(50)
check("tailLog не пустой (lossy UTF-8)", !tail.isEmpty)
check("tailLog содержит кириллицу", tail.contains("я"))
check("tailLog убирает ANSI", !tail.contains("\u{1B}["))

// --- команды кнопок ---
setenv("OCVPN_SUBS_URL", "https://s/x", 1)
check("startCommand --daemon", startCommand().contains("--daemon"))
check("startCommand с env-подпиской", startCommand().contains("OCVPN_SUBS_URL="))
check("stopCommand --cleanup", stopCommand().contains("--cleanup"))
check("newIpCommand --new-ip", newIpCommand().contains("--new-ip"))
check("watchCommand вкл --watch", watchCommand(true).contains("--watch"))
check("watchCommand выкл pkill", watchCommand(false).contains("pkill"))
check("subsSystemSaveCommand url", subsSystemSaveCommand("https://x/y").contains("https://x/y"))
check("subsSystemSaveCommand экранирует кавычку", subsSystemSaveCommand("a'b").contains("a'\\''b"))
unsetenv("OCVPN_SUBS_URL")

print("Итог Swift-app: PASS=\(PASS) FAIL=\(FAIL)")
exit(FAIL == 0 ? 0 : 1)
