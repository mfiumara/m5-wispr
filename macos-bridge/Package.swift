// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "M5WisprBridge",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "m5-wispr-bridge", targets: ["M5WisprBridge"])
    ],
    targets: [
        .target(name: "M5WisprBridgeCore"),
        .executableTarget(
            name: "M5WisprBridge",
            dependencies: ["M5WisprBridgeCore"]
        )
    ]
)
