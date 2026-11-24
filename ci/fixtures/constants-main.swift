// Host driver for constants-verify.swift. Argument 1 is the oracle message; the enum constants
// are printed as `name=case` lines for the harness to compare with `capnp eval`.

import Foundation

@main
struct ConstantsMain {
    static func main() throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let checked = bytes.withUnsafeBytes { verifyConstants($0.baseAddress!, $0.count) }
        precondition(checked == 18, "checked \(checked) oracle fields")
        print("level=\(C.level)")
        print("color=\(C.color)")
        print("Limits.shade=\(C.LimitsReader.shade)")
    }
}
