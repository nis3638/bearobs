// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BearObsDomain",
    platforms: [
        .iOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(name: "BearObsDomain", targets: ["BearObsDomain"]),
        .library(name: "BearObsLocalVault", targets: ["BearObsLocalVault"]),
        .library(name: "BearObsMarkdown", targets: ["BearObsMarkdown"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/jpsim/Yams.git",
            exact: "6.2.2"
        )
    ],
    targets: [
        .target(
            name: "BearObsDomain",
            path: "BearObs/Domain"
        ),
        .target(
            name: "BearObsLocalVault",
            dependencies: ["BearObsDomain"],
            path: "BearObs/Infrastructure/LocalVault"
        ),
        .target(
            name: "BearObsMarkdown",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "BearObs/Markdown/Frontmatter"
        ),
        .testTarget(
            name: "BearObsDomainTests",
            dependencies: ["BearObsDomain"],
            path: "BearObsTests/Domain"
        ),
        .testTarget(
            name: "BearObsLocalVaultTests",
            dependencies: ["BearObsDomain", "BearObsLocalVault"],
            path: "BearObsTests/Infrastructure/LocalVault",
            resources: [
                .copy("../../Fixtures/GoldenVault")
            ]
        ),
        .testTarget(
            name: "BearObsMarkdownTests",
            dependencies: ["BearObsMarkdown"],
            path: "BearObsTests/Markdown/Frontmatter",
            resources: [
                .copy("../../Fixtures/GoldenVault")
            ]
        ),
    ]
)
