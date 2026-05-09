// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "XUI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "XUI", targets: ["XUI"])
    ],
    targets: [
        .executableTarget(name: "XUI"),
        .testTarget(
            name: "XUITests",
            dependencies: ["XUI"]
        )
    ]
)
