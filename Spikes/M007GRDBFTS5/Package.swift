// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "M007GRDBFTS5",
    platforms: [
        .iOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(name: "GRDBFTS5Spike", targets: ["GRDBFTS5Spike"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        )
    ],
    targets: [
        .target(
            name: "GRDBFTS5Spike",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "GRDBFTS5SpikeTests",
            dependencies: [
                "GRDBFTS5Spike",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
