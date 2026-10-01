// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MusicVisualizer",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "MusicVisualizer",
            path: "Sources/MusicVisualizer",
            exclude: ["Render/Shaders.metal"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release))
            ]
        )
    ]
)
