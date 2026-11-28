// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "GettingStarted",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(url: "https://github.com/hooman/capnproto-swift", .upToNextMinor(from: "0.4.0"))
    ],
    targets: [
        .executableTarget(
            name: "GettingStarted",
            dependencies: [.product(name: "CapnpRuntime", package: "capnproto-swift")],
            swiftSettings: [.enableExperimentalFeature("Lifetimes")],
            plugins: [.plugin(name: "CapnpGeneratorPlugin", package: "capnproto-swift")]
        )
    ]
)
