// swift-tools-version: 5.9

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
    swiftLanguageVersions: [.v5]
)
