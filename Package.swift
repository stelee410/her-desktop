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
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "HerDesktop",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
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
