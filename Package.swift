// swift-tools-version: 6.2
// Keep the host generator and allocation-free runtime in one package. Embedded flags
// belong to individual verification/consumer builds, not the Foundation-using host target.
// Lifetimes is enabled per target for explicit borrowed-view dependencies.

import PackageDescription

let package = Package(
    name: "capnproto-swift",
    // Keep POD wire utilities usable below the reader's OS requirement. Reader APIs
    // have their own availability gates for Synchronization.Atomic (macOS 15 / iOS 18).
    // The package floor also accommodates the host test framework.
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1)],
    products: [
        .library(name: "CapnpRuntime", targets: ["CapnpRuntime"]),
        .executable(name: "capnpc-swift", targets: ["capnpc-swift"]),
    ],
    targets: [
        // Allocation-free, Foundation-free runtime. Must stay Embedded-clean.
        .target(
            name: "CapnpRuntime",
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes"),
            ]
        ),
        .executableTarget(
            name: "capnpc-swift",
            dependencies: ["CapnpRuntime"],
            swiftSettings: [.enableExperimentalFeature("Lifetimes")]
        ),
        // Host semantic tests use the full standard library; ci/ separately checks Embedded.
        .testTarget(
            name: "CapnpRuntimeTests",
            dependencies: ["CapnpRuntime"],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes"),
            ]
        ),
    ]
)
