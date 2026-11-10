// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HandPointer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "HandPointer",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/HandPointer",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
