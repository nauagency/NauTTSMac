// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NauTTSMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NauTTSMac", targets: ["NauTTSMac"]),
    ],
    targets: [
        .executableTarget(
            name: "NauTTSMac",
            path: "macos/NauTTSMac"
        ),
    ]
)
