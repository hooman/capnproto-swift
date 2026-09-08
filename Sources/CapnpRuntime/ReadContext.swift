import Synchronization

struct Segment {
    let start: Int
    let words: Int

    func contains(_ byte: Int, words count: UInt64) -> Bool {
        guard byte >= start, (byte - start) % 8 == 0 else { return false }
        let offset = (byte - start) / 8
        return offset <= words && count <= widen(words - offset)
    }
}

struct Frame {
    let headerBytes: Int
    let segmentCount: UInt32
    let byteCount: Int
    let valid: Bool

    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    static func parse(_ bytes: RawSpan, segmentLimit: UInt32) -> Frame {
        let invalid = Frame(headerBytes: 0, segmentCount: 0, byteCount: 0, valid: false)
        guard bytes.byteCount >= 8, bytes.byteCount <= Int.max / 8 else { return invalid }
        let count = widen(UInt32(littleEndian: bytes.unsafeLoadUnaligned(
            fromByteOffset: 0, as: UInt32.self))) + 1
        guard count <= widen(segmentLimit), count <= widen(Int.max / 8) else { return invalid }
        let header = ((count + 2) / 2) * 8
        guard header <= widen(bytes.byteCount) else { return invalid }
        var total = header
        for i in 0..<Int(count._lowWord) {
            let words = UInt32(littleEndian: bytes.unsafeLoadUnaligned(
                fromByteOffset: 4 + i * 4, as: UInt32.self))
            total += widen(words) * 8
            guard total <= widen(bytes.byteCount) else { return invalid }
        }
        return Frame(headerBytes: Int(header._lowWord), segmentCount: UInt32(count._lowWord),
                     byteCount: Int(total._lowWord), valid: true)
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct ReadContext: ~Escapable {
    let bytes: RawSpan
    let state: Span<ReadState>
    let frame: Frame
    let baseID: UInt32

    @_lifetime(copy bytes, copy state)
    init(bytes: RawSpan, state: Span<ReadState>, frame: Frame, baseID: UInt32) {
        self.bytes = bytes
        self.state = state
        self.frame = frame
        self.baseID = baseID
    }

    func report(_ error: ReadError) {
        if !state.isEmpty { state[0].report(error) }
    }

    func charge(_ words: UInt64) -> Bool {
        guard !state.isEmpty else { return false }
        return state[0].charge(words)
    }

    func segment(_ id: UInt32) -> Segment? {
        guard frame.valid else { return nil }
        if frame.headerBytes == 0 {
            return id == baseID ? Segment(start: 0, words: frame.byteCount / 8) : nil
        }
        guard id < frame.segmentCount else { return nil }
        var start = frame.headerBytes
        for i in 0..<Int(id) {
            start += Int(UInt32(littleEndian: bytes.unsafeLoadUnaligned(
                fromByteOffset: 4 + i * 4, as: UInt32.self))) * 8
        }
        let words = UInt32(littleEndian: bytes.unsafeLoadUnaligned(
            fromByteOffset: 4 + Int(id) * 4, as: UInt32.self))
        return Segment(start: start, words: Int(words))
    }

    func word(at byte: Int) -> RawPointer {
        RawPointer(UInt64(littleEndian: bytes.unsafeLoadUnaligned(
            fromByteOffset: byte, as: UInt64.self)))
    }
}
