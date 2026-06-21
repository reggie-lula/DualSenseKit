// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DualSenseKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DualSenseKitApp", targets: ["DualSenseKitApp"]),
        .executable(name: "DualSenseKitDemo", targets: ["DualSenseKitDemo"]),
        .library(name: "DualSenseKit", targets: ["DualSenseKit"]),
        .library(name: "DualSenseKitRuntime", targets: ["DualSenseKitRuntime"]),
        .library(name: "DualSenseKitDemoCore", targets: ["DualSenseKitDemoCore"])
    ],
    targets: [
        .target(name: "DualSenseKit"),
        .target(
            name: "DualSenseKitRuntime",
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
            name: "DualSenseKitApp",
            dependencies: ["DualSenseKitRuntime"],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "DualSenseKitDemoCore",
            dependencies: ["DualSenseKitRuntime"],
            path: "Sources/demo/DualSenseKitDemoCore",
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
            dependencies: ["DualSenseKitDemoCore"],
            path: "Sources/demo/DualSenseKitDemo"
        ),
        .executableTarget(
            name: "DualSenseKitSelfTest",
            dependencies: ["DualSenseKitRuntime"],
            path: "Tests/SelfTest"
        )
    ]
)
