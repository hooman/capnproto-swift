// WASI driver for the shared fixture assertions; builds as full Swift and as Embedded
// Swift. stdin carries an 8-byte prefix whose first byte is the verify mode, followed by
// the framed message; the prefix keeps the message 8-byte aligned in the buffer. A
// failed precondition traps, so the runner's exit status reports assertion failures.

import WASILibc

nonisolated(unsafe) var buffer = InlineArray<1024, UInt64>(repeating: 0)

func readInput() -> (mode: Int32, count: Int) {
    var total = 0
    unsafe withUnsafeMutableBytes(of: &buffer) { raw in
        while total < raw.count {
            let n = unsafe read(0, raw.baseAddress! + total, raw.count - total)
            if n <= 0 { break }
            total += n
        }
    }
    precondition(total > 8 && total < 1024 * 8, "message missing or too large")
    let mode = unsafe withUnsafeBytes(of: &buffer) { raw in Int32(raw[0]) }
    return (mode, total - 8)
}

let input = readInput()
let checksum = unsafe withUnsafeBytes(of: &buffer) { raw in
    unsafe verifyReaders(raw.baseAddress! + 8, input.count, input.mode)
}
print("PASS mode=\(input.mode) checksum=\(checksum)")
