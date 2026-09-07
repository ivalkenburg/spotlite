// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spotlite",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "SpotliteCore"
        ),
        .executableTarget(
            name: "Spotlite",
            dependencies: ["SpotliteCore"]
        ),
        .testTarget(
            name: "SpotliteCoreTests",
            dependencies: ["SpotliteCore"]
        ),
    ]
)
