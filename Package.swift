// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "openmac",
    targets: [
        .executableTarget(
            name: "openmac"
        ),
        .testTarget(
            name: "openmacTests",
            dependencies: ["openmac"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
