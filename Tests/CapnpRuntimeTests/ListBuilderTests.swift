// List, text and data builder answer key (D-18 item 3), written before the code. Frames are
// computed by hand from the encoding spec (capnproto doc/encoding.md):
//
// - List pointer: low 32 = signed word offset << 2 | 1; high 32 = element count << 3 | size
//   code (0 void, 1 bit, 2 byte, 3 two bytes, 4 four bytes, 5 eight bytes, 6 pointer,
//   7 inline composite).
// - Inline composite: the pointer's count field holds the total words of the elements; the
//   tag word before them has the element count in the offset field and the element's
//   struct sizes in the high 32 bits.
// - Text is a byte list ending in NUL, so empty text is the 1-byte list [0]. Data has no NUL.
// - Counts are limited to 2^29 - 1 elements (and words, for inline composite lists).

import Testing

@testable import CapnpRuntime

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

/// Build with a root of `pointers` pointers and no data; return the frame, or the error.
private func build(
    pointers: Int = 1, capacity: Int = 1024, offset: Int = 0,
    _ body: (inout StructBuilder) -> Void
) -> (framed: [UInt8], error: BuildError, required: Int, buffer: [UInt8]) {
    var buffer = [UInt8](repeating: 0xAA, count: offset + capacity + 32)
    var framed: [UInt8] = []
    var error = BuildError.none
    var required = 0
    do {
        var span = buffer.mutableSpan
        var raw = span.mutableBytes
        var message = MessageBuilder(storage: raw._mutatingExtracting(offset..<offset + capacity))
        do {
            var root = message.initRoot(dataWords: 0, pointerCount: pointers)
            body(&root)
        }
        error = message.error
        required = message.requiredByteCount
        let bytes = message.framedBytes
        for i in 0..<bytes.byteCount {
            framed.append(bytes.load(fromByteOffset: i, as: UInt8.self))
        }
    }
    return (framed, error, required, buffer)
}

/// Root pointer to a struct of 0 data words and `pointers` pointers, at offset 0.
private func rootWord(pointers: UInt64 = 1) -> UInt64 { pointers << 48 }

/// A hand-written struct builder with one data word, standing in for generated code.
private struct ItemBuilder: ~Copyable, ~Escapable, CapnpStructBuilder {
    var builder: StructBuilder
    static var _capnpDataWords: Int { 1 }
    static var _capnpPointerCount: Int { 0 }
    @_lifetime(copy builder)
    init(_ builder: consuming StructBuilder) { self.builder = builder }
}

/// One pointer, no data: for lists whose elements own subtrees.
private struct NodeBuilder: ~Copyable, ~Escapable, CapnpStructBuilder {
    var builder: StructBuilder
    static var _capnpDataWords: Int { 0 }
    static var _capnpPointerCount: Int { 1 }
    @_lifetime(copy builder)
    init(_ builder: consuming StructBuilder) { self.builder = builder }
}

private enum Shade: UInt16, CapnpEnum {
    case light = 0
    case dark = 1
}

@Suite("List builder answer key")
struct ListBuilderTests {
    @Test func text() {
        let built = build { root in root.setText("hi".utf8Span, at: 0) }
        #expect(built.error == .none)
        #expect(built.framed == frame([rootWord(), 0x0000_001A_0000_0001, 0x6968]))
    }

    @Test func emptyTextIsOneNulByte() {
        let built = build { root in root.setText("".utf8Span, at: 0) }
        #expect(built.framed == frame([rootWord(), 0x0000_000A_0000_0001, 0]))
    }

    @Test func data() {
        let bytes: [UInt8] = [0x00, 0xFF]
        let built = build { root in root.setBytes(bytes.span, at: 0) }
        #expect(built.framed == frame([rootWord(), 0x0000_0012_0000_0001, 0xFF00]))
    }

    @Test func emptyDataHasNoBody() {
        let bytes: [UInt8] = []
        let built = build { root in root.setBytes(bytes.span, at: 0) }
        #expect(built.framed == frame([rootWord(), 0x0000_0002_0000_0001]))
    }

    @Test func longTextCrossesWords() {
        // 9 bytes plus NUL: two words, the second holding "i" and the NUL.
        let built = build { root in root.setText("abcdefghi".utf8Span, at: 0) }
        #expect(
            built.framed
                == frame([rootWord(), 0x0000_0052_0000_0001, 0x6867_6665_6463_6261, 0x69]))
    }

    @Test func primitiveList() {
        let built = build { root in
            var numbers = root.initList(PrimitiveListBuilder<UInt32>.self, at: 0, count: 3)
            numbers.setElement(0, at: 0)
            numbers.setElement(11, at: 1)
            numbers.setElement(4_000_000_000, at: 2)
            #expect(numbers.count == 3 && numbers.element(at: 1) == 11)
        }
        #expect(
            built.framed
                == frame([rootWord(), 0x0000_001C_0000_0001, 0x0000_000B_0000_0000, 0xEE6B_2800]))
    }

    @Test func boolList() {
        let built = build { root in
            var bits = root.initList(PrimitiveListBuilder<Bool>.self, at: 0, count: 3)
            bits.setElement(true, at: 0)
            bits.setElement(false, at: 1)
            bits.setElement(true, at: 2)
        }
        #expect(built.framed == frame([rootWord(), 0x0000_0019_0000_0001, 0b101]))
    }

    @Test func voidListHasNoBody() {
        let built = build { root in
            _ = root.initList(VoidListBuilder.self, at: 0, count: 3)
        }
        #expect(built.framed == frame([rootWord(), 0x0000_0018_0000_0001]))
    }

    @Test func structList() {
        let built = build { root in
            var items = root.initList(StructListBuilder<ItemBuilder>.self, at: 0, count: 2)
            do {
                var first = items.element(at: 0)
                first.builder.setData(UInt64(11), at: 0, default: 0)
            }
            var second = items.element(at: 1)
            second.builder.setData(UInt64(22), at: 0, default: 0)
        }
        #expect(
            built.framed
                == frame([rootWord(), 0x0000_0017_0000_0001, 0x0000_0001_0000_0008, 11, 22]))
    }

    @Test func textList() {
        let built = build { root in
            var texts = root.initList(TextListBuilder.self, at: 0, count: 2)
            texts.setElement("a".utf8Span, at: 0)
            texts.setElement("b".utf8Span, at: 1)
        }
        #expect(
            built.framed
                == frame([
                    rootWord(), 0x0000_0016_0000_0001, 0x0000_0012_0000_0005,
                    0x0000_0012_0000_0005, 0x61, 0x62,
                ]))
    }

    @Test func dataList() {
        let one: [UInt8] = [0x01]
        let built = build { root in
            var blobs = root.initList(DataListBuilder.self, at: 0, count: 1)
            blobs.setElement(one.span, at: 0)
        }
        #expect(
            built.framed == frame([rootWord(), 0x0000_000E_0000_0001, 0x0000_000A_0000_0001, 0x01]))
    }

    @Test func listOfLists() {
        let built = build { root in
            var matrix = root.initList(
                ListListBuilder<PrimitiveListBuilder<UInt16>>.self, at: 0, count: 2)
            do {
                var row = matrix.initElement(at: 0, count: 1)
                row.setElement(11, at: 0)
            }
            var row = matrix.initElement(at: 1, count: 2)
            row.setElement(21, at: 0)
            row.setElement(22, at: 1)
        }
        #expect(
            built.framed
                == frame([
                    rootWord(), 0x0000_0016_0000_0001, 0x0000_000B_0000_0005,
                    0x0000_0013_0000_0005, 11, 0x0016_0015,
                ]))
    }

    @Test func reinitializingAListZeroesTheOldOne() {
        let built = build { root in
            do {
                var first = root.initList(PrimitiveListBuilder<UInt32>.self, at: 0, count: 2)
                first.setElement(1, at: 0)
                first.setElement(2, at: 1)
            }
            var second = root.initList(PrimitiveListBuilder<UInt32>.self, at: 0, count: 1)
            second.setElement(3, at: 0)
        }
        #expect(built.framed == frame([rootWord(), 0x0000_000C_0000_0005, 0, 3]))
    }

    @Test func clearingAStructListZeroesElementSubtrees() {
        let built = build { root in
            do {
                var nodes = root.initList(StructListBuilder<NodeBuilder>.self, at: 0, count: 1)
                var node = nodes.element(at: 0)
                node.builder.setText("x".utf8Span, at: 0)
            }
            root.clearPointer(at: 0)
        }
        #expect(built.error == .none)
        #expect(built.framed == frame([rootWord(), 0, 0, 0, 0]))
    }

    @Test func textReplacedZeroesTheOldText() {
        let built = build { root in
            root.setText("abcdefghi".utf8Span, at: 0)
            root.setText("z".utf8Span, at: 0)
        }
        #expect(built.framed == frame([rootWord(), 0x0000_0012_0000_0009, 0, 0, 0x7A]))
    }

    @Test func limits() {
        let tooLong = build { root in
            _ = root.initList(PrimitiveListBuilder<UInt8>.self, at: 0, count: 1 << 29)
        }
        #expect(tooLong.error == .listTooLong)
        // 2^28 one-word elements are within both limits but need 2 GiB: out of space, no trap.
        let large = build { root in
            _ = root.initList(StructListBuilder<NodeBuilder>.self, at: 0, count: 1 << 28)
        }
        #expect(large.error == .outOfSpace)
        let huge = build { root in
            _ = root.initList(PrimitiveListBuilder<UInt64>.self, at: 0, count: (1 << 29) - 1)
        }
        #expect(huge.error == .outOfSpace)
        let negative = build { root in
            _ = root.initList(PrimitiveListBuilder<UInt8>.self, at: 0, count: -1)
        }
        #expect(negative.error == .invalidLayout)
        let element = build { root in
            var list = root.initList(PrimitiveListBuilder<UInt8>.self, at: 0, count: 1)
            list.setElement(1, at: 1)
        }
        #expect(element.error == .invalidLayout)
    }

    @Test func compositeWordLimit() {
        // Two pointers per element: 2^28 elements need 2^29 words, one past the limit.
        let built = build { root in
            _ = root.initList(StructListBuilder<PairOfPointers>.self, at: 0, count: 1 << 28)
        }
        #expect(built.error == .listTooLong)
    }

    @Test func outOfSpaceSweepWithText() {
        // 8 header + 8 root pointer + 8 root pointer section + 8 for "hello" and its NUL.
        let reference = build { root in root.setText("hello".utf8Span, at: 0) }
        #expect(reference.required == 32)
        for offset in [0, 1, 3] {
            for capacity in 0..<40 {
                let built = build(capacity: capacity, offset: offset) { root in
                    root.setText("hello".utf8Span, at: 0)
                }
                #expect(built.required == 32, "capacity \(capacity) offset \(offset)")
                #expect(built.error == (capacity < 32 ? .outOfSpace : .none))
                if capacity >= 32 { #expect(built.framed == reference.framed) }
                #expect(built.buffer[..<offset].allSatisfy { $0 == 0xAA })
                #expect(built.buffer[(offset + capacity)...].allSatisfy { $0 == 0xAA })
            }
        }
    }

    @Test func enumList() {
        let built = build { root in
            var shades = root.initList(EnumListBuilder<Shade>.self, at: 0, count: 2)
            shades.setElement(.dark, at: 1)
            #expect(shades.count == 2 && shades.element(at: 1) == .dark)
            #expect(shades.element(at: 0) == .light && shades.element(at: 5) == .light)
        }
        #expect(built.framed == frame([rootWord(), 0x0000_0013_0000_0001, 0x0001_0000]))
    }

    @Test func countsAndReadsWithoutStorage() {
        // After .outOfSpace every view has no storage: reads give zero, writes do nothing.
        var counts: [Int] = []
        let built = build(capacity: 24) { root in
            do {
                var numbers = root.initList(PrimitiveListBuilder<UInt64>.self, at: 0, count: 4)
                numbers.setElement(1, at: 0)
                counts += [numbers.count, Int(numbers.element(at: 0))]
            }
            do {
                var texts = root.initList(TextListBuilder.self, at: 0, count: 1)
                texts.setElement("x".utf8Span, at: 0)
                counts.append(texts.count)
            }
            do {
                var blobs = root.initList(DataListBuilder.self, at: 0, count: 1)
                let one: [UInt8] = [1]
                blobs.setElement(one.span, at: 0)
                counts.append(blobs.count)
            }
            do {
                var matrix = root.initList(ListListBuilder<VoidListBuilder>.self, at: 0, count: 1)
                counts.append(matrix.count)
                let inner = matrix.initElement(at: 0, count: 2)
                counts.append(inner.count)
            }
        }
        #expect(built.error == .outOfSpace)
        #expect(counts == [0, 0, 0, 0, 0, 0])
    }

    @Test func reinitializingZeroesEveryListEncoding() {
        // Each encoding is replaced by a null-equivalent re-set; nothing may survive.
        let built = build(pointers: 6) { root in
            do {
                var bits = root.initList(PrimitiveListBuilder<Bool>.self, at: 0, count: 70)
                bits.setElement(true, at: 69)
                var bytes = root.initList(PrimitiveListBuilder<UInt8>.self, at: 1, count: 9)
                bytes.setElement(0xFF, at: 8)
                var halves = root.initList(PrimitiveListBuilder<UInt16>.self, at: 2, count: 5)
                halves.setElement(0xFFFF, at: 4)
                var longs = root.initList(PrimitiveListBuilder<Int64>.self, at: 3, count: 2)
                longs.setElement(-1, at: 1)
                var voids = root.initList(VoidListBuilder.self, at: 4, count: 3)
                _ = voids.count
                var nodes = root.initList(StructListBuilder<NodeBuilder>.self, at: 5, count: 2)
                var node = nodes.element(at: 1)
                node.builder.setText("deep".utf8Span, at: 0)
                _ = node.builder.initList(PrimitiveListBuilder<UInt8>.self, at: 0, count: 0)
            }
            for index in 0..<6 { root.clearPointer(at: index) }
        }
        #expect(built.error == .none)
        // Root pointer, then everything else zero.
        let words = stride(from: 16, to: built.framed.count, by: 8).map { at in
            built.framed[at..<at + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        #expect(words.allSatisfy { $0 == 0 })
    }

    /// Nest struct lists below `node`: each list costs a level and its element another.
    private func nest(_ node: inout NodeBuilder, depth: Int, until limit: Int) {
        guard depth < limit else { return }
        var list = node.builder.initList(StructListBuilder<NodeBuilder>.self, at: 0, count: 1)
        var element = list.element(at: 0)
        nest(&element, depth: depth + 2, until: limit)
    }

    @Test func listDepthCountsLikeTheReader() {
        // A list costs a level and its struct elements another, as in the reader. The root
        // is level 1, so its list is 2 and the element 3; elements at 63 are allowed, and
        // a list at 64 cannot hold struct elements at 65.
        let fits = build { root in
            var list = root.initList(StructListBuilder<NodeBuilder>.self, at: 0, count: 1)
            var node = list.element(at: 0)
            nest(&node, depth: 3, until: 63)
        }
        #expect(fits.error == .none)
        let tooDeep = build(capacity: 4096) { root in
            var list = root.initList(StructListBuilder<NodeBuilder>.self, at: 0, count: 1)
            var node = list.element(at: 0)
            nest(&node, depth: 3, until: 65)
        }
        #expect(tooDeep.error == .nestingLimit)
    }

    @Test func roundTripThroughTheReader() {
        var storage = [UInt64](repeating: 0, count: 32)
        var ok = false
        var error = ReadError.invalidFrame
        do {
            var span = storage.mutableSpan
            var message = MessageBuilder(storage: span.mutableBytes)
            do {
                var root = message.initRoot(dataWords: 0, pointerCount: 3)
                root.setText("hi!".utf8Span, at: 0)
                var numbers = root.initList(PrimitiveListBuilder<UInt32>.self, at: 1, count: 2)
                numbers.setElement(7, at: 1)
                var texts = root.initList(TextListBuilder.self, at: 2, count: 1)
                texts.setElement("t".utf8Span, at: 0)
            }
            let arena = Arena(framedBytes: message.framedBytes)
            ok = arena.withRoot { root in
                let text = root.pointerField(at: 0).text()
                let numbers = PrimitiveList(
                    root.pointerField(at: 1).list(of: .fourBytes), zero: UInt32(0))
                let texts = root.pointerField(at: 2).list(of: .pointer)
                return text.utf8.count == 3 && numbers.count == 2 && numbers[1] == 7
                    && texts.count == 1
            }
            error = arena.error
        }
        #expect(ok && error == .none)
    }
}

/// Two pointers, no data: for the inline-composite word limit.
private struct PairOfPointers: ~Copyable, ~Escapable, CapnpStructBuilder {
    var builder: StructBuilder
    static var _capnpDataWords: Int { 0 }
    static var _capnpPointerCount: Int { 2 }
    @_lifetime(copy builder)
    init(_ builder: consuming StructBuilder) { self.builder = builder }
}
