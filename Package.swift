// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spotlite",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "CLua", path: "Vendor/Lua", exclude: ["README", "PROVENANCE.md"],
                sources: ["src"], publicHeadersPath: "include",
                cSettings: [.define("LUA_USE_MACOSX")],
                linkerSettings: [.linkedLibrary("m"), .linkedLibrary("dl")]),
        .executableTarget(name: "SpotlitePluginRunner", dependencies: ["CLua"]),
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
