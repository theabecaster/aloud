// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aloud",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned below 0.16 deliberately: 0.15.x is a pure-source dependency
        // (no binary xcframeworks), which keeps the signing/notarization story
        // trivial. Revisit when bumping. See docs/architecture.md.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.5")),
    ],
    targets: [
        .executableTarget(
            name: "Aloud",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Aloud",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AloudTests",
            dependencies: ["Aloud"],
            path: "Tests/AloudTests"
        ),
    ]
)
