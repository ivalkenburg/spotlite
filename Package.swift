// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spotlite",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "SpotliteCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Spotlite",
            dependencies: ["SpotliteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SpotliteCoreTests",
            dependencies: ["SpotliteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
