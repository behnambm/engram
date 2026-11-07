// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Engram",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Engram",
            path: "Sources/Engram"
        )
    ]
)
