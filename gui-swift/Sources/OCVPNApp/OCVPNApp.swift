import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    // Окно можно закрыть — приложение остаётся жить в строке меню.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct OCVPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("OCVPN", id: "main") {
            ContentView()
                .frame(minWidth: 560, minHeight: 740)
        }
        .defaultSize(width: 620, height: 840)
        .windowResizability(.contentMinSize)

        MenuBarExtra("OCVPN", systemImage: "shield.lefthalf.filled") {
            MenuBarView()
        }
    }
}
