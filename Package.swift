// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Peek",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PeekCore"),
        .executableTarget(name: "peek-hook", dependencies: ["PeekCore"]),
        .executableTarget(name: "Peek", dependencies: ["PeekCore"], resources: [.copy("Sounds")]),
        .testTarget(name: "PeekCoreTests", dependencies: ["PeekCore"]),
    ]
)
