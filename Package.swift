// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harc",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarcCore", targets: ["HarcCore"]),
        .library(name: "HarcAudio", targets: ["HarcAudio"]),
        .library(name: "HarcClient", targets: ["HarcClient"]),
        .library(name: "HarcStore", targets: ["HarcStore"]),
        .library(name: "HarcUI", targets: ["HarcUI"]),
        .library(name: "HarcExport", targets: ["HarcExport"]),
        .library(name: "HarcMeetingDetect", targets: ["HarcMeetingDetect"]),
        .library(name: "HarcModels", targets: ["HarcModels"]),
        .library(name: "HarcSummarize", targets: ["HarcSummarize"]),
        .library(name: "HarcVoiceprint", targets: ["HarcVoiceprint"]),
        .executable(name: "harc-stt", targets: ["HarcSTT"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            .upToNextMinor(from: "0.13.5")
        ),
        .package(
            url: "https://github.com/sindresorhus/KeyboardShortcuts.git",
            from: "2.3.0"
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            from: "6.29.0"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            .upToNextMajor(from: "3.31.3")
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            from: "0.9.0"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            from: "1.3.0"
        ),
    ],
    targets: [
        .target(name: "HarcCore"),
        .target(
            name: "HarcAudio",
            dependencies: ["HarcCore", "HarcClient"]
        ),
        .target(
            name: "HarcClient",
            dependencies: ["HarcCore", "HarcVoiceprint"]
        ),
        .target(
            name: "HarcVoiceprint",
            dependencies: ["HarcCore"]
        ),
        .target(
            name: "HarcStore",
            dependencies: [
                "HarcCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "HarcUI",
            dependencies: [
                "HarcCore",
                "HarcAudio",
                "HarcClient",
                "HarcStore",
                "HarcExport",
                "HarcMeetingDetect",
                "HarcModels",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .target(
            name: "HarcModels",
            dependencies: ["HarcCore"]
        ),
        .executableTarget(
            name: "HarcSTT",
            dependencies: [
                "HarcCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .target(
            name: "HarcExport",
            dependencies: ["HarcCore", "HarcClient", "HarcStore"]
        ),
        .target(
            name: "HarcMeetingDetect",
            dependencies: ["HarcCore"]
        ),
        .target(
            name: "HarcSummarize",
            dependencies: [
                "HarcCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .testTarget(name: "HarcCoreTests", dependencies: ["HarcCore"]),
        .testTarget(
            name: "HarcModelsTests",
            dependencies: ["HarcModels", "HarcCore"]
        ),
        .testTarget(
            name: "HarcVoiceprintTests",
            dependencies: ["HarcVoiceprint", "HarcCore"]
        ),
        .testTarget(
            name: "HarcMeetingDetectTests",
            dependencies: ["HarcMeetingDetect", "HarcCore"]
        ),
        .testTarget(
            name: "HarcSummarizeTests",
            dependencies: ["HarcSummarize", "HarcCore"]
        ),
        .testTarget(
            name: "HarcExportTests",
            dependencies: ["HarcExport", "HarcCore", "HarcClient", "HarcStore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "HarcSTTTests",
            dependencies: ["HarcSTT", "HarcCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "HarcAudioTests",
            dependencies: ["HarcAudio", "HarcCore", "HarcClient"]
        ),
        .testTarget(
            name: "HarcClientTests",
            dependencies: ["HarcClient", "HarcCore"]
        ),
        .testTarget(
            name: "HarcUITests",
            dependencies: ["HarcUI", "HarcCore"]
        ),
        .testTarget(
            name: "HarcStoreTests",
            dependencies: ["HarcStore", "HarcCore"]
        ),
    ]
)
