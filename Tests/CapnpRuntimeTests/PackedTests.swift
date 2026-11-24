// Hand-packed frames with their expected results, written before the unpacker (answer key).
// The packed bytes are typed out tag by tag; the expected unpacked bytes come from
// `frame(_:)`, which builds the standard segment table independently of any packer.
// `capnp encode --packed` never emits runs that cross the table/body boundary or a segment
// boundary (C++ writeMessage packs the table and each segment as separate pieces, upstream
// 851c45b), so the C++ oracle in ci/check-readers.py cannot cover those cases; they are
// proven here. 32-bit overflow cases run in ci/fixtures/wasi.

import Testing

@testable import CapnpRuntime

private func frame(_ segments: [[UInt64]]) -> [UInt8] {
    var bytes: [UInt8] = []
    func append<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }
    append(UInt32(segments.count - 1))
    for segment in segments { append(UInt32(segment.count)) }
    if bytes.count % 8 != 0 { append(UInt32(0)) }
    for segment in segments { for word in segment { append(word) } }
    return bytes
}

private struct Unpacked: Equatable {
    let consumed: Int
    let written: Int
    let bytes: [UInt8]
}

/// Unpack the first frame of `packed` into a `capacity`-byte buffer and check that the
/// size query agrees with the bytes actually written.
private func unpack(
    _ packed: [UInt8], capacity: Int = 4096, options: ReaderOptions = ReaderOptions()
) -> Unpacked? {
    var buffer = [UInt8](repeating: 0xA5, count: capacity)
    let result: (consumed: Int, written: Int)?
    do {
        var span = buffer.mutableSpan
        var raw = span.mutableBytes
        result = Packed.unpackFrame(packed.span.bytes, into: &raw, options: options)
    }
    let size = Packed.unpackedFrameByteCount(packed.span.bytes, options: options)
    guard let result else { return nil }
    #expect(size == result.written, "size query disagrees with unpackFrame")
    #expect(result.consumed <= packed.count && result.written <= capacity)
    return Unpacked(
        consumed: result.consumed, written: result.written,
        bytes: Array(buffer[0..<result.written]))
}

/// A malformed frame fails both the size query and the unpack.
private func expectMalformed(
    _ packed: [UInt8], options: ReaderOptions = ReaderOptions(),
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        Packed.unpackedFrameByteCount(packed.span.bytes, options: options) == nil,
        sourceLocation: sourceLocation)
    #expect(unpack(packed, options: options) == nil, sourceLocation: sourceLocation)
}

// encoding.md's packing example as the body of a one-segment, two-word frame.
private let exampleBody: [UInt64] = [0x0002_0003_0000_0008, 0x0000_01AA_0000_0019]
private let examplePacked: [UInt8] = [
    0x10, 0x02,  // table word: count-1 = 0, size = 2
    0x51, 0x08, 0x03, 0x02,  // 08 00 00 00 03 00 02 00
    0x31, 0x19, 0xAA, 0x01,  // 19 00 00 00 aa 01 00 00
]

struct PackedTests {

    // MARK: Valid frames

    @Test func emptyFrameIsOneZeroWord() {
        #expect(
            unpack([0x00, 0x00]) == Unpacked(consumed: 2, written: 8, bytes: frame([[]])))
    }

    @Test func encodingExample() {
        #expect(
            unpack(examplePacked)
                == Unpacked(consumed: 10, written: 24, bytes: frame([exampleBody])))
    }

    @Test func zeroRunInsideBody() {
        // Body word 0 is zero, and its count byte adds two more zero words.
        #expect(
            unpack([0x10, 0x03, 0x00, 0x02])
                == Unpacked(consumed: 4, written: 32, bytes: frame([[0, 0, 0]])))
    }

    @Test func literalRunInsideBody() {
        // Body word 0 is literal (0xFF tag), and its count byte copies one more raw word.
        let packed: [UInt8] = [
            0x10, 0x02,
            0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        let body: [UInt64] = [0x0807_0605_0403_0201, 0]
        #expect(unpack(packed) == Unpacked(consumed: 20, written: 24, bytes: frame([body])))
    }

    @Test func zeroRunCrossesTableIntoBody() {
        // Three segments (sizes 1, 0, 0): the second table word is zero, and its run covers
        // segment 0's single zero word.
        #expect(
            unpack([0x11, 0x02, 0x01, 0x00, 0x01])
                == Unpacked(consumed: 5, written: 24, bytes: frame([[0], [], []])))
    }

    @Test func literalRunStartsAtTableAndCoversBody() {
        // The first table word itself carries the 0xFF tag; the run copies the body word.
        let packed: [UInt8] = [
            0xFF, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0xEF, 0xBE, 0xAD, 0xDE, 0x04, 0x03, 0x02, 0x01,
        ]
        #expect(
            unpack(packed)
                == Unpacked(consumed: 18, written: 16, bytes: frame([[0x0102_0304_DEAD_BEEF]])))
    }

    @Test func zeroRunCrossesSegmentBoundary() {
        // Two one-word segments; the header is padded to 16 bytes. Segment 0's zero word
        // starts the run and segment 1's zero word completes it.
        #expect(
            unpack([0x11, 0x01, 0x01, 0x01, 0x01, 0x00, 0x01])
                == Unpacked(consumed: 7, written: 32, bytes: frame([[0], [0]])))
    }

    @Test func concatenatedFramesReportConsumedBytes() {
        let stream = examplePacked + [0x00, 0x00] + [0x99]
        #expect(unpack(stream)?.consumed == 10)
        #expect(
            unpack(Array(stream[10...]))
                == Unpacked(consumed: 2, written: 8, bytes: frame([[]])))
    }

    @Test func unpackedFrameOpensAsArena() {
        // Root struct with one data word holding 7, built as a standard frame and packed.
        let packed: [UInt8] = [0x10, 0x02, 0x10, 0x01, 0x01, 0x07]
        var buffer = [UInt8](repeating: 0, count: 64)
        var span = buffer.mutableSpan
        var raw = span.mutableBytes
        let result = Packed.unpackFrame(packed.span.bytes, into: &raw)
        #expect(result?.consumed == 6 && result?.written == 24)
        let written = result?.written ?? 0
        let arena = Arena(framedBytes: raw.bytes.extracting(0..<written))
        // #expect cannot capture the nonescapable arena; read its results first.
        let value = arena.withRoot { $0.data(at: 0, default: UInt64(0)) }
        let error = arena.error
        let consumed = arena.consumedByteCount
        #expect(value == 7 && error == .none && consumed == 24)
    }

    // MARK: Runs past the end of the frame

    @Test func zeroRunPastFrameEndIsMalformed() {
        expectMalformed([0x00, 0x01])
        expectMalformed([0x10, 0x03, 0x00, 0x03])
    }

    @Test func literalRunPastFrameEndIsMalformed() {
        expectMalformed(
            [0x10, 0x01, 0xFF, 1, 2, 3, 4, 5, 6, 7, 8, 0x01, 1, 2, 3, 4, 5, 6, 7, 8])
    }

    // MARK: Truncation

    @Test func truncatedInputIsMalformed() {
        expectMalformed([])
        expectMalformed([0x10])  // tag without its one nonzero byte
        expectMalformed([0x00])  // zero tag without its count
        expectMalformed([0x10, 0x02])  // table promises two body words
        expectMalformed(Array(examplePacked.dropLast()))
        expectMalformed([0xFF, 1, 2, 3, 4])  // literal word cut short
        expectMalformed([0xFF, 0, 0, 0, 0, 0, 0, 0, 0])  // literal word without its count
        expectMalformed([0xFF, 0, 0, 0, 0, 0x01, 0, 0, 0, 0x01, 1, 2, 3, 4])  // raw word cut
    }

    // MARK: Limits and output

    @Test func outputTooSmallFailsUnpackOnly() {
        #expect(unpack(examplePacked, capacity: 16) == nil)
        #expect(unpack(examplePacked, capacity: 23) == nil)
        #expect(unpack(examplePacked, capacity: 24)?.written == 24)
        #expect(Packed.unpackedFrameByteCount(examplePacked.span.bytes) == 24)
    }

    @Test func segmentLimitApplies() {
        let twoSegments: [UInt8] = [0x11, 0x01, 0x01, 0x01, 0x01, 0x00, 0x01]
        expectMalformed(twoSegments, options: ReaderOptions(segmentLimit: 1))
        #expect(unpack(twoSegments, options: ReaderOptions(segmentLimit: 2))?.written == 32)
    }

    @Test func traversalLimitBoundsBodyWords() {
        // Like C++ InputStreamMessageReader: the sum of segment sizes, not the header.
        expectMalformed(examplePacked, options: ReaderOptions(traversalLimitWords: 1))
        #expect(unpack(examplePacked, options: ReaderOptions(traversalLimitWords: 2)) != nil)
    }

    @Test func frameSizeMustFitInt() {
        // Added after the answer key: the public API reaches this bound only through
        // megabytes of zero runs, so the arithmetic is checked directly.
        let limit = UInt64(Int.max / 8)
        #expect(Packed.frameByteCount(headerWords: 1, bodyWords: 2) == 24)
        #expect(Packed.frameByteCount(headerWords: 0, bodyWords: limit) == Int(limit) * 8)
        #expect(Packed.frameByteCount(headerWords: 1, bodyWords: limit) == nil)
        let maxHeader: UInt64 = (1 << 31) + 1
        let maxBody = UInt64(UInt32.max) * UInt64(UInt32.max)
        #expect(Packed.frameByteCount(headerWords: maxHeader, bodyWords: maxBody) == nil)
    }

    @Test func hostileSegmentTablesAreMalformed() {
        let unlimited = ReaderOptions(traversalLimitWords: .max, segmentLimit: .max)
        // count-1 = 0xFFFFFFFF: 2^32 segments exceed even UInt32.max.
        expectMalformed([0x0F, 0xFF, 0xFF, 0xFF, 0xFF], options: unlimited)
        // Two segments of 0xFFFFFFFF words each, with no body behind them.
        expectMalformed(
            [0xF1, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0xFF], options: unlimited)
        // The default traversal limit rejects the same table before the body is walked.
        expectMalformed([0xF1, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0xFF])
    }
}
