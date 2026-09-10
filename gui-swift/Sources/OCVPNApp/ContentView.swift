import SwiftUI
import Darwin

/// OCVPN — нативный GUI: состояние + подписка + логи.
/// Привилегии для pf//etc/hosts запрашиваются штатным диалогом macOS
/// (osascript, administrator privileges). Вся блокирующая работа — в фоне,
/// главный поток только рисует (иначе — beachball и рост памяти).
struct ContentView: View {
    @State private var connected = false
    @State private var busy = false
    @State private var detail = "Проверка…"
    @State private var logs = ""
    @State private var autoRotate = false
    @State private var autoChanging = false
    @State private var watchDetail = ""
    @State private var subsText = ""
    @State private var subsStatus = ""
    @State private var subsOk = false
    @State private var showError = false
    @State private var errorMessage: String? = nil
    @State private var timer: Timer?

    static let backend = "/usr/local/bin/ocvpn"
    static let logPath =
        ProcessInfo.processInfo.environment["OCVPN_LOG"] ?? "/var/log/ocvpn.log"
    static let guiLog =
        ("~/Library/Logs/ocvpn-gui.log" as NSString).expandingTildeInPath
    static let socksPort = 10808

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Состояние") {
                HStack(spacing: 10) {
                    Circle()
                        .fill(busy ? .orange : (connected ? .green : .gray))
                        .frame(width: 14, height: 14)
                    VStack(alignment: .leading) {
                        Text(busy ? "Работаю…" : (connected ? "Подключено" : "Отключено"))
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
            }
            GroupBox("Подписка") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("https://…", text: $subsText)
                            .textFieldStyle(.roundedBorder)
                            .disabled(busy)
                        Button("Сохранить") {
                            saveSubs()
                        }
                        .disabled(busy || subsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text(subsStatus)
                        .font(.caption)
                        .foregroundStyle(subsOk ? .green : .red)
                }
            }
            Toggle(
                "Авторотация при лимитах (вотчдог)",
                isOn: Binding(
                    get: { autoRotate },
                    set: { want in toggleWatch(want) }
                )
            )
            .disabled(busy)
            Text(watchDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
            GroupBox("Логи") {
                ScrollView {
                    Text(logs.isEmpty ? "—" : logs)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 180, maxHeight: .infinity)
            }
            HStack {
                Text("Лог: \(Self.logPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Новый IP") {
                    newIp()
                }
                .disabled(busy)
                Button("Обновить") {
                    refreshAsync()
                }
            }
        }
        .padding()
        .onAppear {
            let ver =
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "?"
            let s = subsStatus()
            glog(
                "start ver=\(ver) backend=\(Self.backend) subs=\(s.text)"
            )
            refreshSubs()
            refreshAsync()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                refreshAsync()
            }
        }
        .onDisappear { timer?.invalidate() }
        .alert("OCVPN", isPresented: $showError, presenting: errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - опрос (фон)

    private func refreshAsync() {
        let skipState = busy
        let checkWatch = !autoChanging
        DispatchQueue.global(qos: .utility).async {
            let newLogs = tailLog(120)
            var st = (on: false, detail: "выполняется операция…")
            var pid: Int? = nil
            if !skipState {
                st = queryState()
                if checkWatch { pid = watchPid() }
            }
            DispatchQueue.main.async {
                logs = newLogs
                if !busy {
                    connected = st.on
                    detail = st.detail
                    if !autoChanging {
                        if let p = pid {
                            autoRotate = true
                            watchDetail = "вотчдог: pid \(p)"
                        } else {
                            autoRotate = false
                            watchDetail = "вотчдог выключен"
                        }
                    }
                }
            }
        }
    }

    private func refreshSubs() {
        let s = subsStatus()
        subsOk = s.ok
        subsStatus = s.text
        subsText = s.prefill
    }

    // MARK: - действия (фон + лог)

    private func toggle() {
        busy = true
        let wasOn = connected
        detail = wasOn ? "Отключаю…" : "Подключаю…"
        DispatchQueue.global().async {
            let cmd =
                wasOn
                ? "/bin/bash \(Self.backend) --cleanup"
                : envPrefix() + "/bin/bash \(Self.backend) --daemon"
            let r = runAdmin(cmd)
            glog("action \(wasOn ? "stop" : "start"): rc=\(r.ok) tail=\(r.out.suffix(200))")
            DispatchQueue.main.async {
                busy = false
                if !r.ok {
                    fail(opError("подключить", r.out))
                }
                refreshAsync()
            }
        }
    }

    private func newIp() {
        busy = true
        detail = "Меняю IP…"
        DispatchQueue.global().async {
            let r = runAdmin(envPrefix() + "/bin/bash \(Self.backend) --new-ip")
            glog("action newip: rc=\(r.ok) tail=\(r.out.suffix(200))")
            DispatchQueue.main.async {
                busy = false
                if !r.ok {
                    fail(opError("сменить IP", r.out))
                }
                refreshAsync()
            }
        }
    }

    private func toggleWatch(_ want: Bool) {
        autoChanging = true
        autoRotate = want  // оптимистично; при ошибке откатим
        busy = true
        DispatchQueue.global().async {
            let r: (ok: Bool, out: String)
            if want {
                r = runAdmin(envPrefix() + "/bin/bash \(Self.backend) --daemon --watch")
            } else {
                r = runAdmin("/usr/bin/pkill -f 'ocvpn --watch'")
            }
            glog("action watch(\(want)): rc=\(r.ok) tail=\(r.out.suffix(200))")
            DispatchQueue.main.async {
                autoChanging = false
                busy = false
                if !r.ok {
                    autoRotate = !want
                    fail(opError("вотчдог", r.out))
                }
                refreshAsync()
            }
        }
    }

    private func saveSubs() {
        let url = subsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("http") else {
            fail("Похоже, это не URL подписки: должно начинаться с https://")
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userFile = "\(home)/.ocvpn-subs-url"
        do {
            try url.write(toFile: userFile, atomically: true, encoding: .utf8)
        } catch {
            fail("Не записать \(userFile): \(error.localizedDescription)")
            return
        }
        glog("subs: saved \(userFile)")
        busy = true
        DispatchQueue.global().async {
            let q = url.replacingOccurrences(of: "'", with: "'\\''")
            let cmd =
                "mkdir -p /etc/ocvpn && printf '%s' '\(q)' > /etc/ocvpn/subs-url"
                + " && chmod 600 /etc/ocvpn/subs-url && echo SAVED"
            let r = runAdmin(cmd)
            glog("subs: system save rc=\(r.ok) tail=\(r.out.suffix(120))")
            DispatchQueue.main.async {
                busy = false
                refreshSubs()
                if !r.ok {
                    fail(
                        "В файл сохранено, а системно — нет (\(firstLine(r.out))). "
                            + "Кнопки GUI (работают от root) будут без подписки."
                    )
                }
            }
        }
    }

    private func fail(_ msg: String) {
        glog("error: \(msg.prefix(200))")
        errorMessage = "\(msg)\n\nПодробности: \(Self.guiLog)"
        showError = true
    }
}

// MARK: - backend

private func opError(_ what: String, _ out: String) -> String {
    let first = firstLine(out)
    if first.isEmpty { return "Не удалось \(what): отмена или нет прав (введи пароль в диалоге macOS)." }
    return "Не удалось \(what): \(first)"
}

private func firstLine(_ s: String) -> String {
    s.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? ""
}

/// env GUI до root через osascript не доходит — пробрасываем явно.
private func envPrefix() -> String {
    let u = (ProcessInfo.processInfo.environment["OCVPN_SUBS_URL"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !u.isEmpty else { return "" }
    return "OCVPN_SUBS_URL='\(u.replacingOccurrences(of: "'", with: "'\\''"))' "
}

private func queryState() -> (on: Bool, detail: String) {
    guard FileManager.default.isExecutableFile(atPath: ContentView.backend) else {
        return (false, "не найден \(ContentView.backend) — переустанови пакет")
    }
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
    addr.sin_family = sa_family_t(truncatingIfNeeded: AF_INET)
    addr.sin_port = in_port_t(truncatingIfNeeded: port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { _ = close(fd) }
    var t = timeval(tv_sec: 0, tv_usec: 500_000)
    setsockopt(
        fd, SOL_SOCKET, SO_SNDTIMEO, &t,
        socklen_t(truncatingIfNeeded: MemoryLayout<timeval>.size)
    )
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(
                fd, $0,
                socklen_t(truncatingIfNeeded: MemoryLayout<sockaddr_in>.size)
            ) == 0
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
    return kill(pid_t(truncatingIfNeeded: pid), 0) == 0 ? pid : nil
}

/// Хвост лога bounded: читаем только последние 32 КБ через seek
/// (целиком файл в память НЕ грузим — так и едят оперативу).
private func tailLog(_ n: Int) -> String {
    guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: ContentView.logPath))
    else { return "" }
    defer { try? fh.close() }
    let end = (try? fh.seekToEnd()) ?? 0
    let start: UInt64 = end > 32768 ? end - 32768 : 0
    try? fh.seek(toOffset: start)
    let data = (try? fh.read(upToCount: 32768)) ?? Data()
    guard let text = String(data: data, encoding: .utf8) else { return "" }
    let clean = text.replacingOccurrences(
        of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression
    )
    return clean.components(separatedBy: "\n").suffix(n).joined(separator: "\n")
}

private func readFirstLine(_ path: String) -> String {
    (try? String(contentsOfFile: path))?.components(separatedBy: "\n").first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func subsStatus() -> (ok: Bool, text: String, prefill: String) {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let userURL = readFirstLine("\(home)/.ocvpn-subs-url")
    let sysFile = "/etc/ocvpn/subs-url"
    let env =
        (ProcessInfo.processInfo.environment["OCVPN_SUBS_URL"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let prefill = env.isEmpty ? userURL : env
    if !userURL.isEmpty {
        return (true, "подписка: ~/.ocvpn-subs-url", prefill)
    }
    if FileManager.default.fileExists(atPath: sysFile) {
        let s = readFirstLine(sysFile)
        return (
            true,
            s.isEmpty
                ? "подписка: системная (есть, содержимое скрыто)"
                : "подписка: системная /etc/ocvpn/subs-url", prefill
        )
    }
    if !env.isEmpty {
        return (
            false, "подписка: только env GUI (root её НЕ видит!) — вставь URL и нажми «Сохранить»",
            prefill
        )
    }
    return (false, "подписки НЕТ — вставь URL подписки и нажми «Сохранить»", prefill)
}

/// do shell script ... with administrator privileges — штатный диалог macOS.
private func runAdmin(_ cmd: String) -> (ok: Bool, out: String) {
    let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let src = "do shell script \"\(escaped)\" with administrator privileges"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", src]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        return (false, "не запустился osascript")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out = (String(data: data, encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (p.terminationStatus == 0, out)
}

private func glog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    let path = ContentView.guiLog
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
        defer { try? fh.close() }
        try? fh.seekToEnd()
        try? fh.write(contentsOf: Data(line.utf8))
    }
}
