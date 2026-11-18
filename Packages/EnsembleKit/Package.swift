// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EnsembleKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "EnsembleKit", targets: ["EnsembleKit"]),
    ],
    targets: [
        // Fonts: Inter and Ensemble Serif, SIL Open Font License 1.1 (licence texts next to the font files).
        .target(name: "EnsembleKit", resources: [.copy("Resources/Fonts")]),
        .testTarget(
            name: "EnsembleKitTests",
            dependencies: ["EnsembleKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
