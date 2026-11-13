// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoOrganizer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PhotoOrganizerCore",
            targets: ["PhotoOrganizerCore"]
        ),
        .executable(
            name: "PhotoOrganizerApp",
            targets: ["PhotoOrganizerApp"]
        )
    ],
    targets: [
        .target(
            name: "PhotoOrganizerCore",
            dependencies: [],
            resources: [
                .copy("Resources/MobileFaceNet.mlmodelc")
            ]
        ),
        .executableTarget(
            name: "PhotoOrganizerApp",
            dependencies: ["PhotoOrganizerCore"]
        ),
        .testTarget(
            name: "PhotoOrganizerCoreTests",
            dependencies: ["PhotoOrganizerCore"]
        )
    ]
)
