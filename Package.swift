// swift-tools-version: 6.4
// Keep the host generator and allocation-free runtime in one package. Embedded flags
// belong to individual verification/consumer builds, not the Foundation-using host target.
// Lifetimes is enabled per target for explicit borrowed-view dependencies.

import PackageDescription

// swift-docc-plugin is a dev-only dependency: it adds the
// `generate-documentation`/`preview-documentation` command plugins used to build this
// package's DocC catalog. It never links into CapnpRuntime or capnpc-swift.

/// Settings shared by the runtime and the generator: explicit lifetimes, the Swift 7
/// upcoming features, no implicit main-actor isolation, and strict memory safety with
/// every warning an error, so a new toolchain's new diagnostic stops the build.
let strict: [SwiftSetting] = [
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .defaultIsolation(nil),
    .strictMemorySafety(),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "capnproto-swift",
    // The package is a test bed for current Swift: it targets the newest Apple runtimes
    // (SE-0525 safe RawSpan loads and SE-0519 Ref are available from OS 27) and does not
    // back-deploy. Linux and Embedded targets have no OS gate.
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
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
            swiftSettings: strict
        ),
        .executableTarget(
            name: "capnpc-swift",
            dependencies: ["CapnpRuntime"],
            swiftSettings: strict
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
                .enableExperimentalFeature("Lifetimes")
            ]
        ),
    ]
)
