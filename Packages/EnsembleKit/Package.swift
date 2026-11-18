// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EnsembleKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "EnsembleKit", targets: ["EnsembleKit"]),
    ],
    targets: [
        .target(name: "EnsembleKit"),
        .testTarget(
            name: "EnsembleKitTests",
            dependencies: ["EnsembleKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
