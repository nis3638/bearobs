// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BearObsDomain",
    platforms: [
        .iOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(name: "BearObsDomain", targets: ["BearObsDomain"])
    ],
    targets: [
        .target(
            name: "BearObsDomain",
            path: "BearObs/Domain"
        ),
        .testTarget(
            name: "BearObsDomainTests",
            dependencies: ["BearObsDomain"],
            path: "BearObsTests/Domain"
        ),
    ]
)
