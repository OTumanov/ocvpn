import SwiftUI
import AppKit

/// Пункт в строке меню macOS: быстрый статус + подключение/отключение,
/// смена IP, открытие окна и выход. Логика — тот же backend, что у окна.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var connected = false
    @State private var busy = false
    @State private var detail = "Проверка…"
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(busy ? Color.orange : (connected ? Color.green : Color.gray))
                    .frame(width: 9, height: 9)
                Text(busy ? "Работаю…" : (connected ? "Подключено" : "Отключено"))
                    .font(.headline)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: 240, alignment: .leading)

            Divider()

            Button(connected ? "Отключить" : "Подключить") { toggle() }
                .disabled(busy)
            Button("Новый IP") { newIP() }
                .disabled(busy || !connected)

            Divider()

            Button("Открыть окно") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Выход") { NSApplication.shared.terminate(nil) }
        }
        .padding(8)
        .onAppear {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                refresh()
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    private func refresh() {
        let skip = busy
        DispatchQueue.global(qos: .utility).async {
            if skip { return }
            let st = queryState()
            DispatchQueue.main.async {
                connected = st.on
                detail = st.detail
            }
        }
    }

    private func toggle() {
        busy = true
        let wasOn = connected
        DispatchQueue.global().async {
            let cmd =
                wasOn
                ? "/bin/bash \(ContentView.backend) --cleanup"
                : envPrefix() + "/bin/bash \(ContentView.backend) --daemon"
            let r = runAdmin(cmd)
            glog("menubar \(wasOn ? "stop" : "start"): rc=\(r.ok) tail=\(r.out.suffix(200))")
            DispatchQueue.main.async {
                busy = false
                refresh()
            }
        }
    }

    private func newIP() {
        busy = true
        DispatchQueue.global().async {
            let r = runAdmin(envPrefix() + "/bin/bash \(ContentView.backend) --new-ip")
            glog("menubar newip: rc=\(r.ok) tail=\(r.out.suffix(200))")
            DispatchQueue.main.async {
                busy = false
                refresh()
            }
        }
    }
}
