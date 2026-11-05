// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InstaIndir",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "InstaIndir", path: "Sources/InstaIndir")
    ]
)
