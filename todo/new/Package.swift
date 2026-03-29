// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ScreenMaskRecorder",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ScreenMaskRecorder",
            targets: ["ScreenMaskRecorder"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ScreenMaskRecorder",
            dependencies: [],
            path: "ScreenMaskRecorder",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
