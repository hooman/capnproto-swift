// WASI driver for the shared fixture assertions and 32-bit runtime edge tests; builds as
// full Swift and as Embedded Swift. stdin carries an 8-byte prefix: byte 0 is the mode
// (0/1/2 = oracle verifyReaders, 97 = 32-bit builder suite in ci/fixtures/build32.swift,
// 98 = 32-bit packed suite, 99 = 32-bit overflow/clamping/malformed/unaligned suite; both in
// ci/fixtures/edges32.swift), byte 1 is an
// optional 0...7 byte unalignment shift for the message buffer, and a nonzero byte 2 marks
// the message as packed. A failed precondition traps, so the runner's exit status reports
// assertion failures.

import CapnpRuntime
import WASILibc

nonisolated(unsafe) var buffer = InlineArray<1024, UInt64>(repeating: 0)

func readInput() -> (mode: Int32, shift: Int, packed: Bool, count: Int) {
    var total = 0
    unsafe withUnsafeMutableBytes(of: &buffer) { raw in
        while total < raw.count {
            let n = unsafe read(0, raw.baseAddress! + total, raw.count - total)
            if n <= 0 { break }
            total += n
        }
    }
    precondition(total >= 8 && total < 1024 * 8, "message missing or too large")
    let (mode, shift, packed) = unsafe withUnsafeBytes(of: &buffer) { raw in
        (Int32(raw[0]), Int(raw[1]), raw[2] != 0)
    }
    precondition(shift >= 0 && shift < 8 && total >= 8 + shift, "invalid shift")
    return (mode, shift, packed, total - 8 - shift)
}

let input = readInput()
if input.mode == 99 {
    let checks = verify32BitEdges()
    print("PASS mode=99 checks=\(checks)")
} else if input.mode == 98 {
    let checks = verify32BitPacked()
    print("PASS mode=98 checks=\(checks)")
} else if input.mode == 97 {
    let checks = verify32BitBuilders()
    print("PASS mode=97 checks=\(checks)")
} else {
    precondition(input.count > 0, "message missing")
    let checksum = unsafe withUnsafeBytes(of: &buffer) { raw in
        let start = unsafe raw.baseAddress! + 8 + input.shift
        return input.packed
            ? unsafe verifyPacked(start, input.count, input.mode)
            : unsafe verifyReaders(start, input.count, input.mode)
    }
    let kind = input.packed ? " packed" : ""
    print("PASS\(kind) mode=\(input.mode) shift=\(input.shift) checksum=\(checksum)")
}
