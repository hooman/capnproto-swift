// Host-only measurement driver. File I/O precedes timing; the loop includes arena
// construction, validation and fixture assertions, not just scalar loads. The printed
// checksum keeps results observable and lets repeated runs be compared for correctness.

import Foundation
let mode = Int32(CommandLine.arguments[2])!
let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let iterations = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 1
let start = DispatchTime.now().uptimeNanoseconds
var checksum: UInt64 = 0
bytes.withUnsafeBytes { raw in
    for _ in 0..<iterations {
        checksum &+= verifyReaders(raw.baseAddress!, raw.count, mode)
    }
}
let elapsed = DispatchTime.now().uptimeNanoseconds - start
print("PASS mode=\(mode) iterations=\(iterations) checksum=\(checksum) ns/decode=\(elapsed / UInt64(iterations))")
