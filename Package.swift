// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KittenTTSMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KittenTTSMac", targets: ["KittenTTSMac"]),
    ],
    targets: [
        .executableTarget(
            name: "KittenTTSMac",
            path: "macos/KittenTTSMac"
        ),
    ]
)
