import SwiftUI
import Darwin

/// OCVPN — одна кнопка + логи.
/// Привилегии для pf//etc/hosts запрашиваются штатным диалогом macOS.
struct ContentView: View {
    @State private var connected = false
    @State private var busy = false
    @State private var detail = "Проверка…"
    @State private var logs = ""
    @State private var autoRotate = false
    @State private var watchDetail = ""
    @State private var timer: Timer?

    static let backend = "/usr/local/bin/ocvpn"
    static let logPath =
        ProcessInfo.processInfo.environment["OCVPN_LOG"] ?? "/var/log/ocvpn.log"
    static let socksPort = 10808

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(busy ? .orange : (connected ? .green : .gray))
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading) {
                    Text(connected ? "Подключено" : "Отключено")
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(connected ? "Отключить" : "Подключить") {
                    toggle()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy)
            }
            Toggle("Авторотация при лимитах", isOn: $autoRotate)
                .onChange(of: autoRotate) { want in
                    toggleWatch(want)
                }
            Text(watchDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Логи")
                .font(.headline)
            ScrollView {
                Text(logs.isEmpty ? "—" : logs)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            HStack {
                Text("Лог: \(Self.logPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Обновить") { refresh() }
            }
        }
        .padding()
        .onAppear { refresh(); startTimer() }
        .onDisappear { timer?.invalidate() }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            refresh()
        }
    }

    private func refresh() {
        if !busy {
            let st = queryState()
            connected = st.on
            detail = st.detail
            if let pid = watchPid() {
                autoRotate = true
                watchDetail = "вотчдог: pid \(pid)"
            } else {
                autoRotate = false
                watchDetail = "вотчдог выключен"
            }
        }
        logs = tailLog(120)
    }

    private func toggleWatch(_ want: Bool) {
        busy = true
        DispatchQueue.global().async {
            let ok: Bool
            if want {
                ok = runAdmin("/bin/bash \(Self.backend) --daemon --watch")
            } else {
                ok = runAdmin("/usr/bin/pkill -f 'ocvpn --watch'")
            }
            DispatchQueue.main.async {
                busy = false
                if !ok { autoRotate = !want }
                refresh()
            }
        }
    }

    private func toggle() {
        busy = true
        detail = connected ? "Отключаю…" : "Подключаю…"
        DispatchQueue.global().async {
            let ok: Bool
            if connected {
                ok = runAdmin("/bin/bash \(Self.backend) --cleanup")
            } else {
                ok = runAdmin("/bin/bash \(Self.backend) --daemon")
            }
            DispatchQueue.main.async {
                busy = false
                let st = queryState()
                connected = st.on
                detail = ok ? st.detail : "Ошибка операции"
                logs = tailLog(120)
            }
        }
    }
}

// MARK: - backend

private func queryState() -> (on: Bool, detail: String) {
    if tcpOpen(port: ContentView.socksPort) {
        return (true, "SOCKS 127.0.0.1:\(ContentView.socksPort) отвечает")
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [ContentView.backend, "--status"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus == 0 {
            return (true, "все проверки --status в норме")
        }
    } catch {}
    return (false, "прокси не отвечает")
}

private func tcpOpen(port: Int) -> Bool {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var t = timeval(tv_sec: 0, tv_usec: 500_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}

private func watchPid() -> Int? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let pidFile =
        ProcessInfo.processInfo.environment["OCVPN_STATE_DIR"].map { "\($0)/watch.pid" }
        ?? "\(home)/.local/share/ocvpn/watch.pid"
    guard let text = try? String(contentsOfFile: pidFile),
        let pid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return kill(pid_t(pid), 0) == 0 ? pid : nil
}

private func tailLog(_ n: Int) -> String {    guard let data = try? Data(contentsOf: URL(fileURLWithPath: ContentView.logPath)),
        let text = String(data: data, encoding: .utf8)
    else { return "" }
    let lines = text.components(separatedBy: "\n")
    return lines.suffix(n).joined(separator: "\n")
}

/// do shell script ... with administrator privileges — штатный диалог macOS.
private func runAdmin(_ cmd: String) -> Bool {
    let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let src = "do shell script \"\(escaped)\" with administrator privileges"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", src]
    do {
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    } catch {
        return false
    }
}
