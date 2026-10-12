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
    case "--version": print("capnpc-swift 0.1.0-dev"); exit(0)
    case "--help":
        print("Usage: capnp compile -o /path/to/capnpc-swift[:output-directory] schema.capnp")
        exit(0)
    default: fail(CompilerFailure("unknown arguments; use --help"))
    }
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
    let files = try SwiftGenerator(request: request).generate()
    let manager = FileManager.default
    let root = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
    // Preflight every destination after rendering. Resolve existing symlinks as well as
    // lexical .. components; this assumes no concurrent mutation of the output directory.
    // Writes below are atomic per file, not a transaction across all generated files.
    let destinations = try files.map { file -> URL in
        let destination = root.appendingPathComponent(file.path).standardizedFileURL
            .resolvingSymlinksInPath()
        guard destination.path.hasPrefix(root.path + "/") else {
            throw CompilerFailure("output path escapes the compiler's output directory")
        }
        return destination
    }
    for (file, destination) in zip(files, destinations) {
        try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        try Data(file.contents.utf8).write(to: destination, options: .atomic)
    }
} catch {
    fail(error)
}
