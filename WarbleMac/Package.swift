// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WarbleMac",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "WarbleMac",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .testTarget(
            name: "WarbleMacTests",
            dependencies: ["WarbleMac"]
        )
    ]
)
