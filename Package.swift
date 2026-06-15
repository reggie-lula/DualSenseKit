// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DualSenseBridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DualSenseBridge", targets: ["DualSenseBridge"]),
        .library(name: "DualSenseBridgeSDK", targets: ["DualSenseBridgeSDK"]),
        .library(name: "DualSenseBridgeCore", targets: ["DualSenseBridgeCore"])
    ],
    targets: [
        .target(name: "DualSenseBridgeSDK"),
        .target(
            name: "DualSenseBridgeCore",
            dependencies: ["DualSenseBridgeSDK"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("GameController"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "DualSenseBridge",
            dependencies: ["DualSenseBridgeCore"]
        )
    ]
)
