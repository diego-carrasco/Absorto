// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AbsortoCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AbsortoCore", targets: ["AbsortoCore"]),
        .executable(name: "DriftEngineSmoke", targets: ["DriftEngineSmoke"])
    ],
    targets: [
        .target(
            name: "AbsortoCore",
            path: "Absorto",
            exclude: [
                "AbsortoApp.swift",
                "Info.plist",
                "Absorto.entitlements",
                "Assets.xcassets",
                "Config",
                "UI",
                "Camera",
                "Window",
                "Screen",
                "Vision",
                "Audio",
                "Session",
                "Gemini"
            ],
            sources: [
                "Models/Models.swift",
                "Engine/DriftEngine.swift"
            ]
        ),
        .executableTarget(
            name: "DriftEngineSmoke",
            dependencies: ["AbsortoCore"],
            path: "DriftEngineSmoke"
        ),
        .testTarget(
            name: "AbsortoCoreTests",
            dependencies: ["AbsortoCore"],
            path: "AbsortoCoreTests"
        )
    ]
)
