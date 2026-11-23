// Host driver for enums-verify.swift: each argument is `mode:path` to a framed message.

import Foundation

@main
struct EnumsMain {
    static func main() throws {
        for argument in CommandLine.arguments.dropFirst() {
            let parts = argument.split(separator: ":", maxSplits: 1)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: String(parts[1])))
            let mode = Int32(parts[0])!
            let sum = bytes.withUnsafeBytes { verifyEnums($0.baseAddress!, $0.count, mode) }
            precondition(sum == UInt64(mode + 1) * 10, "mode \(mode) returned \(sum)")
        }
        print("PASS enum readers")
    }
}
