import SwiftUI
import Darwin

// MARK: - Тема оформления (тёмный OLED, акцент — зелёный #22C55E)

private enum Theme {
    static let background = LinearGradient(
        colors: [
            Color(red: 0.043, green: 0.063, blue: 0.118),
            Color(red: 0.059, green: 0.090, blue: 0.164),
            Color(red: 0.035, green: 0.050, blue: 0.098),
        ],
        startPoint: .top, endPoint: .bottom
    )
    static let accent = Color(red: 0.133, green: 0.773, blue: 0.369)
    static let warn = Color(red: 0.976, green: 0.620, blue: 0.100)
    static let danger = Color(red: 0.937, green: 0.267, blue: 0.267)
    static let idle = Color(red: 0.420, green: 0.470, blue: 0.580)
    static let text = Color.white
    static let sub = Color.white.opacity(0.55)
    static let stroke = Color.white.opacity(0.09)
    static let card = Color.white.opacity(0.045)
}

private struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

private extension View {
    func card() -> some View { modifier(CardModifier()) }
}

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

    /// Версия из строки OCVPN_VERSION="x.y.z" в файле.
    static func versionOf(_ path: String) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ""
        }
        for line in text.split(separator: "\n") where line.hasPrefix("OCVPN_VERSION=") {
            return line.replacingOccurrences(of: "OCVPN_VERSION=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return ""
    }

    /// Самоустановка бэкенда: если /usr/local/bin/ocvpn нет или он старее
    /// встроенного в бандл — ставим из Resources через админ-диалог macOS.
    static func ensureBackend() {
        guard let res = Bundle.main.path(forResource: "ocvpn", ofType: "sh") else {
            glog("backend: ресурс ocvpn.sh не найден в бандле")
            return
        }
        let bundled = versionOf(res)
        let installed = versionOf(backend)
        if FileManager.default.isExecutableFile(atPath: backend),
            !bundled.isEmpty, bundled == installed
        {
            return
        }
        glog("backend: устанавливаю (bundled=\(bundled) installed=\(installed))")
        let cmd =
            "mkdir -p /usr/local/bin && install -m 0755 '\(res)' '\(backend)'"
            + " && '\(backend)' --cleanup"
        let r = runAdmin(cmd)
        glog("backend: install rc=\(r.ok) tail=\(r.out.suffix(160))")
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                header
                hero
                subscriptionCard
                watchRow
                logsCard
                footer
            }
            .padding(22)
        }
        .frame(minWidth: 560, minHeight: 740)
        .onAppear {
            let ver =
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "?"
            let s = readSubsStatus()
            glog(
                "start ver=\(ver) backend=\(Self.backend) subs=\(s.text)"
            )
            refreshSubs()
            // бэкенд ставим/обновляем сами (может показать админ-диалог)
            DispatchQueue.global(qos: .userInitiated).async {
                ContentView.ensureBackend()
                DispatchQueue.main.async { refreshSubs(); refreshAsync() }
            }
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

    // MARK: - UI-компоненты

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Theme.accent.opacity(0.45)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("OCVPN")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text("Прозрачный VPN для opencode")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.sub)
            }
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        let color = busy ? Theme.warn : (connected ? Theme.accent : Theme.idle)
        let label = busy ? "Работаю…" : (connected ? "Подключено" : "Отключено")
        return HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: 6)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }

    private var hero: some View {
        let color = busy ? Theme.warn : (connected ? Theme.accent : Theme.idle)
        return VStack(spacing: 14) {
            Button(action: toggle) {
                ZStack {
                    if busy {
                        Circle()
                            .stroke(color.opacity(0.55), lineWidth: 2)
                            .frame(width: 196, height: 196)
                            .scaleEffect(busy ? 1.16 : 1.0)
                            .opacity(busy ? 0 : 1)
                            .animation(
                                .easeOut(duration: 1.3).repeatForever(autoreverses: false),
                                value: busy
                            )
                    }
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [color.opacity(0.9), color.opacity(0.28)],
                                center: .center, startRadius: 6, endRadius: 150
                            )
                        )
                        .frame(width: 182, height: 182)
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                        .shadow(color: color.opacity(0.55), radius: 26, x: 0, y: 10)
                    VStack(spacing: 10) {
                        Image(systemName: connected ? "shield.lefthalf.filled" : "power")
                            .font(.system(size: 50, weight: .semibold))
                        Text(connected ? "ОТКЛЮЧИТЬ" : "ПОДКЛЮЧИТЬ")
                            .font(.system(size: 14, weight: .heavy, design: .rounded))
                            .tracking(1.6)
                    }
                    .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .animation(.easeInOut(duration: 0.3), value: connected)
            .animation(.easeInOut(duration: 0.3), value: busy)
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.sub)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private var subscriptionCard: some View {
        let canSave = !busy
            && !subsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            label("link", "ПОДПИСКА")
            HStack(spacing: 8) {
                TextField("https://…", text: $subsText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.28))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1)
                    )
                    .disabled(busy)
                Button("Сохранить") { saveSubs() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.accent.opacity(canSave ? 0.9 : 0.4))
                    )
                    .disabled(!canSave)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(subsOk ? Theme.accent : Theme.danger)
                    .frame(width: 6, height: 6)
                Text(subsStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(subsOk ? Theme.accent : Theme.danger)
            }
        }
        .card()
    }

    private var watchRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Авторотация при лимитах")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(watchDetail.isEmpty ? "вотчдог следит за IP-лимитами opencode" : watchDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.sub)
            }
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { autoRotate },
                    set: { want in toggleWatch(want) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .disabled(busy)
        }
        .card()
    }

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                label("terminal", "ЛОГИ")
                Spacer()
                Text(Self.logPath)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.sub.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ScrollView {
                Text(logs.isEmpty ? "—" : logs)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 150, maxHeight: .infinity)
        }
        .card()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            secondaryButton("arrow.triangle.2.circlepath.circle.fill", "Новый IP", action: newIp)
            Spacer()
            secondaryButton("arrow.clockwise", "Обновить", action: refreshAsync)
        }
    }

    private func label(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.sub)
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.sub)
        }
    }

    private func secondaryButton(
        _ icon: String, _ text: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(text)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
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
        let s = readSubsStatus()
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
func envPrefix() -> String {
    let u = (ProcessInfo.processInfo.environment["OCVPN_SUBS_URL"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !u.isEmpty else { return "" }
    return "OCVPN_SUBS_URL='\(u.replacingOccurrences(of: "'", with: "'\\''"))' "
}

func queryState() -> (on: Bool, detail: String) {
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

private func readSubsStatus() -> (ok: Bool, text: String, prefill: String) {
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
func runAdmin(_ cmd: String) -> (ok: Bool, out: String) {
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

func glog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    let path = ContentView.guiLog
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: Data(line.utf8))
    }
}
