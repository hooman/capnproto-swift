// Answer key for Packed.pack and Packed.packedFrameByteCount (PR #29), written before the code.
// Expected bytes are computed by hand from encoding.md ("Packing") and the C++ packer
// (capnp/serialize-packed.c++, PackedOutputStream::write):
//
// - Each word is a tag byte (bit i set when byte i is nonzero), then its nonzero bytes.
// - Tag 0x00 is followed by the count of further all-zero words, at most 255.
// - Tag 0xFF is followed by the count of further words with at most one zero byte, at most
//   255, then those words verbatim. The run stops before a word with two or more zero bytes.
// - Runs never cross a write: C++ writes the segment table and each segment as separate
//   pieces, so runs restart at every piece boundary, and an empty segment writes nothing.
//
// The primary oracle is the live encoder: check-readers compares Packed.pack with
// `capnp encode --packed` for every oracle message and an edge-case message. These keys are
// secondary; where one disagrees with the oracle, the oracle wins.

import Testing

@testable import CapnpRuntime

/// A framed message: the segment table (count - 1, sizes, padding), then the segments.
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

/// Pack `framed` into `capacity` bytes followed by 16 guard bytes; the guards must survive.
private func pack(_ framed: [UInt8], capacity: Int? = nil) -> (
    consumed: Int, written: Int, bytes: [UInt8]
)? {
    let size = capacity ?? framed.count * 2 + 16
    var buffer = [UInt8](repeating: 0xEE, count: size + 16)
    var result: (consumed: Int, written: Int)?
    do {
        var span = buffer.mutableSpan
        var raw = span.mutableBytes
        var output = raw._mutatingExtracting(0..<size)
        result = Packed.pack(framed.span.bytes, into: &output)
    }
    #expect(buffer[size...].allSatisfy { $0 == 0xEE }, "wrote past the output")
    guard let result else { return nil }
    return (result.consumed, result.written, Array(buffer[0..<result.written]))
}

/// The packed bytes of `framed`, checked against the size query and an unpack round trip.
private func packed(_ framed: [UInt8]) -> [UInt8] {
    guard let result = pack(framed) else {
        Issue.record("pack failed")
        return []
    }
    #expect(result.consumed == framed.count)
    #expect(Packed.packedFrameByteCount(framed.span.bytes) == result.written)
    var unpacked = [UInt8](repeating: 0, count: framed.count + 64)
    var back: (consumed: Int, written: Int)?
    do {
        var span = unpacked.mutableSpan
        var raw = span.mutableBytes
        back = Packed.unpackFrame(result.bytes.span.bytes, into: &raw)
    }
    #expect(back?.consumed == result.written && back?.written == framed.count)
    #expect(Array(unpacked[0..<framed.count]) == framed, "the round trip changed the message")
    return result.bytes
}

private let allNonzero: UInt64 = 0x0807_0605_0403_0201  // bytes 01 02 ... 08

@Suite("Packed output answer key")
struct PackedOutputTests {
    /// encoding.md's example: `08 00 00 00 03 00 02 00  19 00 00 00 aa 01 00 00` packs to
    /// `51 08 03 02  31 19 aa 01`. The one-segment table (0, 2 words) packs to `10 02`.
    @Test func specExample() {
        let bytes = packed(frame([[0x0002_0003_0000_0008, 0x0000_01AA_0000_0019]]))
        #expect(bytes == [0x10, 0x02, 0x51, 0x08, 0x03, 0x02, 0x31, 0x19, 0xAA, 0x01])
    }

    /// 300 zero words: tag 0x00 with 255 more (256 words), then tag 0x00 with 43 more.
    @Test func zeroRunsStopAt255() {
        let bytes = packed(frame([[UInt64](repeating: 0, count: 300)]))
        #expect(bytes == [0x30, 0x2C, 0x01, 0x00, 0xFF, 0x00, 0x2B])
    }

    /// Three all-nonzero words: tag 0xFF, the first word, a count of 2, then two words verbatim.
    @Test func literalRun() {
        let word: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let bytes = packed(frame([[allNonzero, allNonzero, allNonzero]]))
        #expect(bytes == [0x10, 0x03, 0xFF] + word + [0x02] + word + word)
    }

    /// A word with one zero byte joins the literal run; one with two zero bytes ends it.
    @Test func literalRunStopsAtTwoZeros() {
        let oneZero: UInt64 = 0x0807_0605_0403_0200  // 00 02 03 04 05 06 07 08
        let twoZeros: UInt64 = 0x0807_0605_0403_0000  // 00 00 03 04 05 06 07 08
        let bytes = packed(frame([[allNonzero, oneZero, twoZeros]]))
        #expect(
            bytes == [0x10, 0x03, 0xFF, 1, 2, 3, 4, 5, 6, 7, 8, 0x01, 0, 2, 3, 4, 5, 6, 7, 8]
                + [0xFC, 3, 4, 5, 6, 7, 8])
    }

    /// 300 all-nonzero words: a literal run of 1 + 255 words, then one of 1 + 43.
    @Test func literalRunsStopAt255() {
        let bytes = packed(frame([[UInt64](repeating: allNonzero, count: 300)]))
        #expect(bytes.count == 3 + (1 + 8 + 1 + 255 * 8) + (1 + 8 + 1 + 43 * 8))
        #expect(Array(bytes[0..<3]) == [0x30, 0x2C, 0x01])
        #expect(bytes[3] == 0xFF && bytes[12] == 0xFF)
        let second = 13 + 255 * 8
        #expect(bytes[second] == 0xFF && bytes[second + 9] == 0x2B)
    }

    /// Two segments of one zero word each: each is its own `00 00`, not one `00 01` run.
    @Test func runsRestartAtSegmentBoundaries() {
        let bytes = packed(frame([[0], [0]]))
        #expect(bytes == [0x11, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00])
    }

    /// An empty segment writes nothing.
    @Test func emptySegmentWritesNothing() {
        let bytes = packed(frame([[0xAA], [], [0xBB]]))
        #expect(bytes == [0x11, 0x02, 0x01, 0x10, 0x01, 0x01, 0xAA, 0x01, 0xBB])
    }

    /// Only the first frame is packed; the bytes after it belong to the next message.
    @Test func packsOnlyTheFirstFrame() {
        let first = frame([[allNonzero]])
        let result = pack(first + frame([[0]]))
        #expect(result?.consumed == first.count)
        #expect(result?.bytes == packed(first))
    }

    /// Too little output fails, and nothing is written past it (the guard bytes in `pack`).
    @Test func outputTooSmall() {
        let framed = frame([[allNonzero, 0, 0x1234]])
        let needed = packed(framed).count
        #expect(pack(framed, capacity: needed - 1) == nil)
        #expect(pack(framed, capacity: needed)?.written == needed)
    }

    /// Not a frame: empty, shorter than a table word, or a table that claims more than is there.
    @Test func invalidFrames() {
        for bytes in [[], [UInt8](repeating: 0, count: 4), Array(frame([[1, 2]]).dropLast(8))] {
            #expect(Packed.packedFrameByteCount(bytes.span.bytes) == nil)
            #expect(pack(bytes) == nil)
        }
    }

    /// A message from the builder round-trips, and packs smaller than it is.
    @Test func builtMessageRoundTrips() {
        var storage = [UInt8](repeating: 0, count: 256)
        var framed: [UInt8] = []
        do {
            var span = storage.mutableSpan
            var message = MessageBuilder(storage: span.mutableBytes)
            do {
                var root = message.initRoot(dataWords: 2, pointerCount: 2)
                root.setData(UInt32(7), at: 1, default: 0)
                root.setText("packed output".utf8Span, at: 0)
                var list = root.initList(PrimitiveListBuilder<UInt16>.self, at: 1, count: 20)
                list.setElement(5, at: 19)
            }
            let bytes = message.framedBytes
            for i in 0..<bytes.byteCount {
                framed.append(bytes.load(fromByteOffset: i, as: UInt8.self))
            }
        }
        #expect(packed(framed).count < framed.count)
    }
}
