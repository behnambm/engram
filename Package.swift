// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Siaheh",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Siaheh",
            path: "Sources/Siaheh"
        )
    ]
)
