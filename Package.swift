// swift-tools-version: 6.2
// Keep the host generator and allocation-free runtime in one package. Embedded flags
// belong to individual verification/consumer builds, not the Foundation-using host target.
// Lifetimes is enabled per target for explicit borrowed-view dependencies.

import PackageDescription

// swift-docc-plugin is a dev-only dependency: it adds the
// `generate-documentation`/`preview-documentation` command plugins used to build this
// package's DocC catalog. It never links into CapnpRuntime or capnpc-swift.

let package = Package(
    name: "capnproto-swift",
    // Keep POD wire utilities usable below the reader's OS requirement. Reader APIs
    // have their own availability gates for Synchronization.Atomic (macOS 15 / iOS 18).
    // The package floor also accommodates the host test framework.
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1)],
    products: [
        .library(name: "CapnpRuntime", targets: ["CapnpRuntime"]),
        .executable(name: "capnpc-swift", targets: ["capnpc-swift"]),
        // Build-time schema generation for consuming targets.
        .plugin(name: "CapnpGeneratorPlugin", targets: ["CapnpGeneratorPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0")
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
        // Locates capnp on the host and lets it drive capnpc-swift per schema.
        .plugin(
            name: "CapnpGeneratorPlugin",
            capability: .buildTool(),
            dependencies: ["capnpc-swift"]
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
