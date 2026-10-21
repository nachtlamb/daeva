// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Daeva",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Daeva", path: "Sources/Daeva")
    ]
)
