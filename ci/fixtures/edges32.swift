// The 32-bit runtime suites, shared by the WASI driver (ci/fixtures/wasi/main.swift) and the
// bare-metal QEMU driver (ci/qemu/main.swift), so Wasm32 and the emulated Cortex-M4 and RV32
// images run the same checks. Each suite returns its check count; a failed precondition traps.

import CapnpRuntime

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
    let badOffsets: InlineArray<2, Int32> = [0x1000_0000, -0x1000_0001]
    for index in badOffsets.indices {
        let badOffset = badOffsets[index]
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

/// Whether both packed entry points reject `packed`, the unpack into a 512-byte output.
func packedRejected(_ packed: RawSpan, options: ReaderOptions) -> Bool {
    guard Packed.unpackedFrameByteCount(packed, options: options) == nil else { return false }
    var storage = InlineArray<64, UInt64>(repeating: 0)
    var words = storage.mutableSpan
    var output = words.mutableBytes
    return Packed.unpackFrame(packed, into: &output, options: options) == nil
}

/// Copy `bytes` into `input` at `offset`; returns the offset after them.
func put<let N: Int>(
    _ bytes: InlineArray<N, UInt8>, into input: inout InlineArray<2304, UInt8>, at offset: Int
) -> Int {
    for i in 0..<N { input[offset + i] = bytes[i] }
    return offset + N
}

func verify32BitPacked() -> Int {
    precondition(Int.bitWidth == 32, "expected 32-bit platform")
    let unlimited = ReaderOptions(traversalLimitWords: .max, segmentLimit: .max)
    var input = InlineArray<2304, UInt8>(repeating: 0xFF)

    // 1. 512 segments of 0xFFFFFFFF words: 2^41 words, far past a 32-bit Int in bytes.
    // Table word 0 (count-1 = 511, size 0xFFFFFFFF), then a 0xFF literal word whose run
    // copies 254 all-0xFF words, then the last size plus padding. No body follows.
    var n = put([0xF3, 0xFF, 0x01, 0xFF, 0xFF, 0xFF, 0xFF], into: &input, at: 0)
    n += 9  // 0xFF tag and eight 0xFF bytes (the buffer is prefilled with 0xFF)
    input[n] = 254
    n += 1 + 254 * 8
    n = put([0x0F, 0xFF, 0xFF, 0xFF, 0xFF], into: &input, at: n)
    precondition(
        packedRejected(
            input.span.bytes.extracting(0..<n),
            options: ReaderOptions(traversalLimitWords: .max, segmentLimit: 512)),
        "512 maximal segments must be rejected without overflow")

    // 2. count-1 = 0xFFFFFFFF: 2^32 segments, more than even segmentLimit = UInt32.max.
    n = put([0x0F, 0xFF, 0xFF, 0xFF, 0xFF], into: &input, at: 0)
    precondition(
        packedRejected(input.span.bytes.extracting(0..<n), options: unlimited),
        "2^32 segments must be rejected without overflow")

    // 3. One segment of 0xFFFFFFFF words (32 GiB), then eight 256-word zero runs.
    n = put([0xF0, 0xFF, 0xFF, 0xFF, 0xFF], into: &input, at: 0)
    for _ in 0..<8 { n = put([0x00, 0xFF], into: &input, at: n) }
    precondition(
        packedRejected(input.span.bytes.extracting(0..<n), options: unlimited),
        "a 32 GiB segment must be rejected without overflow")

    // 4. Amplification: 11 bytes expand to 1,000 zero words. The size query reports
    // 8,008 bytes; a 512-byte output is rejected and an 8 KiB one holds the frame.
    do {
        n = put(
            [0x30, 0xE8, 0x03, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xE7], into: &input, at: 0)
        let zeros = input.span.bytes.extracting(0..<n)
        precondition(Packed.unpackedFrameByteCount(zeros) == 8008, "amplified size query")
        var small = InlineArray<64, UInt64>(repeating: 0)
        var smallWords = small.mutableSpan
        var smallOutput = smallWords.mutableBytes
        precondition(
            Packed.unpackFrame(zeros, into: &smallOutput) == nil, "512 bytes cannot hold 8,008")
        var large = InlineArray<1024, UInt64>(repeating: 0xA5A5)
        var largeWords = large.mutableSpan
        var largeOutput = largeWords.mutableBytes
        let amplified = Packed.unpackFrame(zeros, into: &largeOutput)
        precondition(amplified?.consumed == n && amplified?.written == 8008, "amplified unpack")
        let arena = Arena(framedBytes: largeOutput.bytes.extracting(0..<8008))
        arena.withRoot { root in precondition(root.data(at: 0, default: UInt32(3)) == 3) }
        let error = arena.error  // read first: precondition's autoclosure cannot capture it
        precondition(error == .none, "amplified frame must open")
    }

    // 5. A zero run crossing a segment boundary decodes on 32-bit and writes exactly
    // the frame: two table words and two zero body words.
    n = put([0x11, 0x01, 0x01, 0x01, 0x01, 0x00, 0x01], into: &input, at: 0)
    var storage = InlineArray<8, UInt64>(repeating: 0xA5A5)
    let crossing: (consumed: Int, written: Int)?
    do {
        var words = storage.mutableSpan
        var output = words.mutableBytes
        crossing = Packed.unpackFrame(input.span.bytes.extracting(0..<n), into: &output)
    }
    precondition(crossing?.consumed == 7 && crossing?.written == 32, "segment-crossing run")
    precondition(storage[2] == 0 && storage[3] == 0 && storage[4] == 0xA5A5)

    // 6. PR #24, R1, written before the fix. With segmentLimit raised to UInt32.max a frame
    // may declare 2^32 - 1 segments: a 2^31-word table. The size query must reject it, not
    // overflow a 32-bit Int counting table words: 2 MiB of zero runs expand to the 2^28 words
    // that pass Int.max bytes. Full Swift only: the input needs a heap array, larger than the
    // Embedded fixtures' fixed buffers.
    #if !hasFeature(Embedded)
        do {
            let pairs = (1 << 20) + 16
            var table = [UInt8](repeating: 0xFF, count: 5 + 2 * pairs)
            table[0] = 0x0F  // four literal bytes follow: count - 1 = 0xFFFFFFFE
            table[1] = 0xFE
            var i = 5
            while i < table.count {
                table[i] = 0x00  // tag 0x00, then run 0xFF: 256 zero table words
                i += 2
            }
            let size = Packed.unpackedFrameByteCount(table.span.bytes, options: unlimited)
            precondition(size == nil, "a 2^31-word table must be rejected without overflow")
        }
        return 6
    #else
        return 5
    #endif
}
