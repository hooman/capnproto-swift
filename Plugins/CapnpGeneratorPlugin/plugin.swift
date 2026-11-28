// SwiftPM build-tool plugin: turn every .capnp schema in a target into generated Swift
// readers and builders at build time. The plugin only *describes* commands; capnp runs them and
// invokes capnpc-swift, which writes relative to the output directory capnp selects.
//
// Consuming targets must still enable the Lifetimes experimental feature and depend on
// CapnpRuntime; a build-tool plugin cannot add swiftSettings to its host target.

import Foundation
import PackagePlugin

struct CapnpPluginError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
struct CapnpGeneratorPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let module = target.sourceModule else { return [] }
        let schemas = module.sourceFiles.map(\.url)
            .filter { $0.pathExtension == "capnp" }
            .map(\.standardizedFileURL)
            .sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
        guard !schemas.isEmpty else { return [] }

        let capnp = try Self.locateCapnp()
        let generator = try context.tool(named: "capnpc-swift").url
        // Resolve schema names against the target's source root so nested directories and
        // cross-schema imports keep the same relative names capnp reports in the request.
        let root = module.directoryURL.standardizedFileURL
        let outputRoot = context.pluginWorkDirectoryURL
        let rootPath = root.path(percentEncoded: false)

        return try schemas.map { schema in
            let relative = try Self.relativePath(of: schema, under: root)
            return .buildCommand(
                displayName: "Generating Swift readers for \(relative)",
                executable: capnp,
                arguments: [
                    "compile",
                    "-o",
                    "\(generator.path(percentEncoded: false)):\(outputRoot.path(percentEncoded: false))",
                    "-I", rootPath,
                    "--src-prefix=\(rootPath)",
                    schema.path(percentEncoded: false),
                ],
                // Every schema in the target is an input, not just this one: a schema's
                // imports are invisible without parsing it, and an importer whose import
                // changed must regenerate. Over-declaring rebuilds more than the minimum
                // but never leaves a stale generated file behind.
                inputFiles: schemas,
                outputFiles: [outputRoot.appending(path: relative + ".swift")]
            )
        }
    }

    /// capnp is an external native tool, so it is located rather than built. CAPNP wins,
    /// then PATH, then the usual package-manager prefixes.
    static func locateCapnp() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CAPNP"], !override.isEmpty {
            guard Self.isExecutableRegularFile(override) else {
                throw CapnpPluginError(
                    "CAPNP is set to \(override), which is not an executable file")
            }
            return URL(fileURLWithPath: override)
        }
        // Only absolute PATH entries are considered: a relative entry (e.g. ".") would
        // resolve against this plugin process's working directory, not the user's shell cwd.
        var candidates = (environment["PATH"] ?? "").split(separator: ":")
            .map { "\($0)/capnp" }
            .filter { $0.hasPrefix("/") }
        candidates += [
            "/opt/homebrew/bin/capnp", "/usr/local/bin/capnp", "/usr/bin/capnp",
            "/opt/local/bin/capnp",
        ]
        for candidate in candidates where Self.isExecutableRegularFile(candidate) {
            return URL(fileURLWithPath: candidate)
        }
        throw CapnpPluginError(
            "cannot find the capnp compiler; install it (brew install capnp) or set CAPNP to its path"
        )
    }

    /// `FileManager.isExecutableFile(atPath:)` alone also accepts directories with the
    /// search bit set, so a `CAPNP`/PATH entry pointing at a directory would silently pass
    /// this check and reach `executable:` in a build command, where SwiftPM's sandbox
    /// rejects it with an opaque diagnostic that never names CAPNP as the cause.
    static func isExecutableRegularFile(_ path: String) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue
        else {
            return false
        }
        return manager.isExecutableFile(atPath: path)
    }

    /// capnpc-swift rejects absolute and traversing output names, so every schema must sit
    /// inside the target's source directory.
    static func relativePath(of url: URL, under root: URL) throws -> String {
        let rootComponents = root.pathComponents
        let components = url.pathComponents
        guard components.count > rootComponents.count,
            Array(components.prefix(rootComponents.count)) == rootComponents
        else {
            throw CapnpPluginError(
                "schema \(url.path(percentEncoded: false)) is outside the target directory "
                    + root.path(percentEncoded: false))
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
