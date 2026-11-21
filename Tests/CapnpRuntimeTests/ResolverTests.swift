// Handwritten wire words cover valid and malformed layouts, including landing pads and
// truncated bodies that a conforming encoder would not normally produce. Keep these
// directed cases alongside the independent C++ encoder checks in ci/check-readers.py.

import Testing

@testable import CapnpRuntime

private func structWord(_ offset: Int32 = 0, data: UInt16 = 0, pointers: UInt16 = 0) -> UInt64 {
    UInt64(UInt32(bitPattern: offset) << 2) | UInt64(data) << 32 | UInt64(pointers) << 48
}
private func listWord(_ offset: Int32 = 0, size: UInt8, count: UInt32) -> UInt64 {
    UInt64(UInt32(bitPattern: offset) << 2 | 1) | UInt64(count << 3 | UInt32(size)) << 32
}
private func farWord(_ id: UInt32, position: UInt32 = 0, double: Bool = false) -> UInt64 {
    UInt64(position << 3 | (double ? 6 : 2)) | UInt64(id) << 32
}
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

struct ResolverTests {
    @Test func framedRootAndExtremeOffsets() {
        frame([[structWord(data: 1), 42]]).withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in
                #expect(root.data(at: 0, default: UInt64(0)) == 42)
                #expect(root.data(at: Int.max, default: UInt64(9)) == 9)
                #expect(root.data(at: Int.min, default: UInt64(9)) == 9)
                #expect(root.pointerField(at: Int.max).isNull == true)
                #expect(root.pointerField(at: -1).text().count == 0)
            }
            #expect(arena.error == .none)
            #expect(arena.consumedByteCount == 24)
            #expect(arena.remainingTraversalWords == Wire.traversalLimitWords - 1)
        }
    }

    @Test(arguments: [false, true])
    func farRoots(double: Bool) {
        let segments: [[UInt64]] =
            double
            ? [[farWord(1, double: true)], [farWord(2), structWord(data: 1)], [99]]
            : [[farWord(1)], [structWord(data: 1), 99]]
        frame(segments).withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in #expect(root.data(at: 0, default: UInt64(0)) == 99) }
            #expect(arena.error == .none)
            #expect(arena.remainingTraversalWords == Wire.traversalLimitWords - (double ? 3 : 2))
        }
    }

    @Test func backwardPointer() {
        frame([[structWord(1, pointers: 1), 123, structWord(-2, data: 1)]])
            .withUnsafeBytes { bytes in
                let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
                arena.withRoot { root in
                    #expect(
                        root.pointerField(at: 0).structure().data(at: 0, default: UInt64(0)) == 123)
                }
                #expect(arena.error == .none)
            }
    }

    @Test(arguments: [
        [UInt8](), [0, 0, 0, 0], [255, 255, 255, 255, 0, 0, 0, 0],
        [0, 0, 0, 0, 255, 255, 255, 127], [1, 0, 0, 0, 0, 0, 0, 0],
    ])
    func invalidFrames(_ fixture: [UInt8]) {
        fixture.withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            #expect(arena.error == .invalidFrame)
            #expect(arena.consumedByteCount == 0)
            arena.withRoot { root in #expect(root.data(at: 0, default: UInt64(3)) == 3) }
        }
    }

    @Test func concatenatedFramesAndSegmentLimit() {
        let first = frame([[0]])
        (first + frame([[0]])).withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            #expect(arena.consumedByteCount == first.count)
            #expect(arena.error == .none)
        }
        frame([[0], []]).withUnsafeBytes { bytes in
            let arena = Arena(
                framedBytes: RawSpan(_unsafeBytes: bytes),
                options: ReaderOptions(segmentLimit: 1))
            #expect(arena.error == .invalidFrame)
        }
    }

    @Test(arguments: [
        [[structWord(-2, data: 1)]],
        [[structWord(data: 1)]],
        [[farWord(5)]],
        [[farWord(1, position: 2)], [0]],
        [[farWord(1, double: true)], [farWord(2)], [0]],
        [[farWord(1, double: true)], [structWord(), structWord(data: 1)], [0]],
        [[farWord(1, double: true)], [farWord(2, double: true), structWord(data: 1)], [0]],
        [[farWord(1, double: true)], [farWord(2), structWord(1, data: 1)], [0]],
        [[farWord(1)], [farWord(0)]],
    ])
    func invalidPointerRanges(_ segments: [[UInt64]]) {
        frame(segments).withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in #expect(root.data(at: 0, default: UInt32(7)) == 7) }
            #expect(arena.error == .invalidPointer)
        }
    }

    @Test func sharedTraversalBudgetAndNesting() {
        let fixture = frame([[structWord(pointers: 1), structWord(-1, pointers: 1)]])
        fixture.withUnsafeBytes { bytes in
            let arena = Arena(
                framedBytes: RawSpan(_unsafeBytes: bytes),
                options: ReaderOptions(traversalLimitWords: 2))
            arena.withRoot { root in
                let child = root.pointerField(at: 0).structure()
                #expect(child.pointerField(at: 0).isNull == false)
                let exhausted = root.pointerField(at: 0).structure()
                #expect(exhausted.pointerField(at: 0).isNull == true)
            }
            #expect(arena.error == .traversalLimit)
            #expect(arena.remainingTraversalWords == 0)
        }
        fixture.withUnsafeBytes { bytes in
            let arena = Arena(
                framedBytes: RawSpan(_unsafeBytes: bytes),
                options: ReaderOptions(nestingLimit: 2))
            arena.withRoot { root in
                let child = root.pointerField(at: 0).structure()
                #expect(child.pointerField(at: 0).isNull == false)
                #expect(child.pointerField(at: 0).structure().pointerField(at: 0).isNull == true)
            }
            #expect(arena.error == .nestingLimit)
        }
    }

    @Test(arguments: [UInt8(0), UInt8(7)])
    func zeroSizedAmplification(_ encoding: UInt8) {
        let payload: [UInt64] =
            encoding == 0
            ? [listWord(size: 0, count: 100)]
            : [listWord(size: 7, count: 0), UInt64(100 << 2)]
        frame([[structWord(pointers: 1)] + payload]).withUnsafeBytes { bytes in
            let arena = Arena(
                framedBytes: RawSpan(_unsafeBytes: bytes),
                options: ReaderOptions(traversalLimitWords: 10))
            arena.withRoot { root in
                #expect(root.pointerField(at: 0).list(of: .inlineComposite).count == 0)
            }
            #expect(arena.error == .traversalLimit)
        }
    }

    @Test(arguments: [UInt8(0), 1, 2, 3, 4, 5, 6, 7])
    func allListEncodings(_ size: UInt8) {
        var payload: [UInt64]
        if size == 7 {
            payload = [listWord(size: 7, count: 2), structWord(2, data: 1), 11, 22]
        } else if size == 0 {
            payload = [listWord(size: 0, count: 2)]
        } else if size == 6 {
            payload = [listWord(size: 6, count: 2), structWord(-1), 0]
        } else {
            let bits = [0, 1, 8, 16, 32, 64][Int(size)]
            payload = [listWord(size: size, count: 2), 1]
            if bits == 64 { payload.append(2) } else { payload[1] |= UInt64(1) << bits }
        }
        frame([[structWord(pointers: 1)] + payload]).withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in
                let list = root.pointerField(at: 0).list(of: ElementSize(rawValue: size)!)
                #expect(list.count == 2)
                switch size {
                case 0: #expect(list.structure(at: 1).data(at: 0, default: UInt64(9)) == 9)
                case 1: #expect(list.data(at: 1, default: false) == true)
                case 2: #expect(list.data(at: 1, default: UInt8(0)) == 1)
                case 3: #expect(list.data(at: 1, default: UInt16(0)) == 1)
                case 4: #expect(list.data(at: 1, default: UInt32(0)) == 1)
                case 5: #expect(list.data(at: 1, default: UInt64(0)) == 2)
                case 6:
                    #expect(list.pointer(at: 0).isNull == false)
                    #expect(list.pointer(at: 1).isNull == true)
                default: #expect(list.structure(at: 1).data(at: 0, default: UInt64(0)) == 22)
                }
            }
            #expect(arena.error == .none)
        }
    }

    @Test func schemaListUpgrades() {
        frame([[structWord(pointers: 1), listWord(size: 3, count: 2), 0x0022_0011]])
            .withUnsafeBytes { bytes in
                let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
                arena.withRoot { root in
                    let list = root.pointerField(at: 0).list(of: .inlineComposite)
                    #expect(list.structure(at: 1).data(at: 0, default: UInt16(0)) == 0x22)
                    #expect(list.structure(at: 1).data(at: 1, default: UInt16(9)) == 9)
                }
                #expect(arena.error == .none)
            }
        frame([
            [
                structWord(pointers: 1), listWord(size: 7, count: 4),
                structWord(2, data: 1, pointers: 1), 11, 0, 22, 0,
            ]
        ])
        .withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in
                let primitive = root.pointerField(at: 0).list(of: .twoBytes)
                #expect(primitive.data(at: 1, default: UInt16(0)) == 22)
                #expect(root.pointerField(at: 0).list(of: .pointer).pointer(at: 1).isNull == true)
            }
            #expect(arena.error == .none)
        }
    }

    @Test(arguments: [
        [listWord(size: 7, count: 1), structWord(2, data: 1), 0],
        [listWord(size: 7, count: 0), UInt64(1)],
        [listWord(size: 5, count: 0x1fff_ffff)],
        [listWord(-10, size: 2, count: 1)],
    ])
    func malformedLists(_ payload: [UInt64]) {
        frame([[structWord(pointers: 1)] + payload]).withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in
                #expect(root.pointerField(at: 0).list(of: .inlineComposite).count == 0)
            }
            #expect(arena.error == .invalidPointer)
        }
    }

    @Test(arguments: [
        [UInt8(0x68), 0x69, 0], [0xc3, 0xa9, 0], [0xf0, 0x9f, 0x98, 0x80, 0],
        [0xc0, 0x80, 0], [0xed, 0xa0, 0x80, 0], [0xf4, 0x90, 0x80, 0x80, 0],
        [0xe2, 0x82, 0], [0xff, 0], [0x68, 0x69], [],
    ])
    func textValidation(_ text: [UInt8]) {
        var word: UInt64 = 0
        for (i, byte) in text.enumerated() { word |= UInt64(byte) << (i * 8) }
        frame([[structWord(pointers: 1), listWord(size: 2, count: UInt32(text.count)), word]])
            .withUnsafeBytes { bytes in
                let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
                let valid =
                    text.last == 0 && String(validating: text.dropLast(), as: UTF8.self) != nil
                arena.withRoot { root in
                    let reader = root.pointerField(at: 0).text()
                    #expect(reader.count == (valid ? text.count - 1 : 0))
                    if valid { for i in 0..<reader.count { #expect(reader[i] == text[i]) } }
                }
                #expect(arena.error == (valid ? .none : .invalidText))
            }
    }
    @Test func copiedReadersShareBudgetAndListNesting() {
        let fixture = frame([
            [
                structWord(pointers: 1), listWord(size: 7, count: 1),
                structWord(1, data: 1), 42,
            ]
        ])
        fixture.withUnsafeBytes { bytes in
            let arena = Arena(
                framedBytes: RawSpan(_unsafeBytes: bytes),
                options: ReaderOptions(traversalLimitWords: 3))
            arena.withRoot { root in
                let copy = root
                #expect(root.pointerField(at: 0).list(of: .inlineComposite).count == 1)
                #expect(copy.pointerField(at: 0).list(of: .inlineComposite).count == 0)
            }
            #expect(arena.error == .traversalLimit)
        }
        fixture.withUnsafeBytes { bytes in
            let arena = Arena(
                framedBytes: RawSpan(_unsafeBytes: bytes),
                options: ReaderOptions(nestingLimit: 2))
            arena.withRoot { root in
                let list = root.pointerField(at: 0).list(of: .inlineComposite)
                #expect(list.count == 1)
                #expect(list.structure(at: 0).data(at: 0, default: UInt64(0)) == 0)
            }
            #expect(arena.error == .nestingLimit)
        }
    }

    @Test func deterministicMalformedTraversal() {
        var random: UInt64 = 0xdeca_fbad_1234_5678
        func next() -> UInt64 {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return random
        }
        for _ in 0..<2000 {
            var words: [UInt64] = [structWord(pointers: 8)]
            for _ in 0..<16 { words.append(next()) }
            // Some pointers are near enough to reach payload rather than fail immediately.
            for i in 1...4 { words[i] = (words[i] & 0xffff_ffff_0000_0003) | UInt64(i * 4) }
            frame([words]).withUnsafeBytes { bytes in
                let arena = Arena(
                    framedBytes: RawSpan(_unsafeBytes: bytes),
                    options: ReaderOptions(traversalLimitWords: 128, nestingLimit: 8))
                arena.withRoot { root in
                    for i in 0..<8 {
                        let pointer = root.pointerField(at: i)
                        _ = pointer.structure().data(at: 0, default: UInt64(0))
                        _ = pointer.text().count
                        _ = pointer.data().count
                        for encoding in UInt8(0)...7 {
                            let list = pointer.list(of: ElementSize(rawValue: encoding)!)
                            for j in 0..<min(list.count, 8) {
                                _ = list.data(at: j, default: UInt64(0))
                                _ = list.structure(at: j).pointerField(at: 0).structure()
                                _ = list.pointer(at: j).text().count
                            }
                        }
                    }
                }
                #expect(arena.remainingTraversalWords <= 128)
            }
        }
    }

    // ListReader's index guards are exercised through PointerReader.list(of:) above with
    // in-range access; these call the raw ListReader accessors out of range directly,
    // since generated code cannot itself construct an out-of-range index.
    @Test func listIndexOutOfRangeGuards() {
        let fixture = frame([
            [
                structWord(pointers: 1), listWord(size: 4, count: 2),
                UInt64(11) | UInt64(22) << 32,
            ]
        ])
        fixture.withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in root.pointerField(at: 0).list(of: .fourBytes).void(at: 0) }
            #expect(arena.error == .none)
        }
        fixture.withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in root.pointerField(at: 0).list(of: .fourBytes).void(at: 2) }
            #expect(arena.error == .invalidIndex)
        }
        fixture.withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in
                let list = root.pointerField(at: 0).list(of: .fourBytes)
                #expect(list.data(at: -1, default: UInt32(7)) == 7)
            }
            #expect(arena.error == .invalidIndex)
        }
        fixture.withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in
                let list = root.pointerField(at: 0).list(of: .fourBytes)
                #expect(list.structure(at: 9).data(at: 0, default: UInt64(9)) == 9)
            }
            #expect(arena.error == .invalidIndex)
        }
        fixture.withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in
                #expect(root.pointerField(at: 0).list(of: .fourBytes).pointer(at: 9).isNull == true)
            }
            #expect(arena.error == .invalidIndex)
        }
    }

    @Test func listStructureRejectsBitEncoding() {
        // structure(at:) refuses a bit list explicitly: packed bits are not struct data/
        // pointer sections, unlike every other encoding, which structure(at:) will address
        // directly (correctly or not) without an encoding check of its own.
        frame([[structWord(pointers: 1), listWord(size: 1, count: 8), UInt64(0)]])
            .withUnsafeBytes { bytes in
                let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
                arena.withRoot { root in
                    let list = root.pointerField(at: 0).list(of: .bit)
                    #expect(list.structure(at: 0).data(at: 0, default: UInt64(5)) == 5)
                }
                #expect(arena.error == .typeMismatch)
            }
    }

    @Test func listPrimitiveDefaultsWhenRequestedTypeIsWiderThanStored() {
        // A direct generic data(at:default:) call for a type wider than the list's own
        // element defaults rather than reading past the element stride into the next one.
        frame([[structWord(pointers: 1), listWord(size: 4, count: 1), UInt64(42)]])
            .withUnsafeBytes { bytes in
                let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
                arena.withRoot { root in
                    let list = root.pointerField(at: 0).list(of: .fourBytes)
                    #expect(list.data(at: 0, default: UInt64(99)) == 99)
                }
                #expect(arena.error == .none)
            }
    }

    @Test func primitiveListWrapsListReader() {
        frame([
            [
                structWord(pointers: 1), listWord(size: 4, count: 2),
                UInt64(11) | UInt64(22) << 32,
            ]
        ])
        .withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in
                let list = PrimitiveList<UInt32>(
                    root.pointerField(at: 0).list(of: .fourBytes), zero: 0)
                #expect(list.count == 2)
                #expect(list[0] == 11)
                #expect(list[1] == 22)
            }
            #expect(arena.error == .none)
        }
    }

    @Test func blobReadersExposeSpansUTF8SpanAndIterable() {
        // UTF-8 "hé" = [0x68, 0xc3, 0xa9, 0x00] (3 bytes + NUL); Data = [10, 20, 30]
        let textWord: UInt64 = 0x68 | (0xc3 << 8) | (0xa9 << 16)
        let dataWord: UInt64 = 10 | (20 << 8) | (30 << 16)
        frame([
            [
                structWord(pointers: 2),
                listWord(1, size: 2, count: 4),
                listWord(1, size: 2, count: 3),
                textWord,
                dataWord,
            ]
        ])
        .withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in
                let text = root.pointerField(at: 0).text()
                #expect(text.count == 3)
                #expect(text.utf8.count == 3)
                let bytesMatch = text.utf8.bytesEqual(to: [0x68, 0xc3, 0xa9])
                #expect(bytesMatch)
                var scalars = text.utf8.makeUnicodeScalarIterator()
                #expect(scalars.next() == Unicode.Scalar("h"))
                #expect(scalars.next() == Unicode.Scalar("é"))
                #expect(scalars.next() == nil)
                var textBytes: [UInt8] = []
                var textIter = text.makeBorrowingIterator()
                while true {
                    let chunk = textIter.nextSpan(maxCount: 2)
                    if chunk.isEmpty { break }
                    for i in 0..<chunk.count { textBytes.append(chunk[i]) }
                }
                #expect(textBytes == [0x68, 0xc3, 0xa9])
                #expect(text[9] == 0)

                let data = root.pointerField(at: 1).data()
                #expect(data.count == 3)
                #expect(data.bytes.count == 3)
                #expect(data.bytes[0] == 10 && data.bytes[1] == 20 && data.bytes[2] == 30)
                var sum: UInt32 = 0
                var dataIter = data.makeBorrowingIterator()
                while true {
                    let chunk = dataIter.nextSpan(maxCount: 2)
                    if chunk.isEmpty { break }
                    for i in 0..<chunk.count { sum &+= UInt32(chunk[i]) }
                }
                #expect(sum == 60)
            }
            #expect(arena.error == .invalidIndex)
        }
    }

    @Test func genericCapnpListAndVoidListDecodeWithoutGeneratedWrappers() {
        // Root has 2 pointers: pointer 0 = List(Text) with 1 element "ok\0"; pointer 1 = List(Void) of length 3.
        let okWord: UInt64 = 0x6f | (0x6b << 8)
        frame([
            [
                structWord(pointers: 2),
                listWord(1, size: 6, count: 1),  // pointer 0 -> word 3 (pointer list)
                listWord(2, size: 0, count: 3),  // pointer 1 -> word 5 (void list)
                listWord(0, size: 2, count: 3),  // pointer element 0 -> word 4 ("ok\0")
                okWord,
            ]
        ])
        .withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in
                let texts = CapnpList<TextReader>(root.pointerField(at: 0).list(of: .pointer))
                #expect(texts.count == 1)
                let isOK = texts[0].utf8.bytesEqual(to: [0x6f, 0x6b])
                #expect(isOK)

                let voids = VoidList(root.pointerField(at: 1).list(of: .void))
                #expect(voids.count == 3)
                voids[0]
                voids[2]
            }
            #expect(arena.error == .none)
        }
    }

    @Test func floatAndAllPrimitiveMetadata() {
        let f1 = Float(1.25).bitPattern
        let f2 = Float(-3.5).bitPattern ^ Float(2.0).bitPattern
        let word = UInt64(f1) | (UInt64(f2) << 32)
        frame([[structWord(data: 1), word]]).withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in
                #expect(root.data(at: 0, default: Float(0)) == 1.25)
                #expect(root.data(at: 1, default: Float(2.0)) == -3.5)
                #expect(root.data(at: 2, default: Float(7.5)) == 7.5)
            }
            #expect(arena.error == .none)
        }
        #expect(Bool.zero == false && Bool.listElementSize == .bit)
        #expect(Int8.zero == 0 && Int8.listElementSize == .byte)
        #expect(UInt8.zero == 0 && UInt8.listElementSize == .byte)
        #expect(Int16.zero == 0 && Int16.listElementSize == .twoBytes)
        #expect(UInt16.zero == 0 && UInt16.listElementSize == .twoBytes)
        #expect(Int32.zero == 0 && Int32.listElementSize == .fourBytes)
        #expect(UInt32.zero == 0 && UInt32.listElementSize == .fourBytes)
        #expect(Int64.zero == 0 && Int64.listElementSize == .eightBytes)
        #expect(UInt64.zero == 0 && UInt64.listElementSize == .eightBytes)
        #expect(Float.zero == 0 && Float.listElementSize == .fourBytes)
        #expect(Double.zero == 0 && Double.listElementSize == .eightBytes)
    }

    @Test func unionMemberBorrowedAndNestedCapnpListElements() {
        struct ItemReader: ~Escapable, ~Sendable, CapnpStructReader {
            let reader: StructReader
            @_lifetime(copy reader)
            init(_ reader: consuming StructReader) { self.reader = reader }
            var value: UInt64 { reader.data(at: 0, default: UInt64(0)) }
        }

        // Root: 1 data word (discriminant = 2 at UInt16 offset 0, value = 77 at UInt16 offset 1),
        // 5 pointers:
        //   0: List(ItemReader) = [(value: 42)]
        //   1: List(Data) = [[0xaa, 0xbb]]
        //   2: List(List(Text)) = [["hi"]]
        //   3: List(List(Void)) = [[void, void]]
        //   4: List(List(UInt32)) = [[10, 20]]
        let rootData: UInt64 = UInt64(2) | (UInt64(77) << 16)
        let hiWord: UInt64 = 0x68 | (0x69 << 8)
        let dataWord: UInt64 = 0xaa | (0xbb << 8)
        let u32Pair: UInt64 = UInt64(10) | (UInt64(20) << 32)
        // Word layout inside segment 0:
        //   0: root pointer (data=1, ptrs=5)
        //   1: root data word
        //   2..6: root pointers 0..4
        //   7..8: ptr0 target: inlineComposite tag (count=1, data=1, ptrs=0) + item word (42)
        //   9..10: ptr1 target: pointer list (count=1) -> word 10 (dataWord)
        //   11..13: ptr2 target: pointer list (count=1) -> word 12 (pointer list count=1) -> word 13 (hiWord)
        //   14: ptr3 target: pointer list (count=1) -> void list (count=2)
        //   15..16: ptr4 target: pointer list (count=1) -> word 16 (u32Pair)
        frame([
            [
                structWord(data: 1, pointers: 5),
                rootData,
                listWord(4, size: 7, count: 1),   // slot 2 -> word 7
                listWord(5, size: 6, count: 1),   // slot 3 -> word 9
                listWord(6, size: 6, count: 1),   // slot 4 -> word 11
                listWord(8, size: 6, count: 1),   // slot 5 -> word 14
                listWord(8, size: 6, count: 1),   // slot 6 -> word 15
                structWord(1, data: 1), 42,       // words 7..8
                listWord(0, size: 2, count: 2), dataWord,  // words 9..10
                listWord(0, size: 6, count: 1),   // word 11 -> word 12
                listWord(0, size: 2, count: 3),   // word 12 -> word 13
                hiWord,                           // word 13
                listWord(0, size: 0, count: 2),   // word 14 (void list)
                listWord(0, size: 4, count: 2), u32Pair,   // words 15..16
            ]
        ])
        .withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in
                let active = root.unionMember(at: 0, equals: 2)
                let inactive = root.unionMember(at: 0, equals: 1)
                #expect(active.data(at: 1, default: UInt16(0)) == 77)
                #expect(inactive.data(at: 1, default: UInt16(9)) == 9)
                #expect(root.borrowed().data(at: 1, default: UInt16(0)) == 77)

                let items = CapnpList<ItemReader>(
                    root.pointerField(at: 0).list(of: ItemReader.listElementEncoding))
                #expect(items.count == 1 && items[0].value == 42)

                let blobs = CapnpList<DataReader>(
                    root.pointerField(at: 1).list(of: DataReader.listElementEncoding))
                #expect(blobs.count == 1 && blobs[0].count == 2)
                #expect(blobs[0][0] == 0xaa && blobs[0][1] == 0xbb)

                let nestedTexts = CapnpList<CapnpList<TextReader>>(
                    root.pointerField(at: 2).list(of: CapnpList<TextReader>.listElementEncoding))
                #expect(nestedTexts.count == 1 && nestedTexts[0].count == 1)
                let textBytes = nestedTexts[0][0].bytes
                #expect(textBytes.count == 2 && textBytes[0] == 0x68 && textBytes[1] == 0x69)

                let nestedVoids = CapnpList<VoidList>(
                    root.pointerField(at: 3).list(of: VoidList.listElementEncoding))
                #expect(nestedVoids.count == 1 && nestedVoids[0].count == 2)

                let nestedPrimitives = CapnpList<PrimitiveList<UInt32>>(
                    root.pointerField(at: 4).list(of: PrimitiveList<UInt32>.listElementEncoding))
                #expect(nestedPrimitives.count == 1 && nestedPrimitives[0].count == 2)
                #expect(nestedPrimitives[0][0] == 10 && nestedPrimitives[0][1] == 20)
            }
            #expect(arena.error == .none)

            // Exercise DataReader out-of-range subscript error path separately.
            let arena2 = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena2.withRoot { root in
                let blobs = CapnpList<DataReader>(root.pointerField(at: 1).list(of: .pointer))
                #expect(blobs[0][99] == 0)
            }
            #expect(arena2.error == .invalidIndex)
        }
    }

    @Test func unsupportedDefaultDataMismatchCapabilitiesAndArenaCharge() {
        let capWord: UInt64 = 3 | (UInt64(42) << 32)
        #expect(RawPointer(capWord).kind == .other)
        #expect(RawPointer(capWord).capabilityIndex == 42)

        // Non-null struct default -> .unsupportedDefault; null default -> .none.
        frame([[structWord(pointers: 3), 0, listWord(0, size: 4, count: 1), capWord, 0x1234]])
            .withUnsafeBytes { bytes in
                let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
                #expect(arena.charge(words: 5) == true)
                arena.withRoot { root in
                    #expect(root.pointerField(at: 0).structure(default: RawPointer(0)).pointer(at: 0).isNull)
                    // Capability pointer is non-null on wire, but dereferences cleanly as empty.
                    #expect(root.pointerField(at: 2).isNull == false)
                    #expect(root.pointerField(at: 2).structure().data(at: 0, default: UInt64(5)) == 5)
                }
                #expect(arena.error == .none)

                let badDefault = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
                badDefault.withRoot { root in
                    _ = root.pointerField(at: 0).structure(default: RawPointer(4))
                }
                #expect(badDefault.error == .unsupportedDefault)

                // data() on a fourBytes list must reject with .typeMismatch.
                let badData = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
                badData.withRoot { root in
                    #expect(root.pointerField(at: 1).data().count == 0)
                }
                #expect(badData.error == .typeMismatch)

                // Explicit arena.charge exhaustion.
                let lowBudget = Arena(
                    framedBytes: RawSpan(_unsafeBytes: bytes),
                    options: ReaderOptions(traversalLimitWords: 2, nestingLimit: -5))
                #expect(lowBudget.charge(words: 3) == false)
                #expect(lowBudget.error == .traversalLimit)
            }
    }

    @Test func unframedEmptySegmentAndCrossSegmentRejection() {
        // Empty 0-byte unframed segment has valid alignment, so withRoot hits PointerReader
        // invalid-slot validation on both isNull and resolve().
        let empty: [UInt8] = []
        empty.withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw))
            #expect(arena.error == .none)
            arena.withRoot { root in
                #expect(root.data(at: 0, default: UInt64(9)) == 9)
            }
            #expect(arena.error == .invalidPointer)
        }
        // Unaligned unframed segment fails framing immediately.
        let unaligned: [UInt8] = [1, 2, 3]
        unaligned.withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw))
            #expect(arena.error == .invalidFrame)
        }
        // Unframed Arena(bytes:segmentID: 2) rejects far pointers targeting another segment ID.
        let words: [UInt64] = [structWord(pointers: 1), farWord(0)]
        words.withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw), segmentID: 2)
            arena.withRoot { root in
                #expect(root.pointerField(at: 0).structure().data(at: 0, default: UInt64(7)) == 7)
            }
            #expect(arena.error == .invalidPointer)
        }
        // PointerReader.isNull invalid-slot path when segment lookup fails.
        frame([[structWord(pointers: 1), 0]]).withUnsafeBytes { raw in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: raw))
            arena.withRoot { root in
                let badSlot = PointerReader(
                    context: root.context, segmentID: 99, pointerByte: 0, nestingLimit: 4)
                #expect(badSlot.isNull == true)
            }
            #expect(arena.error == .invalidPointer)
        }
        #expect(widen(UInt8(0xab)) == 0xab)
    }

    @Test func multiSegmentMalformedTraversal() {
        var random: UInt64 = 0xfeed_face_cafe_beef
        func next() -> UInt64 {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return random
        }
        for _ in 0..<1000 {
            var seg0: [UInt64] = [structWord(pointers: 6)]
            for i in 0..<6 {
                let raw = next()
                switch i {
                case 0: seg0.append(farWord(UInt32(raw % 4), position: UInt32((raw >> 8) % 6)))
                case 1:
                    seg0.append(
                        farWord(UInt32(raw % 4), position: UInt32((raw >> 8) % 6), double: true))
                default: seg0.append(raw)
                }
            }
            let seg1 = (0..<6).map { _ in next() }
            let seg2 = (0..<6).map { _ in next() }
            frame([seg0, seg1, seg2]).withUnsafeBytes { bytes in
                let arena = Arena(
                    framedBytes: RawSpan(_unsafeBytes: bytes),
                    options: ReaderOptions(traversalLimitWords: 64, nestingLimit: 8))
                arena.withRoot { root in
                    for i in 0..<6 {
                        let ptr = root.pointerField(at: i)
                        _ = ptr.isNull
                        _ = ptr.structure().data(at: 0, default: UInt64(0))
                        _ = ptr.text().count
                        _ = ptr.data().count
                        let list = ptr.list(of: .inlineComposite)
                        for j in 0..<min(list.count, 4) {
                            _ = list.structure(at: j).data(at: 0, default: UInt64(0))
                            _ = list.pointer(at: j).data().count
                        }
                    }
                }
                #expect(arena.remainingTraversalWords <= 64)
            }
        }
    }
}
