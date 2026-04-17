// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Harc",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarcCore", targets: ["HarcCore"]),
        .executable(name: "harc-stt", targets: ["HarcSTT"]),
    ],
    targets: [
        .target(name: "HarcCore"),
        .executableTarget(name: "HarcSTT", dependencies: ["HarcCore"]),
        .testTarget(name: "HarcCoreTests", dependencies: ["HarcCore"]),
    ]
)
