import Foundation

private func fail(_ error: Error) -> Never {
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
    guard #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) else {
        throw CompilerFailure("this host requires macOS 15 or later")
    }
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
    // Complete semantic validation before creating or replacing any output.
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
