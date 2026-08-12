// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "JianguoyunWebDAVVerifier",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "JianguoyunWebDAVVerifierCore",
            targets: ["JianguoyunWebDAVVerifierCore"]
        ),
        .executable(
            name: "JianguoyunWebDAVVerifier",
            targets: ["JianguoyunWebDAVVerifierCLI"]
        ),
    ],
    targets: [
        .target(
            name: "JianguoyunWebDAVVerifierCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "JianguoyunWebDAVVerifierCLI",
            dependencies: ["JianguoyunWebDAVVerifierCore"]
        ),
        .testTarget(
            name: "JianguoyunWebDAVVerifierCoreTests",
            dependencies: ["JianguoyunWebDAVVerifierCore"]
        ),
    ]
)
