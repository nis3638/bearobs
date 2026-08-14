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
        .library(name: "BearObsIndex", targets: ["BearObsIndex"]),
        .library(name: "BearObsLibrary", targets: ["BearObsLibrary"]),
        .library(name: "BearObsUserState", targets: ["BearObsUserState"]),
        .executable(name: "BearObsAppShell", targets: ["BearObsAppShell"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        ),
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
                "BearObsDomain",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "BearObs/Markdown"
        ),
        .target(
            name: "BearObsIndex",
            dependencies: [
                "BearObsDomain",
                "BearObsLocalVault",
                "BearObsMarkdown",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "BearObs/Infrastructure/Index"
        ),
        .target(
            name: "BearObsLibrary",
            dependencies: [
                "BearObsDomain",
                "BearObsIndex",
                "BearObsLocalVault",
                "BearObsMarkdown",
            ],
            path: "BearObs/Features/Library"
        ),
        .target(
            name: "BearObsUserState",
            dependencies: ["BearObsDomain"],
            path: "BearObs/Infrastructure/UserState"
        ),
        .executableTarget(
            name: "BearObsAppShell",
            dependencies: ["BearObsLibrary", "BearObsUserState"],
            path: "BearObs/App"
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
            dependencies: [
                "BearObsDomain",
                "BearObsMarkdown",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "BearObsTests/Markdown",
            resources: [
                .copy("../Fixtures/GoldenVault")
            ]
        ),
        .testTarget(
            name: "BearObsIndexTests",
            dependencies: [
                "BearObsDomain",
                "BearObsIndex",
                "BearObsLocalVault",
                "BearObsMarkdown",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "BearObsTests/Infrastructure/Index",
            resources: [
                .copy("../../Fixtures/ChineseSearchVault")
            ]
        ),
        .testTarget(
            name: "BearObsUserStateTests",
            dependencies: ["BearObsDomain", "BearObsUserState"],
            path: "BearObsTests/Infrastructure/UserState"
        ),
        .testTarget(
            name: "BearObsLibraryTests",
            dependencies: [
                "BearObsDomain",
                "BearObsIndex",
                "BearObsLibrary",
                "BearObsLocalVault",
                "BearObsMarkdown",
            ],
            path: "BearObsTests/Features/Library"
        ),
    ]
)
