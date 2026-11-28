// capnp supplies one binary request on stdin and chooses the output working directory.
// Decode and render everything before writing; diagnostics go to stderr. This boundary
// owns host allocations and filesystem policy so the reader runtime remains freestanding.

import Foundation

private func fail(_ error: any Error) -> Never {
    FileHandle.standardError.write(Data("capnpc-swift: \(error)\n".utf8))
    exit(1)
}

if CommandLine.arguments.count > 1 {
    switch CommandLine.arguments.dropFirst().joined(separator: " ") {
    case "--version":
        print("capnpc-swift 0.4.0")
        exit(0)
    case "--help":
        print("Usage: capnp compile -o /path/to/capnpc-swift[:output-directory] schema.capnp")
        exit(0)
    default: fail(CompilerFailure("unknown arguments; use --help"))
    }
}

/// Validate `relativePath` against `root`, resolving existing parent symlinks even when
/// the target file does not yet exist (unlike `URL.resolvingSymlinksInPath()` alone on
/// nonexistent leaves), and rejecting symlink or directory destinations.
private func resolveOutputDestination(
    for relativePath: String, under root: URL, manager: FileManager
) throws -> URL {
    let rootPrefix = root.path == "/" ? "/" : root.path + "/"
    let lexical = root.appendingPathComponent(relativePath).standardizedFileURL
    guard lexical.path.hasPrefix(rootPrefix) else {
        throw CompilerFailure("output path escapes the compiler's output directory")
    }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
        throw CompilerFailure("output path escapes the compiler's output directory")
    }
    var current = root
    for component in components.dropLast() {
        let candidate = current.appendingPathComponent(String(component), isDirectory: true)
        if let attrs = try? manager.attributesOfItem(atPath: candidate.path) {
            let kind = attrs[.type] as? FileAttributeType
            if kind == .typeSymbolicLink {
                let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
                let resolvedKind =
                    (try? manager.attributesOfItem(atPath: resolved.path))?[.type]
                    as? FileAttributeType
                guard resolvedKind == .typeDirectory,
                    resolved.path == root.path || resolved.path.hasPrefix(rootPrefix)
                else {
                    throw CompilerFailure("output path escapes the compiler's output directory")
                }
                current = resolved
            } else if kind == .typeDirectory {
                current = candidate
            } else {
                throw CompilerFailure(
                    "output path parent is not a directory: \(candidate.path)")
            }
        } else {
            current = candidate
        }
    }
    // `components` is non-empty: the guard above rejected an empty path.
    let destination = current.appendingPathComponent(String(components.last!), isDirectory: false)
        .standardizedFileURL
    guard destination.path.hasPrefix(rootPrefix) else {
        throw CompilerFailure("output path escapes the compiler's output directory")
    }
    if let attrs = try? manager.attributesOfItem(atPath: destination.path) {
        let kind = attrs[.type] as? FileAttributeType
        if kind == .typeSymbolicLink {
            throw CompilerFailure("output path escapes or targets a symbolic link")
        }
        if kind == .typeDirectory {
            throw CompilerFailure("output path is an existing directory: \(destination.path)")
        }
    }
    return destination
}

do {
    // Bound input while streaming it in; readToEnd would allocate before enforcing the cap.
    let limit = 64 * 1024 * 1024
    var input = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
        guard chunk.count <= limit - input.count else {
            throw CompilerFailure("CodeGeneratorRequest exceeds the 64 MiB input limit")
        }
        input.append(chunk)
    }
    let request = try RequestDecoder.decode(input)
    let (files, warnings) = try SwiftGenerator(request: request).generate()
    for warning in warnings {
        FileHandle.standardError.write(Data("capnpc-swift: warning: \(warning)\n".utf8))
    }
    let manager = FileManager.default
    let root = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
    // Preflight every destination after rendering, walking existing parent components so
    // symlinked directories cannot be bypassed when the leaf file does not exist yet.
    // This assumes no concurrent mutation of the output directory.
    let destinations = try files.map { file in
        try resolveOutputDestination(for: file.path, under: root, manager: manager)
    }
    // Writes are atomic per file. Track newly created files and remove them on failure so
    // a failed multi-file run does not strand newly written partial output.
    var created: [URL] = []
    do {
        for (file, destination) in zip(files, destinations) {
            let existed = (try? manager.attributesOfItem(atPath: destination.path)) != nil
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(file.contents.utf8).write(to: destination, options: .atomic)
            if !existed { created.append(destination) }
        }
    } catch {
        for url in created.reversed() { try? manager.removeItem(at: url) }
        throw error
    }
} catch {
    fail(error)
}
