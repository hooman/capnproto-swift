// Validate the frame once, then locate segments by summing its size table on demand.
// This trades O(segment ID) lookup for zero auxiliary allocation; segmentLimit bounds
// the scan. Offsets are absolute bytes in the borrowed buffer, sizes are wire words.

import Synchronization

struct Segment {
    let start: Int
    let words: Int

    func contains(_ byte: Int, words count: UInt64) -> Bool {
        guard byte >= start, (byte - start) % 8 == 0 else { return false }
        let offset = (byte - start) / 8
        // Subtract within the segment rather than adding an untrusted size to an address.
        // An empty object may start exactly at the end of its segment.
        return offset <= words && count <= widen(words - offset)
    }
}

struct Frame {
    let headerBytes: Int
    let segmentCount: UInt32
    let byteCount: Int
    let valid: Bool

    static func parse(_ bytes: RawSpan, segmentLimit: UInt32) -> Frame {
        let invalid = Frame(headerBytes: 0, segmentCount: 0, byteCount: 0, valid: false)
        guard bytes.byteCount >= 8, bytes.byteCount <= Int.max / 8 else { return invalid }
        let count = widen(bytes.load(fromByteOffset: 0, as: UInt32.self, .littleEndian)) + 1
        guard count <= widen(segmentLimit), count <= widen(Int.max / 8) else { return invalid }
        // One count-minus-one entry plus N sizes, padded to a whole 64-bit word.
        let header = ((count + 2) / 2) * 8
        guard header <= widen(bytes.byteCount) else { return invalid }
        var total = header
        for i in 0..<Int(count._lowWord) {
            let words = bytes.load(fromByteOffset: 4 + i * 4, as: UInt32.self, .littleEndian)
            total += widen(words) * 8
            guard total <= widen(bytes.byteCount) else { return invalid }
        }
        return Frame(
            headerBytes: Int(header._lowWord), segmentCount: UInt32(count._lowWord),
            byteCount: Int(total._lowWord), valid: true)
    }
}

struct ReadContext: ~Escapable, ~Sendable {
    let bytes: RawSpan
    let state: Ref<ReadState>
    let frame: Frame
    let baseID: UInt32

    @_lifetime(copy bytes, copy state)
    init(bytes: RawSpan, state: Ref<ReadState>, frame: Frame, baseID: UInt32) {
        self.bytes = bytes
        self.state = state
        self.frame = frame
        self.baseID = baseID
    }

    func report(_ error: ReadError) {
        state.value.report(error)
    }

    func charge(_ words: UInt64) -> Bool {
        state.value.charge(words)
    }

    func segment(_ id: UInt32) -> Segment? {
        guard frame.valid else { return nil }
        if frame.headerBytes == 0 {
            return id == baseID ? Segment(start: 0, words: frame.byteCount / 8) : nil
        }
        guard id < frame.segmentCount else { return nil }
        var start = frame.headerBytes
        for i in 0..<Int(id) {
            start += Int(bytes.load(fromByteOffset: 4 + i * 4, as: UInt32.self, .littleEndian)) * 8
        }
        let words = bytes.load(fromByteOffset: 4 + Int(id) * 4, as: UInt32.self, .littleEndian)
        return Segment(start: start, words: Int(words))
    }

    // Caller must have validated a complete word at this absolute byte offset.
    func word(at byte: Int) -> RawPointer {
        RawPointer(bytes.load(fromByteOffset: byte, as: UInt64.self, .littleEndian))
    }
}
