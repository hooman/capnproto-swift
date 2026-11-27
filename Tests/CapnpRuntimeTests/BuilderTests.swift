// Builder answer key (D-18, build item 1), written before the builder. Every expected
// frame is computed by hand from the encoding spec (capnproto doc/encoding.md):
//
// - Frame header word: low 32 bits = segment count - 1 (0), high 32 = segment size in words.
// - Struct pointer: low 32 = signed word offset << 2 (kind 0), measured from the word after
//   the pointer; high 32 = data words | pointer count << 16.
// - A zero-sized struct gets offset -1 (low 32 = 0xFFFF_FFFC), never all zeros (null).
// - Scalars are stored XOR their schema default. Allocation is a bump allocator, so the
//   segment is laid out in call order.
//
// Raw bytes are compared directly, not through canonical form: canonicalization drops
// unreachable words, so it cannot see stale data left by re-initialization (critique #1).

import Testing

@testable import CapnpRuntime

/// The standard frame for one segment of `words`.
private func frame(_ words: [UInt64]) -> [UInt8] {
    var bytes: [UInt8] = []
    func append<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }
    append(UInt32(0))
    append(UInt32(words.count))
    for word in words { append(word) }
    return bytes
}

private struct Built {
    let framed: [UInt8]
    let error: BuildError
    let required: Int
    /// The whole backing buffer, including the 0xAA guard bytes around the storage.
    let buffer: [UInt8]
    let offset: Int
    let capacity: Int
}

/// Build into `capacity` bytes starting `offset` bytes into a 0xAA-filled buffer with 32
/// guard bytes after the storage.
private func build(
    capacity: Int = 1024, offset: Int = 0, _ body: (inout MessageBuilder) -> Void
) -> Built {
    var buffer = [UInt8](repeating: 0xAA, count: offset + capacity + 32)
    var framed: [UInt8] = []
    var error = BuildError.none
    var required = 0
    do {
        var span = buffer.mutableSpan
        var raw = span.mutableBytes
        var message = MessageBuilder(storage: raw._mutatingExtracting(offset..<offset + capacity))
        body(&message)
        error = message.error
        required = message.requiredByteCount
        let bytes = message.framedBytes
        for i in 0..<bytes.byteCount {
            framed.append(bytes.load(fromByteOffset: i, as: UInt8.self))
        }
    }
    return Built(
        framed: framed, error: error, required: required, buffer: buffer, offset: offset,
        capacity: capacity)
}

@Suite("Builder answer key")
struct BuilderTests {
    @Test func singleScalarRoot() {
        let built = build { message in
            var root = message.initRoot(dataWords: 1, pointerCount: 0)
            root.setData(UInt32(42), at: 0, default: 0)
        }
        #expect(built.error == .none)
        #expect(built.framed == frame([0x0000_0001_0000_0000, 0x2A]))
        #expect(built.required == built.framed.count)
    }

    @Test func scalarsAreStoredXorTheirDefault() {
        let built = build { message in
            var root = message.initRoot(dataWords: 2, pointerCount: 0)
            root.setData(Int16(-1), at: 0, default: 0)  // bits 0..<16
            root.setData(true, at: 16, default: false)  // bit 16
            root.setData(UInt32(7), at: 1, default: 5)  // bits 32..<64: 7 ^ 5 = 2
            root.setData(1.5 as Double, at: 1, default: 0)  // word 1
        }
        #expect(built.error == .none)
        #expect(
            built.framed
                == frame([0x0000_0002_0000_0000, 0x0000_0002_0001_FFFF, 0x3FF8_0000_0000_0000]))
    }

    @Test func boolBitsSetAndClear() {
        let built = build { message in
            var root = message.initRoot(dataWords: 1, pointerCount: 0)
            root.setData(true, at: 3, default: false)
            root.setData(true, at: 9, default: false)
            root.setData(false, at: 3, default: false)
            root.setData(false, at: 63, default: true)  // false XOR true: bit 63 set
        }
        #expect(built.framed == frame([0x0000_0001_0000_0000, 0x8000_0000_0000_0200]))
    }

    @Test func floatsKeepTheirBits() {
        let built = build { message in
            var root = message.initRoot(dataWords: 1, pointerCount: 0)
            root.setData(-0.0 as Float, at: 0, default: 0)
            root.setData(Float.infinity, at: 1, default: 0)
        }
        #expect(built.framed == frame([0x0000_0001_0000_0000, 0x7F80_0000_8000_0000]))
    }

    @Test func readBackFromTheBuilder() {
        _ = build { message in
            var root = message.initRoot(dataWords: 1, pointerCount: 0)
            root.setData(UInt32(7), at: 1, default: 5)
            #expect(root.data(at: 1, default: UInt32(5)) == 7)
            #expect(root.data(at: 0, default: UInt32(9)) == 9)
        }
    }

    @Test func nestedStruct() {
        let built = build { message in
            var root = message.initRoot(dataWords: 1, pointerCount: 1)
            root.setData(UInt64(1), at: 0, default: 0)
            var child = root.initStruct(at: 0, dataWords: 1, pointerCount: 0)
            child.setData(UInt64(2), at: 0, default: 0)
        }
        #expect(built.error == .none)
        #expect(
            built.framed
                == frame([0x0001_0001_0000_0000, 1, 0x0000_0001_0000_0000, 2]))
    }

    @Test func zeroSizedStructsUseOffsetMinusOne() {
        let child = build { message in
            var root = message.initRoot(dataWords: 0, pointerCount: 1)
            _ = root.initStruct(at: 0, dataWords: 0, pointerCount: 0)
        }
        #expect(child.framed == frame([0x0001_0000_0000_0000, 0x0000_0000_FFFF_FFFC]))
        let root = build { message in
            _ = message.initRoot(dataWords: 0, pointerCount: 0)
        }
        #expect(root.framed == frame([0x0000_0000_FFFF_FFFC]))
    }

    @Test func reinitializingAPointerZeroesTheOldObject() {
        let built = build { message in
            var root = message.initRoot(dataWords: 0, pointerCount: 1)
            do {
                var first = root.initStruct(at: 0, dataWords: 1, pointerCount: 0)
                first.setData(UInt64(0xDEAD), at: 0, default: 0)
            }
            var second = root.initStruct(at: 0, dataWords: 1, pointerCount: 0)
            second.setData(UInt64(0xBEEF), at: 0, default: 0)
        }
        #expect(built.framed == frame([0x0001_0000_0000_0000, 0x0000_0001_0000_0004, 0, 0xBEEF]))
    }

    @Test func reinitializingZeroesTheWholeSubtree() {
        let built = build { message in
            var root = message.initRoot(dataWords: 0, pointerCount: 1)
            do {
                var child = root.initStruct(at: 0, dataWords: 0, pointerCount: 1)
                var grandchild = child.initStruct(at: 0, dataWords: 1, pointerCount: 0)
                grandchild.setData(UInt64(0x77), at: 0, default: 0)
            }
            var replacement = root.initStruct(at: 0, dataWords: 1, pointerCount: 0)
            replacement.setData(UInt64(0x88), at: 0, default: 0)
        }
        #expect(
            built.framed
                == frame([0x0001_0000_0000_0000, 0x0000_0001_0000_0008, 0, 0, 0x88]))
    }

    @Test func reinitializingTheRoot() {
        let built = build { message in
            do {
                var first = message.initRoot(dataWords: 1, pointerCount: 0)
                first.setData(UInt64(5), at: 0, default: 0)
            }
            var second = message.initRoot(dataWords: 1, pointerCount: 0)
            second.setData(UInt64(6), at: 0, default: 0)
        }
        #expect(built.framed == frame([0x0000_0001_0000_0004, 0, 6]))
    }

    @Test func clearPointerZeroesTheObjectAndThePointer() {
        let built = build { message in
            var root = message.initRoot(dataWords: 0, pointerCount: 1)
            do {
                var child = root.initStruct(at: 0, dataWords: 1, pointerCount: 0)
                child.setData(UInt64(9), at: 0, default: 0)
            }
            root.clearPointer(at: 0)
        }
        #expect(built.error == .none)
        #expect(built.framed == frame([0x0001_0000_0000_0000, 0, 0]))
    }

    @Test func outOfRangeFieldsAreInvalidLayout() {
        let data = build { message in
            var root = message.initRoot(dataWords: 1, pointerCount: 0)
            root.setData(UInt64(1), at: 1, default: 0)
        }
        #expect(data.error == .invalidLayout)
        #expect(data.framed.isEmpty)
        let pointer = build { message in
            var root = message.initRoot(dataWords: 1, pointerCount: 0)
            _ = root.initStruct(at: 0, dataWords: 1, pointerCount: 0)
        }
        #expect(pointer.error == .invalidLayout)
        let size = build { message in
            _ = message.initRoot(dataWords: 65536, pointerCount: 0)
        }
        #expect(size.error == .invalidLayout)
        let negative = build { message in
            _ = message.initRoot(dataWords: -1, pointerCount: 0)
        }
        #expect(negative.error == .invalidLayout)
    }

    /// root {1 data, 1 pointer} with a child {2 data}: 8 header + 8 root pointer + 16 + 16.
    private func tree(_ message: inout MessageBuilder) {
        var root = message.initRoot(dataWords: 1, pointerCount: 1)
        root.setData(UInt64(0x1111), at: 0, default: 0)
        var child = root.initStruct(at: 0, dataWords: 2, pointerCount: 0)
        child.setData(UInt64(0x2222), at: 0, default: 0)
        child.setData(UInt64(0x3333), at: 1, default: 0)
    }

    @Test func outOfSpaceSweep() {
        let reference = build(tree)
        #expect(reference.error == .none)
        #expect(reference.required == 48)
        #expect(
            reference.framed
                == frame([0x0001_0001_0000_0000, 0x1111, 0x0000_0002_0000_0000, 0x2222, 0x3333]))
        for offset in [0, 1, 3] {
            for capacity in 0..<64 {
                let built = build(capacity: capacity, offset: offset, tree)
                #expect(built.required == 48, "capacity \(capacity) offset \(offset)")
                if capacity < 48 {
                    #expect(built.error == .outOfSpace, "capacity \(capacity) offset \(offset)")
                    #expect(built.framed.isEmpty)
                } else {
                    #expect(built.error == .none, "capacity \(capacity) offset \(offset)")
                    #expect(built.framed == reference.framed)
                }
                // Nothing outside the storage is ever written.
                #expect(built.buffer[..<offset].allSatisfy { $0 == 0xAA })
                #expect(built.buffer[(offset + capacity)...].allSatisfy { $0 == 0xAA })
            }
        }
    }

    @Test func writesAfterAFailureAreNoOps() {
        // 40 bytes hold the header, root pointer and root (32), not the child (16 more).
        let built = build(capacity: 40) { message in
            var root = message.initRoot(dataWords: 1, pointerCount: 1)
            root.setData(UInt64(0x1111), at: 0, default: 0)
            do {
                var child = root.initStruct(at: 0, dataWords: 2, pointerCount: 0)
                child.setData(UInt64(0x2222), at: 0, default: 0)
            }
            root.setData(UInt64(0x9999), at: 0, default: 0)
        }
        #expect(built.error == .outOfSpace)
        #expect(built.required == 48)
        // Root data word at storage bytes 16..<24 keeps the value written before the failure.
        let word = built.buffer[16..<24].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        #expect(word == 0x1111)
    }

    /// Chain `depth` nested structs below `parent`, each {1 data, 1 pointer}.
    private func chain(_ parent: inout StructBuilder, _ depth: Int) {
        guard depth > 0 else { return }
        var child = parent.initStruct(at: 0, dataWords: 1, pointerCount: 1)
        child.setData(UInt64(depth), at: 0, default: 0)
        chain(&child, depth - 1)
    }

    @Test func nestingLimitMatchesTheDefaultReader() {
        // The root is depth 1, so 63 more levels give 64 structs: allowed, and readable
        // with the default ReaderOptions nesting limit (64).
        var storage = [UInt64](repeating: 0, count: 2 + 64 * 2 + 4)
        var deepest: UInt64 = 0
        var readError = ReadError.invalidFrame
        var buildError = BuildError.invalidLayout
        do {
            var span = storage.mutableSpan
            var message = MessageBuilder(storage: span.mutableBytes)
            do {
                var root = message.initRoot(dataWords: 1, pointerCount: 1)
                chain(&root, 63)
            }
            buildError = message.error
            let arena = Arena(framedBytes: message.framedBytes)
            deepest = arena.withRoot { root in
                var view = root.borrowed()
                for _ in 0..<63 { view = view.pointerField(at: 0).structure() }
                return view.data(at: 0, default: UInt64(0))
            }
            readError = arena.error
        }
        #expect(buildError == .none)
        #expect(readError == .none)
        #expect(deepest == 1)

        let tooDeep = build(capacity: 4096) { message in
            var root = message.initRoot(dataWords: 1, pointerCount: 1)
            chain(&root, 64)
        }
        #expect(tooDeep.error == .nestingLimit)
    }

    @Test func roundTripThroughTheReader() {
        var storage = [UInt64](repeating: 0, count: 8)
        var values: (UInt64, UInt64, UInt64) = (0, 0, 0)
        var error = ReadError.invalidFrame
        do {
            var span = storage.mutableSpan
            var message = MessageBuilder(storage: span.mutableBytes)
            tree(&message)
            let arena = Arena(framedBytes: message.framedBytes)
            values = arena.withRoot { root in
                let child = root.pointerField(at: 0).structure()
                return (
                    root.data(at: 0, default: UInt64(0)), child.data(at: 0, default: UInt64(0)),
                    child.data(at: 1, default: UInt64(0))
                )
            }
            error = arena.error
        }
        #expect(error == .none)
        #expect(values == (0x1111, 0x2222, 0x3333))
    }
}
