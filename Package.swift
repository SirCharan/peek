// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchTasks",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "NotchTasks", resources: [.copy("Sounds")])]
)
