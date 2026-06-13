// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDC002",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "PDC002Kit",
            resources: [.copy("Resources/firmware")]
        ),
        .executableTarget(
            name: "PDC002",
            dependencies: ["PDC002Kit"]
        ),
        .testTarget(
            name: "PDC002KitTests",
            dependencies: ["PDC002Kit"],
            resources: [.copy("Resources")]
        ),
    ]
)
