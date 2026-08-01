// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "M009AtomicWrite",
    platforms: [
        .iOS(.v26),
        .macOS(.v15),
    ],
    products: [
        .library(name: "AtomicWriteSpike", targets: ["AtomicWriteSpike"]),
        .executable(
            name: "AtomicWriteCrashProbe",
            targets: ["AtomicWriteCrashProbe"]
        ),
    ],
    targets: [
        .target(name: "AtomicWriteSpike"),
        .executableTarget(
            name: "AtomicWriteCrashProbe",
            dependencies: ["AtomicWriteSpike"]
        ),
        .testTarget(
            name: "AtomicWriteSpikeTests",
            dependencies: ["AtomicWriteSpike"]
        ),
    ]
)
