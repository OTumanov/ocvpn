import SwiftUI

@main
struct OCVPNApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 440)
        }
        .windowResizability(.contentSize)
    }
}
