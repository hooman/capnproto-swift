// The 32-bit builder suite (D-18 item 1), shared like edges32.swift by the WASI driver and the
// bare-metal QEMU driver, so Wasm32, Cortex-M4 and RV32 build with a 32-bit Int. It repeats
// the host answer key's layouts (Tests/CapnpRuntimeTests/BuilderTests.swift) and INVARIANT 7's
// checks: the out-of-space sweep with guard bytes, writes after a failure, the nesting limit
// and invalid sizes. Storage is InlineArray, with no array literals: this file compiles with
// -no-allocations in the QEMU image. Returns the check count; a failed precondition traps.

import CapnpRuntime

/// Word `index` of a framed message; index 0 is the frame header.
func frameWord(_ framed: RawSpan, _ index: Int) -> UInt64 {
    framed.load(fromByteOffset: index * 8, as: UInt64.self, .littleEndian)
}

/// The header of a one-segment frame of `words` words.
func headerWord(_ words: UInt32) -> UInt64 { UInt64(_truncatingBits: UInt(words)) &<< 32 }

/// root {1 data, 1 pointer} with a child {2 data}: 8 header + 8 root pointer + 16 + 16 bytes.
func buildTree(_ message: inout MessageBuilder) {
    var root = message.initRoot(dataWords: 1, pointerCount: 1)
    root.setData(UInt64(0x1111), at: 0, default: 0)
    var child = root.initStruct(at: 0, dataWords: 2, pointerCount: 0)
    child.setData(UInt64(0x2222), at: 0, default: 0)
    child.setData(UInt64(0x3333), at: 1, default: 0)
}

func buildChain(_ parent: inout StructBuilder, _ depth: Int) {
    guard depth > 0 else { return }
    var child = parent.initStruct(at: 0, dataWords: 1, pointerCount: 1)
    child.setData(UInt64(_truncatingBits: UInt(depth)), at: 0, default: 0)
    buildChain(&child, depth - 1)
}

func verify32BitBuilders() -> Int {
    var checks = 0

    // 1. The tree's exact frame.
    do {
        var storage = InlineArray<8, UInt64>(repeating: 0)
        var span = storage.mutableSpan
        var message = MessageBuilder(storage: span.mutableBytes)
        buildTree(&message)
        let framed = message.framedBytes
        precondition(message.error == .none && message.requiredByteCount == 48)
        precondition(framed.byteCount == 48 && frameWord(framed, 0) == headerWord(5))
        precondition(frameWord(framed, 1) == structWord(data: 1, pointers: 1))
        precondition(frameWord(framed, 2) == 0x1111)
        precondition(frameWord(framed, 3) == structWord(data: 2))
        precondition(frameWord(framed, 4) == 0x2222 && frameWord(framed, 5) == 0x3333)
        checks += 1
    }

    // 2. Re-initializing zeroes the old subtree; a zero-sized struct gets offset -1.
    do {
        var storage = InlineArray<8, UInt64>(repeating: 0)
        var span = storage.mutableSpan
        var message = MessageBuilder(storage: span.mutableBytes)
        do {
            var root = message.initRoot(dataWords: 0, pointerCount: 2)
            do {
                var child = root.initStruct(at: 0, dataWords: 0, pointerCount: 1)
                var grandchild = child.initStruct(at: 0, dataWords: 1, pointerCount: 0)
                grandchild.setData(UInt64(0x77), at: 0, default: 0)
            }
            var replacement = root.initStruct(at: 0, dataWords: 1, pointerCount: 0)
            replacement.setData(UInt64(0x88), at: 0, default: 0)
        }
        _ = message.initRoot(dataWords: 0, pointerCount: 0)
        let framed = message.framedBytes
        precondition(message.error == .none && framed.byteCount == 56)
        // The second root is zero-sized; the first root and its subtree are all zero.
        precondition(frameWord(framed, 1) == 0x0000_0000_FFFF_FFFC)
        var word = 2
        while word < 7 {
            precondition(frameWord(framed, word) == 0)
            word += 1
        }
        checks += 1
    }

    // 3. Out of space: every capacity below 48 fails with requiredByteCount 48 and writes
    // nothing outside the storage, at offsets 0, 1 and 3; 48 and up succeed.
    var offset = 0
    while offset < 4 {
        var capacity = 0
        while capacity < 64 {
            var buffer = InlineArray<128, UInt8>(repeating: 0xAA)
            var error = BuildError.none
            var required = 0
            var count = 0
            do {
                var span = buffer.mutableSpan
                var raw = span.mutableBytes
                var message = MessageBuilder(
                    storage: raw._mutatingExtracting(offset..<offset + capacity))
                buildTree(&message)
                error = message.error
                required = message.requiredByteCount
                count = message.framedBytes.byteCount
            }
            precondition(required == 48)
            precondition(capacity < 48 ? error == .outOfSpace && count == 0 : error == .none)
            var index = 0
            while index < 128 {
                if index < offset || index >= offset + capacity {
                    precondition(buffer[index] == 0xAA)
                }
                index += 1
            }
            capacity += 1
        }
        offset += offset == 1 ? 2 : 1  // 0, 1, 3
    }
    checks += 1

    // 4. Writes after a failure are no-ops: 40 bytes hold the root, not the child.
    do {
        var storage = InlineArray<5, UInt64>(repeating: 0)
        var error = BuildError.none
        do {
            var span = storage.mutableSpan
            var message = MessageBuilder(storage: span.mutableBytes)
            do {
                var root = message.initRoot(dataWords: 1, pointerCount: 1)
                root.setData(UInt64(0x1111), at: 0, default: 0)
                do {
                    var child = root.initStruct(at: 0, dataWords: 2, pointerCount: 0)
                    child.setData(UInt64(0x2222), at: 0, default: 0)
                }
                root.setData(UInt64(0x9999), at: 0, default: 0)
            }
            error = message.error
        }
        precondition(error == .outOfSpace && storage[2] == 0x1111)
        checks += 1
    }

    // 5. 64 nested levels build and read back with the default nesting limit; 65 don't build.
    do {
        var storage = InlineArray<136, UInt64>(repeating: 0)
        var span = storage.mutableSpan
        var message = MessageBuilder(storage: span.mutableBytes)
        do {
            var root = message.initRoot(dataWords: 1, pointerCount: 1)
            buildChain(&root, 63)
        }
        precondition(message.error == .none)
        let arena = Arena(framedBytes: message.framedBytes)
        let deepest = arena.withRoot { root in
            var view = root.borrowed()
            var level = 0
            while level < 63 {
                view = view.pointerField(at: 0).structure()
                level += 1
            }
            return view.data(at: 0, default: UInt64(0))
        }
        let readError = arena.error  // not inside the autoclosure: arena is ~Escapable
        precondition(readError == .none && deepest == 1)
    }
    do {
        // Re-initializing the root zeroes the whole 64-level chain, down to the deepest body
        // (the zeroing recursion's worst case, so the QEMU stack figure includes it).
        var storage = InlineArray<136, UInt64>(repeating: 0)
        var error = BuildError.invalidLayout
        do {
            var span = storage.mutableSpan
            var message = MessageBuilder(storage: span.mutableBytes)
            do {
                var root = message.initRoot(dataWords: 1, pointerCount: 1)
                buildChain(&root, 63)
            }
            _ = message.initRoot(dataWords: 0, pointerCount: 0)
            error = message.error
        }
        precondition(error == .none && storage[1] == 0x0000_0000_FFFF_FFFC)
        var word = 2
        while word < 136 {
            precondition(storage[word] == 0)
            word += 1
        }
    }
    do {
        // Fresh storage with room for 65 levels, so the limit, not space, stops it.
        var storage = InlineArray<136, UInt64>(repeating: 0)
        var span = storage.mutableSpan
        var message = MessageBuilder(storage: span.mutableBytes)
        do {
            var root = message.initRoot(dataWords: 1, pointerCount: 1)
            buildChain(&root, 64)
        }
        precondition(message.error == .nestingLimit)
        checks += 1
    }

    // 6. Sizes outside the wire range are invalid layouts, not traps.
    do {
        var storage = InlineArray<4, UInt64>(repeating: 0)
        var span = storage.mutableSpan
        var message = MessageBuilder(storage: span.mutableBytes)
        do {
            var root = message.initRoot(dataWords: 65536, pointerCount: -1)
            root.setData(UInt64(1), at: Int.max, default: 0)
            _ = root.initStruct(at: Int.min, dataWords: Int.max, pointerCount: Int.max)
        }
        precondition(message.error == .invalidLayout && message.framedBytes.byteCount == 0)
        checks += 1
    }

    // 7. Every scalar type round-trips through an Arena, including XOR defaults.
    do {
        var storage = InlineArray<10, UInt64>(repeating: 0)
        var span = storage.mutableSpan
        var message = MessageBuilder(storage: span.mutableBytes)
        do {
            var root = message.initRoot(dataWords: 6, pointerCount: 0)
            root.setData(UInt8(0xAB), at: 0, default: 0)
            root.setData(Int8(-5), at: 1, default: 3)
            root.setData(UInt16(0xBEEF), at: 1, default: 0)
            root.setData(UInt32(0xDEAD_BEEF), at: 1, default: 7)
            root.setData(Int16(-300), at: 4, default: 0)
            root.setData(true, at: 80, default: false)
            root.setData(Int32(-70_000), at: 3, default: 0)
            root.setData(Float(-2.5), at: 4, default: 1)
            root.setData(Double(0.1), at: 3, default: 0)
            root.setData(Int64.min, at: 4, default: 0)
            root.setData(UInt64.max, at: 5, default: 1)
        }
        precondition(message.error == .none)
        let arena = Arena(framedBytes: message.framedBytes)
        let ok = arena.withRoot { root in
            root.data(at: 0, default: UInt8(0)) == 0xAB && root.data(at: 1, default: Int8(3)) == -5
                && root.data(at: 1, default: UInt16(0)) == 0xBEEF
                && root.data(at: 1, default: UInt32(7)) == 0xDEAD_BEEF
                && root.data(at: 4, default: Int16(0)) == -300
                && root.data(at: 80, default: false)
                && root.data(at: 3, default: Int32(0)) == -70_000
                && root.data(at: 4, default: Float(1)) == -2.5
                && root.data(at: 3, default: Double(0)) == 0.1
                && root.data(at: 4, default: Int64(0)) == .min
                && root.data(at: 5, default: UInt64(1)) == .max
        }
        let readError = arena.error
        precondition(ok && readError == .none)
        checks += 1
    }
    // 8. Lists, text and data (item 3): an exact frame, and over-limit sizes that would
    // overflow a 32-bit Int record an error instead of trapping.
    do {
        var storage = InlineArray<8, UInt64>(repeating: 0)
        var span = storage.mutableSpan
        var message = MessageBuilder(storage: span.mutableBytes)
        do {
            var root = message.initRoot(dataWords: 0, pointerCount: 2)
            root.setText("hi".utf8Span, at: 0)
            var numbers = root.initList(PrimitiveListBuilder<UInt16>.self, at: 1, count: 3)
            numbers.setElement(0xBEEF, at: 2)
        }
        let framed = message.framedBytes
        precondition(message.error == .none && framed.byteCount == 48)
        precondition(frameWord(framed, 2) == 0x0000_001A_0000_0005)  // text: 3 bytes, +1 word
        precondition(frameWord(framed, 3) == 0x0000_001B_0000_0005)  // 3 two-byte elements
        precondition(frameWord(framed, 4) == 0x6968 && frameWord(framed, 5) == 0xBEEF_0000_0000)
    }
    do {
        var storage = InlineArray<4, UInt64>(repeating: 0)
        var span = storage.mutableSpan
        var message = MessageBuilder(storage: span.mutableBytes)
        do {
            var root = message.initRoot(dataWords: 0, pointerCount: 1)
            _ = root.initList(PrimitiveListBuilder<UInt64>.self, at: 0, count: (1 << 29) - 1)
        }
        // More than a 32-bit builder can ever use (about 256 MiB): no retry can succeed (#24, F4).
        precondition(message.error == .messageTooLarge)
    }
    do {
        var storage = InlineArray<4, UInt64>(repeating: 0)
        var span = storage.mutableSpan
        var message = MessageBuilder(storage: span.mutableBytes)
        do {
            var root = message.initRoot(dataWords: 0, pointerCount: 1)
            _ = root.initList(PrimitiveListBuilder<UInt8>.self, at: 0, count: 1 << 29)
        }
        precondition(message.error == .listTooLong)
        checks += 1
    }

    // 9. PR #24, B1, written before the fix: text of Int.max bytes is .listTooLong, not a trap
    // adding its NUL. The span covers one real byte and is never read, since the count is
    // rejected first. Only a 32-bit target can reach it: on 64-bit, UTF8Span's count is
    // smaller than Int.max.
    do {
        var byte: UInt8 = 0
        let error = unsafe withUnsafePointer(to: &byte) { pointer in
            var storage = InlineArray<4, UInt64>(repeating: 0)
            var span = storage.mutableSpan
            var message = MessageBuilder(storage: span.mutableBytes)
            do {
                var root = message.initRoot(dataWords: 0, pointerCount: 1)
                let huge = unsafe Span<UInt8>(_unsafeStart: pointer, count: Int.max)
                root.setText(UTF8Span(unchecked: huge), at: 0)
            }
            return message.error
        }
        precondition(error == .listTooLong, "text of Int.max bytes")
        checks += 1
    }
    return checks
}
