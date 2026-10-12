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
        let segments: [[UInt64]] = double
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
                    #expect(root.pointerField(at: 0).structure().data(at: 0, default: UInt64(0)) == 123)
                }
                #expect(arena.error == .none)
            }
    }

    @Test(arguments: [
        [UInt8](), [0, 0, 0, 0], [255, 255, 255, 255, 0, 0, 0, 0],
        [0, 0, 0, 0, 255, 255, 255, 127], [1, 0, 0, 0, 0, 0, 0, 0]
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
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes),
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
        [[farWord(1)], [farWord(0)]]
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
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes),
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
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes),
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
        let payload: [UInt64] = encoding == 0
            ? [listWord(size: 0, count: 100)]
            : [listWord(size: 7, count: 0), UInt64(100 << 2)]
        frame([[structWord(pointers: 1)] + payload]).withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes),
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
            if bits == 64 { payload.append(2) }
            else { payload[1] |= UInt64(1) << bits }
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
                case 6: #expect(list.pointer(at: 0).isNull == false); #expect(list.pointer(at: 1).isNull == true)
                default: #expect(list.structure(at: 1).data(at: 0, default: UInt64(0)) == 22)
                }
            }
            #expect(arena.error == .none)
        }
    }

    @Test func schemaListUpgrades() {
        frame([[structWord(pointers: 1), listWord(size: 3, count: 2), 0x00220011]])
            .withUnsafeBytes { bytes in
                let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
                arena.withRoot { root in
                    let list = root.pointerField(at: 0).list(of: .inlineComposite)
                    #expect(list.structure(at: 1).data(at: 0, default: UInt16(0)) == 0x22)
                    #expect(list.structure(at: 1).data(at: 1, default: UInt16(9)) == 9)
                }
                #expect(arena.error == .none)
            }
        frame([[structWord(pointers: 1), listWord(size: 7, count: 4),
                structWord(2, data: 1, pointers: 1), 11, 0, 22, 0]])
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
        [listWord(size: 5, count: 0x1fffffff)],
        [listWord(-10, size: 2, count: 1)]
    ])
    func malformedLists(_ payload: [UInt64]) {
        frame([[structWord(pointers: 1)] + payload]).withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
            arena.withRoot { root in #expect(root.pointerField(at: 0).list(of: .inlineComposite).count == 0) }
            #expect(arena.error == .invalidPointer)
        }
    }

    @Test(arguments: [
        [UInt8(0x68), 0x69, 0], [0xc3, 0xa9, 0], [0xf0, 0x9f, 0x98, 0x80, 0],
        [0xc0, 0x80, 0], [0xed, 0xa0, 0x80, 0], [0xf4, 0x90, 0x80, 0x80, 0],
        [0xe2, 0x82, 0], [0xff, 0], [0x68, 0x69], []
    ])
    func textValidation(_ text: [UInt8]) {
        var word: UInt64 = 0
        for (i, byte) in text.enumerated() { word |= UInt64(byte) << (i * 8) }
        frame([[structWord(pointers: 1), listWord(size: 2, count: UInt32(text.count)), word]])
            .withUnsafeBytes { bytes in
                let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
                let valid = text.last == 0 && String(validating: text.dropLast(), as: UTF8.self) != nil
                arena.withRoot { root in
                    let reader = root.pointerField(at: 0).text()
                    #expect(reader.count == (valid ? text.count - 1 : 0))
                    if valid { for i in 0..<reader.count { #expect(reader[i] == text[i]) } }
                }
                #expect(arena.error == (valid ? .none : .invalidText))
            }
    }
    @Test func copiedReadersShareBudgetAndListNesting() {
        let fixture = frame([[structWord(pointers: 1), listWord(size: 7, count: 1),
                              structWord(1, data: 1), 42]])
        fixture.withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes),
                              options: ReaderOptions(traversalLimitWords: 3))
            arena.withRoot { root in
                let copy = root
                #expect(root.pointerField(at: 0).list(of: .inlineComposite).count == 1)
                #expect(copy.pointerField(at: 0).list(of: .inlineComposite).count == 0)
            }
            #expect(arena.error == .traversalLimit)
        }
        fixture.withUnsafeBytes { bytes in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes),
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
        var random: UInt64 = 0xdecafbad12345678
        func next() -> UInt64 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return random
        }
        for _ in 0..<2000 {
            var words: [UInt64] = [structWord(pointers: 8)]
            for _ in 0..<16 { words.append(next()) }
            // Some pointers are near enough to reach payload rather than fail immediately.
            for i in 1...4 { words[i] = (words[i] & 0xffffffff00000003) | UInt64(i * 4) }
            frame([words]).withUnsafeBytes { bytes in
                let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes),
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
        let fixture = frame([[structWord(pointers: 1), listWord(size: 4, count: 2),
                              UInt64(11) | UInt64(22) << 32]])
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
        frame([[structWord(pointers: 1), listWord(size: 4, count: 2),
               UInt64(11) | UInt64(22) << 32]])
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
}
