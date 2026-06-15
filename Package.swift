// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DualSenseKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DualSenseKitDemo", targets: ["DualSenseKitDemo"]),
        .library(name: "DualSenseKit", targets: ["DualSenseKit"]),
        .library(name: "DualSenseKitDemoCore", targets: ["DualSenseKitDemoCore"])
    ],
    targets: [
        .target(name: "DualSenseKit"),
        .target(
            name: "DualSenseKitDemoCore",
            dependencies: ["DualSenseKit"],
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
            name: "DualSenseKitDemo",
            dependencies: ["DualSenseKitDemoCore"]
        )
    ]
)
