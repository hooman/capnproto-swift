// Host-only measurement driver. File I/O precedes timing; the loop includes arena
// construction, validation and fixture assertions, not just scalar loads. The printed
// checksum keeps results observable and lets repeated runs be compared for correctness.
// With a fourth argument, the message is packed and the argument names its unpacked
// encoding: unpacking must reproduce it byte for byte, and each timed iteration includes
// the unpack into fixed storage.

import CapnpRuntime
import Foundation

let mode = Int32(CommandLine.arguments[2])!
let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let iterations = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 1
let packed = CommandLine.arguments.count > 4
if packed {
    let reference = try [UInt8](Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4])))
    let input = [UInt8](bytes)
    var output = [UInt8](repeating: 0xA5, count: reference.count + 64)
    let result: (consumed: Int, written: Int)?
    do {
        var span = output.mutableSpan
        var raw = span.mutableBytes
        result = Packed.unpackFrame(input.span.bytes, into: &raw)
    }
    guard let result, result.consumed == input.count, result.written == reference.count,
        Array(output[0..<result.written]) == reference
    else {
        fatalError(
            "unpacked bytes differ from the unpacked encoding: \(String(describing: result))")
    }
}
let start = DispatchTime.now().uptimeNanoseconds
var checksum: UInt64 = 0
bytes.withUnsafeBytes { raw in
    for _ in 0..<iterations {
        checksum &+=
            packed
            ? verifyPacked(raw.baseAddress!, raw.count, mode)
            : verifyReaders(raw.baseAddress!, raw.count, mode)
    }
}
let elapsed = DispatchTime.now().uptimeNanoseconds - start
print(
    "PASS \(packed ? "packed " : "")mode=\(mode) iterations=\(iterations) checksum=\(checksum) ns/decode=\(elapsed / UInt64(iterations))"
)
