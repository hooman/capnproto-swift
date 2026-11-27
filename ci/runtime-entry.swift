// An exported entry point makes concrete reader operations reachable by the Embedded
// compiler. Compiling declarations alone could leave generic bodies uninstantiated and
// miss allocations. The object is audited by both host and cross-target gates.

@c(capnp_embedded_probe)
public func capnpEmbeddedProbe(_ pointer: UnsafeRawPointer, _ count: Int) -> UInt64 {
    let bytes = unsafe UnsafeRawBufferPointer(start: pointer, count: count)
    let arena = Arena(framedBytes: unsafe RawSpan(_unsafeBytes: bytes))
    let result = arena.withRoot { root in
        var sum = root.data(at: 0, default: (0 as UInt64))
        let child = root.pointerField(at: 0).structure()
        sum &+= child.data(at: 0, default: (0 as UInt64))
        let list = root.pointerField(at: 1).list(of: .inlineComposite)
        for i in 0..<list.count {
            sum &+= list.structure(at: i).data(at: 0, default: (0 as UInt64))
        }
        let primitives = PrimitiveList(
            root.pointerField(at: 2).list(of: .fourBytes), zero: UInt32(0))
        for i in 0..<primitives.count { sum &+= widen(primitives[i]) }
        let text = root.pointerField(at: 3).text()
        sum &+= widen(text.utf8.count)
        for i in 0..<text.count { sum &+= widen(text[i]) }
        let data = root.pointerField(at: 4).data()
        var dataIter = data.makeBorrowingIterator()
        while true {
            let chunk = dataIter.nextSpan(maxCount: 64)
            if chunk.isEmpty { break }
            for i in 0..<chunk.count { sum &+= widen(chunk[i]) }
        }
        return sum
    }
    return result &+ widen(arena.error.rawValue)
}

/// Unpack one packed frame into caller storage, then run the same reader probe over the
/// bytes written. Returns UInt64.max if the frame does not unpack or the size query
/// disagrees, so the firmware link and the allocation audits cover `Packed` too.
@c(capnp_embedded_packed_probe)
public func capnpEmbeddedPackedProbe(
    _ packed: UnsafeRawPointer, _ count: Int, _ output: UnsafeMutableRawPointer, _ capacity: Int
) -> UInt64 {
    let input = unsafe RawSpan(_unsafeBytes: UnsafeRawBufferPointer(start: packed, count: count))
    var storage = unsafe MutableRawSpan(
        _unsafeBytes: UnsafeMutableRawBufferPointer(start: output, count: capacity))
    let size = Packed.unpackedFrameByteCount(input)
    guard let (_, written) = Packed.unpackFrame(input, into: &storage), size == written else {
        return .max
    }
    _ = consume storage
    return unsafe capnpEmbeddedProbe(UnsafeRawPointer(output), written)
}

/// Build a message into caller storage (D-18) with every scalar store, nested, zero-sized,
/// re-initialized and cleared structs, then read it back through an Arena. Returns the root
/// value plus the frame size on success, or UInt64.max on any build failure, so the
/// allocation audits and the firmware link cover the builder path.
@c(capnp_embedded_builder_probe)
public func capnpEmbeddedBuilderProbe(_ output: UnsafeMutableRawPointer, _ capacity: Int)
    -> UInt64
{
    let storage = unsafe MutableRawSpan(
        _unsafeBytes: UnsafeMutableRawBufferPointer(start: output, count: capacity))
    var message = MessageBuilder(storage: storage)
    do {
        var root = message.initRoot(dataWords: 6, pointerCount: 2)
        root.setData(UInt8(1), at: 0, default: 0)
        root.setData(Int8(-1), at: 1, default: 0)
        root.setData(UInt16(2), at: 1, default: 0)
        root.setData(UInt32(3), at: 1, default: 0)
        root.setData(Int16(-2), at: 4, default: 0)
        root.setData(true, at: 80, default: false)
        root.setData(Int32(-3), at: 3, default: 0)
        root.setData(Float(1.5), at: 4, default: 0)
        root.setData(Double(2.5), at: 3, default: 0)
        root.setData(Int64(-4), at: 4, default: 0)
        root.setData(UInt64(7), at: 5, default: 0)
        do {
            var child = root.initStruct(at: 0, dataWords: 1, pointerCount: 0)
            child.setData(UInt64(9), at: 0, default: 0)
        }
        _ = root.initStruct(at: 1, dataWords: 0, pointerCount: 0)
        root.clearPointer(at: 1)
        do {
            var again = root.initStruct(at: 0, dataWords: 1, pointerCount: 0)
            again.setData(again.data(at: 0, default: UInt64(0)) &+ 1, at: 0, default: 0)
        }
    }
    guard message.error == .none else { return .max }
    return capnpEmbeddedListProbe(&message)
}

/// The item 3 paths: text, data and every list builder, rooted for the same audits. The
/// root is re-initialized with pointers for them, zeroing the scalar root above.
func capnpEmbeddedListProbe(_ message: inout MessageBuilder) -> UInt64 {
    do {
        var root = message.initRoot(dataWords: 1, pointerCount: 8)
        root.setData(UInt64(7), at: 0, default: 0)
        root.setText("t".utf8Span, at: 0)
        var bytes = InlineArray<2, UInt8>(repeating: 9)
        root.setBytes(bytes.span, at: 1)
        bytes[0] = 1
        do {
            var numbers = root.initList(PrimitiveListBuilder<UInt32>.self, at: 2, count: 2)
            numbers.setElement(numbers.element(at: 0) &+ 1, at: 1)
        }
        do {
            var bits = root.initList(PrimitiveListBuilder<Bool>.self, at: 3, count: 9)
            bits.setElement(true, at: 8)
        }
        do {
            var texts = root.initList(TextListBuilder.self, at: 4, count: 1)
            texts.setElement("u".utf8Span, at: 0)
        }
        do {
            var blobs = root.initList(DataListBuilder.self, at: 5, count: 1)
            blobs.setElement(bytes.span, at: 0)
        }
        do {
            var matrix = root.initList(
                ListListBuilder<PrimitiveListBuilder<UInt16>>.self, at: 6, count: 1)
            var row = matrix.initElement(at: 0, count: 1)
            row.setElement(3, at: 0)
        }
        _ = root.initList(VoidListBuilder.self, at: 7, count: 2)
        root.clearPointer(at: 7)
    }
    guard message.error == .none else { return .max }
    let arena = Arena(framedBytes: message.framedBytes)
    let value = arena.withRoot { root in
        root.data(at: 0, default: UInt64(0))
            &+ widen(root.pointerField(at: 0).text().utf8.count)
    }
    return value &+ widen(message.requiredByteCount)
}
