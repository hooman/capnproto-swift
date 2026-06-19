// swift-tools-version: 6.2
// capnproto-swift — Cap'n Proto for modern Swift (6.3+), Embedded-Swift-capable.
//
// Two targets per decision D-2: an unconstrained host plugin (`capnpc-swift`) and an
// allocation-free runtime (`CapnpRuntime`). The Embedded build flags
// (`-enable-experimental-feature Embedded`, `-no-allocations`, `-wmo`) are applied
// per-build for embedded targets, not globally here. See the workspace anchors/INVARIANTS.md.

import PackageDescription

let package = Package(
    name: "capnproto-swift",
    // Minimal floor = the Swift-concurrency era (the lowest deployment at which
    // swift-testing's macros compile; XCTest is unavailable without full Xcode). This
    // preserves D-10's model (keep the floor low, gate the reader surface via
    // `@available`); it is NOT the reader's real requirement. The reader needs the
    // Synchronization set (macOS 15 / iOS 18 / watchOS 11 / tvOS 18 / visionOS 2) because
    // the D-11/A `Atomic` limiter back-deploys only that far — a finding that supersedes
    // D-10/DR-D's "RawSpan back-deployment set is the floor" (see the M1 feedback;
    // propose-then-commit). RawPointer/Wire stay usable down to this floor.
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
                .enableExperimentalFeature("Lifetimes"),  // gates @_lifetime
            ]
        ),
        // Host-only code generator. Unconstrained (Foundation allowed, per D-8).
        .executableTarget(
            name: "capnpc-swift",
            dependencies: ["CapnpRuntime"]
        ),
        // Host tests for the runtime (full stdlib; the Embedded gate is a separate
        // compile check in ci/). Needs `Lifetimes` because it constructs the
        // `~Escapable` reader over a borrowed arena.
        .testTarget(
            name: "CapnpRuntimeTests",
            dependencies: ["CapnpRuntime"],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes"),
            ]
        ),
    ]
)
