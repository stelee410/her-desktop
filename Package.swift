// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HerDesktop",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HerDesktop", targets: ["HerDesktop"])
    ],
    targets: [
        .executableTarget(
            name: "HerDesktop",
            path: "Sources/HerDesktop",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "HerDesktopTests",
            dependencies: ["HerDesktop"],
            path: "Tests/HerDesktopTests"
        )
    ]
)
