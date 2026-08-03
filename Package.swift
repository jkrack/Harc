// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Harc",
    platforms: [.macOS(.v26), .iOS(.v18)],
    products: [
        .library(name: "HarcCore", targets: ["HarcCore"]),
        .library(name: "HarcDomain", targets: ["HarcDomain"]),
        .library(name: "HarcIdentity", targets: ["HarcIdentity"]),
        .library(name: "HarcTransfer", targets: ["HarcTransfer"]),
        .library(name: "HarcProtocolWire", targets: ["HarcProtocolWire"]),
        .library(name: "HarcProtocol", targets: ["HarcProtocol"]),
        .library(name: "HarcClientStore", targets: ["HarcClientStore"]),
        .library(name: "HarcHost", targets: ["HarcHost"]),
        .library(name: "HarcHostTransport", targets: ["HarcHostTransport"]),
        .library(name: "HarcClientTransport", targets: ["HarcClientTransport"]),
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
        .executable(name: "harc-mcp", targets: ["HarcMCP"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            .upToNextMinor(from: "0.15.5")
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
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            .upToNextMinor(from: "0.12.1")
        ),
        .package(
            url: "https://github.com/grpc/grpc-swift-2.git",
            exact: "2.4.2"
        ),
        .package(
            url: "https://github.com/grpc/grpc-swift-protobuf.git",
            exact: "2.4.1"
        ),
        .package(
            url: "https://github.com/grpc/grpc-swift-nio-transport.git",
            exact: "2.9.0"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            exact: "1.38.1",
            traits: []
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.99.0"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-transport-services.git",
            exact: "1.28.0"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-ssl.git",
            exact: "2.37.2"
        ),
    ],
    targets: [
        .target(name: "HarcCore"),
        .target(name: "HarcDomain", exclude: ["README.md"]),
        .target(
            name: "HarcIdentity",
            dependencies: ["HarcDomain"],
            exclude: ["README.md"]
        ),
        .target(
            name: "HarcTransfer",
            dependencies: ["HarcDomain", "HarcIdentity"],
            exclude: ["README.md"]
        ),
        .target(
            name: "HarcProtocolWire",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Protos",
            exclude: ["Fixtures", "README.md"],
            plugins: [
                .plugin(
                    name: "GRPCProtobufGenerator",
                    package: "grpc-swift-protobuf"
                ),
            ]
        ),
        .target(
            name: "HarcProtocol",
            dependencies: [
                "HarcProtocolWire",
                "HarcDomain",
                "HarcIdentity",
                "HarcTransfer",
            ],
            exclude: ["README.md"],
            resources: [
                .copy("../../Protos/Fixtures/harc-sas-words-v1.txt"),
            ]
        ),
        .target(
            name: "HarcClientStore",
            dependencies: [
                "HarcDomain",
                "HarcTransfer",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            exclude: ["README.md"]
        ),
        .target(
            name: "HarcHost",
            dependencies: [
                "HarcDomain",
                "HarcIdentity",
                "HarcProtocol",
                "HarcStore",
                "HarcTransfer",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            exclude: ["README.md"]
        ),
        .target(
            name: "HarcHostTransport",
            dependencies: [
                "HarcHost",
                "HarcProtocol",
                .product(
                    name: "GRPCNIOTransportHTTP2TransportServices",
                    package: "grpc-swift-nio-transport"
                ),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(
                    name: "NIOTransportServices",
                    package: "swift-nio-transport-services"
                ),
            ],
            exclude: ["README.md"]
        ),
        .target(
            name: "HarcClientTransport",
            dependencies: [
                "HarcProtocol",
                "HarcIdentity",
                "HarcTransfer",
                .product(
                    name: "GRPCNIOTransportHTTP2TransportServices",
                    package: "grpc-swift-nio-transport"
                ),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(
                    name: "NIOTransportServices",
                    package: "swift-nio-transport-services"
                ),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            exclude: ["README.md"]
        ),
        .target(
            name: "HarcAudio",
            dependencies: ["HarcCore", "HarcDomain", "HarcClient", "HarcAudioObjC"]
        ),
        .target(
            name: "HarcAudioObjC",
            publicHeadersPath: "include"
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
                "HarcDomain",
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
                "HarcSummarize",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ]
        ),
        .target(
            name: "HarcModels",
            dependencies: [
                "HarcCore",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "HarcSTT",
            dependencies: [
                "HarcCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "HarcMCP",
            dependencies: [
                "HarcCore",
                "HarcStore",
                .product(name: "MCP", package: "swift-sdk"),
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
        .testTarget(name: "HarcDomainTests", dependencies: ["HarcDomain"]),
        .testTarget(
            name: "HarcIdentityTests",
            dependencies: ["HarcIdentity", "HarcDomain"]
        ),
        .testTarget(
            name: "HarcTransferTests",
            dependencies: ["HarcTransfer", "HarcIdentity", "HarcDomain"]
        ),
        .testTarget(
            name: "HarcProtocolTests",
            dependencies: [
                "HarcProtocol",
                "HarcProtocolWire",
                "HarcDomain",
                "HarcIdentity",
                "HarcTransfer",
            ]
        ),
        .testTarget(
            name: "HarcClientStoreTests",
            dependencies: [
                "HarcClientStore",
                "HarcDomain",
                "HarcIdentity",
                "HarcTransfer",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "HarcHostTests",
            dependencies: [
                "HarcHost",
                "HarcDomain",
                "HarcIdentity",
                "HarcProtocol",
                "HarcStore",
                "HarcTransfer",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "HarcHostTransportTests",
            dependencies: [
                "HarcHostTransport",
                .product(
                    name: "GRPCNIOTransportHTTP2TransportServices",
                    package: "grpc-swift-nio-transport"
                ),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "HarcClientTransportTests",
            dependencies: [
                "HarcClientTransport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
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
            dependencies: ["HarcAudio", "HarcCore", "HarcDomain", "HarcClient"]
        ),
        .testTarget(
            name: "HarcClientTests",
            dependencies: ["HarcClient", "HarcCore"]
        ),
        .testTarget(
            name: "HarcUITests",
            dependencies: ["HarcUI", "HarcCore", "HarcStore", "HarcExport", "HarcAudio"]
        ),
        .testTarget(
            name: "HarcQualityTests",
            dependencies: ["HarcCore", "HarcSTT", "HarcSummarize"]
        ),
        .testTarget(
            name: "HarcStoreTests",
            dependencies: ["HarcStore", "HarcCore", "HarcDomain"]
        ),
        .testTarget(
            name: "HarcMCPTests",
            dependencies: ["HarcMCP", "HarcStore", "HarcCore"]
        ),
    ]
)
