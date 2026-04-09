// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NexAsk",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "NexShared", targets: ["NexShared"]),
        .library(name: "NexAskFoundation", targets: ["NexAskFoundation"]),
        .library(name: "NexAskCore", targets: ["NexAskCore"]),
        .executable(name: "NexAskApp", targets: ["NexAskHost"])
    ],
    targets: [
        .target(
            name: "NexShared",
            path: "Sources/NexShared",
            exclude: [
                "Resources"
            ],
            sources: [
                "ActivationCore",
                "App",
                "EntryPipelines",
                "PlatformServices",
                "Presentation",
                "ProductCapabilities",
                "Screenshot",
                "Services",
                "SkillKernel",
                "UI"
            ],
            resources: [
                .process("LocalizationResources")
            ]
        ),
        .target(
            name: "NexAskFoundation",
            path: "Sources/NexAskFoundation"
        ),
        .target(
            name: "NexAskCore",
            dependencies: [
                "NexShared",
                "NexAskFoundation"
            ],
            path: "Sources/NexAskCore"
        ),
        .executableTarget(
            name: "NexAskHost",
            dependencies: [
                "NexShared",
                "NexAskCore"
            ],
            path: "Sources/NexAskHost"
        ),
        .testTarget(
            name: "NexAskTests",
            dependencies: [
                "NexShared",
                "NexAskCore"
            ],
            path: "Tests/NexAskTests"
        )
    ]
)
