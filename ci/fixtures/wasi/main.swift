// WASI driver for the shared fixture assertions and 32-bit runtime edge tests; builds as
// full Swift and as Embedded Swift. stdin carries an 8-byte prefix: byte 0 is the mode
// (0/1/2 = oracle verifyReaders, 99 = 32-bit overflow/clamping/malformed/unaligned suite),
// byte 1 is an optional 0...7 byte unalignment shift for the message buffer. A failed
// precondition traps, so the runner's exit status reports assertion failures.

import CapnpRuntime
import WASILibc

nonisolated(unsafe) var buffer = InlineArray<1024, UInt64>(repeating: 0)

func readInput() -> (mode: Int32, shift: Int, count: Int) {
    var total = 0
    unsafe withUnsafeMutableBytes(of: &buffer) { raw in
        while total < raw.count {
            let n = unsafe read(0, raw.baseAddress! + total, raw.count - total)
            if n <= 0 { break }
            total += n
        }
    }
    precondition(total >= 8 && total < 1024 * 8, "message missing or too large")
    let (mode, shift) = unsafe withUnsafeBytes(of: &buffer) { raw in
        (Int32(raw[0]), Int(raw[1]))
    }
    precondition(shift >= 0 && shift < 8 && total >= 8 + shift, "invalid shift")
    return (mode, shift, total - 8 - shift)
}

func structWord(_ offset: Int32 = 0, data: UInt16 = 0, pointers: UInt16 = 0) -> UInt64 {
    let low = UInt64(_truncatingBits: UInt(UInt32(bitPattern: offset) &<< 2))
    let d = UInt64(_truncatingBits: UInt(data)) &<< 32
    let p = UInt64(_truncatingBits: UInt(pointers)) &<< 48
    return low | d | p
}

func listWord(_ offset: Int32 = 0, size: UInt8, count: UInt32) -> UInt64 {
    let low = UInt64(_truncatingBits: UInt((UInt32(bitPattern: offset) &<< 2) | 1))
    let high = UInt64(_truncatingBits: UInt((count &<< 3) | UInt32(size))) &<< 32
    return low | high
}

func farWord(_ id: UInt32, position: UInt32 = 0, double: Bool = false) -> UInt64 {
    let low = UInt64(_truncatingBits: UInt((position &<< 3) | (double ? 6 : 2)))
    let high = UInt64(_truncatingBits: UInt(id)) &<< 32
    return low | high
}

func writeLE32(_ value: UInt32, to bytes: inout InlineArray<64, UInt8>, at offset: Int) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}

func writeLE64(_ value: UInt64, to bytes: inout InlineArray<64, UInt8>, at offset: Int) {
    writeLE32(UInt32(truncatingIfNeeded: value._lowWord), to: &bytes, at: offset)
    writeLE32(UInt32(truncatingIfNeeded: (value &>> 32)._lowWord), to: &bytes, at: offset + 4)
}

func withSpan(
    _ bytes: borrowing InlineArray<64, UInt8>, start: Int = 0, count: Int,
    _ body: (RawSpan) -> Void
) {
    unsafe withUnsafeBytes(of: bytes) { raw in
        let slice = unsafe UnsafeRawBufferPointer(start: raw.baseAddress! + start, count: count)
        body(unsafe RawSpan(_unsafeBytes: slice))
    }
}

func verify32BitEdges() -> Int {
    // 1. Confirm execution on a 32-bit target.
    precondition(Int.bitWidth == 32, "expected 32-bit platform")

    // 2. Single-far position > Int32.max overflow guard (PointerReader.resolve L66).
    var buf = InlineArray<64, UInt8>(repeating: 0)
    writeLE32(1, to: &buf, at: 0)  // 2 segments
    writeLE32(1, to: &buf, at: 4)  // seg 0: 1 word
    writeLE32(1, to: &buf, at: 8)  // seg 1: 1 word
    writeLE32(0, to: &buf, at: 12)  // pad
    writeLE64(farWord(1, position: 0x1000_0000), to: &buf, at: 16)  // 2^28 * 8 = 2^31 > Int32.max
    writeLE64(0, to: &buf, at: 24)
    withSpan(buf, count: 32) { span in
        let arena = Arena(framedBytes: span)
        arena.withRoot { root in
            precondition(root.data(at: 0, default: UInt32(7)) == 7)
        }
        precondition(arena.error == .invalidPointer, "single-far Int32.max guard failed")
    }

    // 3. Double-far target byte > Int32.max overflow guard (PointerReader.resolve L92).
    buf = InlineArray<64, UInt8>(repeating: 0)
    writeLE32(2, to: &buf, at: 0)  // 3 segments
    writeLE32(1, to: &buf, at: 4)  // seg 0: 1 word
    writeLE32(2, to: &buf, at: 8)  // seg 1: 2 words (double-far landing pad)
    writeLE32(1, to: &buf, at: 12)  // seg 2: 1 word
    writeLE64(farWord(1, position: 0, double: true), to: &buf, at: 16)
    writeLE64(farWord(2, position: 0x1000_0000), to: &buf, at: 24)
    writeLE64(structWord(0, data: 1), to: &buf, at: 32)
    writeLE64(0, to: &buf, at: 40)
    withSpan(buf, count: 48) { span in
        let arena = Arena(framedBytes: span)
        arena.withRoot { root in
            precondition(root.data(at: 0, default: UInt32(9)) == 9)
        }
        precondition(arena.error == .invalidPointer, "double-far Int32.max guard failed")
    }

    // 4. Signed offset * 8 overflow/underflow on 32-bit Int.
    for badOffset in [Int32(0x1000_0000), Int32(-0x1000_0001)] {
        buf = InlineArray<64, UInt8>(repeating: 0)
        writeLE32(0, to: &buf, at: 0)
        writeLE32(1, to: &buf, at: 4)
        writeLE64(structWord(badOffset, data: 1), to: &buf, at: 8)
        withSpan(buf, count: 16) { span in
            let arena = Arena(framedBytes: span)
            arena.withRoot { root in
                precondition(root.data(at: 0, default: UInt32(5)) == 5)
            }
            precondition(arena.error == .invalidPointer, "signedOffsetWords overflow guard failed")
        }
    }

    // 5. 32-bit Atomic<UInt> traversal budget clamping and > UInt32.max charge rejection.
    buf = InlineArray<64, UInt8>(repeating: 0)
    writeLE32(0, to: &buf, at: 0)
    writeLE32(2, to: &buf, at: 4)
    writeLE64(structWord(0, data: 1), to: &buf, at: 8)
    writeLE64(0xffff_ffff_ffff_ffff, to: &buf, at: 16)
    withSpan(buf, count: 24) { span in
        let maxU32 = UInt64(_truncatingBits: UInt.max)
        let clamped = Arena(
            framedBytes: span, options: ReaderOptions(traversalLimitWords: UInt64.max))
        precondition(clamped.remainingTraversalWords == maxU32, "32-bit budget clamp failed")
        precondition(clamped.charge(words: maxU32 &+ 1) == false, "huge charge must fail")
        precondition(clamped.error == .traversalLimit, "huge charge must set traversalLimit")

        let normal = Arena(framedBytes: span, options: ReaderOptions(traversalLimitWords: 10))
        normal.withRoot { root in
            precondition(root.data(at: 0, default: UInt64(0)) == 0xffff_ffff_ffff_ffff)
        }
        precondition(normal.error == .none && normal.remainingTraversalWords == 9)
    }

    // 6. Zero-sized amplification and huge 8-byte list count on 32-bit.
    buf = InlineArray<64, UInt8>(repeating: 0)
    writeLE32(0, to: &buf, at: 0)
    writeLE32(2, to: &buf, at: 4)
    writeLE64(structWord(0, pointers: 1), to: &buf, at: 8)
    writeLE64(listWord(0, size: 0, count: 0x1fff_ffff), to: &buf, at: 16)
    withSpan(buf, count: 24) { span in
        let arena = Arena(framedBytes: span)
        arena.withRoot { root in
            precondition(root.pointerField(at: 0).list(of: .void).count == 0)
        }
        precondition(arena.error == .traversalLimit, "32-bit zero-sized amplification failed")
    }
    writeLE64(listWord(0, size: 5, count: 0x1fff_ffff), to: &buf, at: 16)
    withSpan(buf, count: 24) { span in
        let arena = Arena(framedBytes: span)
        arena.withRoot { root in
            precondition(root.pointerField(at: 0).list(of: .eightBytes).count == 0)
        }
        precondition(arena.error == .invalidPointer, "32-bit huge list bounds check failed")
    }

    // 7. Unaligned (+1 byte) buffer with scalar + UTF-8 Text ("hé") + UTF8Span validation.
    buf = InlineArray<64, UInt8>(repeating: 0)
    writeLE32(0, to: &buf, at: 1)
    writeLE32(4, to: &buf, at: 5)
    writeLE64(structWord(0, data: 1, pointers: 1), to: &buf, at: 9)
    writeLE64(0x1234_5678_9abc_def0, to: &buf, at: 17)
    writeLE64(listWord(0, size: 2, count: 4), to: &buf, at: 25)
    // "hé\0" = [0x68, 0xc3, 0xa9, 0x00]
    buf[33] = 0x68
    buf[34] = 0xc3
    buf[35] = 0xa9
    buf[36] = 0x00
    withSpan(buf, start: 1, count: 40) { span in
        let arena = Arena(framedBytes: span)
        arena.withRoot { root in
            precondition(root.data(at: 0, default: UInt64(0)) == 0x1234_5678_9abc_def0)
            let text = root.pointerField(at: 0).text()
            precondition(text.count == 3 && text.utf8.count == 3)
            precondition(text[0] == 0x68 && text[1] == 0xc3 && text[2] == 0xa9)
        }
        precondition(arena.error == .none, "unaligned valid message failed")
    }

    // 8. Malformed frame + invalid UTF-8 surrogate on 32-bit.
    buf = InlineArray<64, UInt8>(repeating: 0)
    writeLE32(0xffff_ffff, to: &buf, at: 0)
    withSpan(buf, count: 8) { span in
        let arena = Arena(framedBytes: span)
        precondition(arena.error == .invalidFrame, "huge segment count must fail framing")
    }
    buf = InlineArray<64, UInt8>(repeating: 0)
    writeLE32(0, to: &buf, at: 0)
    writeLE32(3, to: &buf, at: 4)
    writeLE64(structWord(0, pointers: 1), to: &buf, at: 8)
    writeLE64(listWord(0, size: 2, count: 4), to: &buf, at: 16)
    buf[24] = 0xed
    buf[25] = 0xa0
    buf[26] = 0x80
    buf[27] = 0x00
    withSpan(buf, count: 32) { span in
        let arena = Arena(framedBytes: span)
        arena.withRoot { root in
            precondition(root.pointerField(at: 0).text().count == 0)
        }
        precondition(arena.error == .invalidText, "invalid UTF-8 must fail on 32-bit")
    }

    return 8
}

let input = readInput()
if input.mode == 99 {
    let checks = verify32BitEdges()
    print("PASS mode=99 checks=\(checks)")
} else {
    precondition(input.count > 0, "message missing")
    let checksum = unsafe withUnsafeBytes(of: &buffer) { raw in
        unsafe verifyReaders(raw.baseAddress! + 8 + input.shift, input.count, input.mode)
    }
    print("PASS mode=\(input.mode) shift=\(input.shift) checksum=\(checksum)")
}
