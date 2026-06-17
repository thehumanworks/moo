// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MooDeck",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MooDeck", targets: ["MooDeck"]),
        .library(name: "MooDeckCore", targets: ["MooDeckCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0"),
    ],
    targets: [
        .target(name: "MooDeckCore"),
        .executableTarget(
            name: "MooDeck",
            dependencies: [
                "MooDeckCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "MooDeckCoreTests",
            dependencies: ["MooDeckCore"]
        ),
    ]
)
