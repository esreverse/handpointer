// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TinyPointer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TinyPointer",
            path: "Sources/TinyPointer"
        )
    ]
)
