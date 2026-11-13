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
                .copy("Resources/MobileFaceNet.mlmodelc"),
                .copy("Resources/HeroSilhouette1.png"),
                .copy("Resources/HeroSilhouette2.png"),
                .copy("Resources/AppIcon.icns")
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
