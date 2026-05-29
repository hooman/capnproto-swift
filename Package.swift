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
    ]
)
