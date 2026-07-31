// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "M008Markdown",
    platforms: [
        .iOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(name: "MarkdownSpike", targets: ["MarkdownSpike"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-markdown.git",
            exact: "0.8.0"
        ),
        .package(
            url: "https://github.com/jpsim/Yams.git",
            exact: "6.2.2"
        ),
    ],
    targets: [
        .target(
            name: "MarkdownSpike",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .testTarget(
            name: "MarkdownSpikeTests",
            dependencies: ["MarkdownSpike"]
        ),
    ]
)
