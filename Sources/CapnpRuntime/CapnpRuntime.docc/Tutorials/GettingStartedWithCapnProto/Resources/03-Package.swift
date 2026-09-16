// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GettingStarted",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/hooman/capnproto-swift", branch: "main")
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
