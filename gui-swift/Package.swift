// swift-tools-version: 5.9
// Нативный GUI OCVPN для macOS (SwiftUI). Сборка ТОЛЬКО на Mac:
//   cd gui-swift && ./build.sh   → dist/OCVPN-native.app
import PackageDescription

let package = Package(
    name: "OCVPNApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OCVPNApp",
            path: "Sources/OCVPNApp"
        )
    ]
)
