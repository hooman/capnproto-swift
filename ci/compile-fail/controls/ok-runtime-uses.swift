// EXPECT-PASS

import CapnpRuntime

@_lifetime(copy bytes)
private func openArena(_ bytes: RawSpan) -> Arena {
    Arena(framedBytes: bytes)
}

@_lifetime(copy reader)
private func forwardView(_ reader: borrowing StructReader) -> StructReader {
    reader.borrowed()
}

private func checkSendableConstraint<T: Sendable & ~Copyable & ~Escapable>(_: borrowing T) {}

private func useRuntime(_ framed: [UInt8], _ raw: RawSpan) -> UInt64 {
    checkSendableConstraint(UInt64(0))
    let options = ReaderOptions(traversalLimitWords: 1024, nestingLimit: 16, segmentLimit: 8)
    let arena = Arena(framedBytes: framed.span.bytes, options: options)
    var total = UInt64(arena.consumedByteCount) &+ arena.remainingTraversalWords
    _ = arena.charge(words: 1)

    let fromRoot = arena.withRoot { root -> UInt64 in
        var sum = root.data(at: 0, default: UInt64(0))
        if root.pointer(at: 0).isNull { sum &+= 1 }
        let copied = forwardView(root)
        let member = copied.unionMember(at: 0, equals: 1)
        let ptr = member.pointerField(at: 0)
        if !ptr.isNull { sum &+= 2 }
        let child = ptr.structure()
        let list = child.pointerField(at: 0).list(of: .inlineComposite)
        list.void(at: 0)
        sum &+= UInt64(list.count)
        sum &+= UInt64(list.data(at: 0, default: UInt32(0)))
        sum &+= list.structure(at: 0).data(at: 0, default: UInt64(0))
        if list.pointer(at: 0).isNull { sum &+= 4 }
        let prims = PrimitiveList(
            child.pointerField(at: 1).list(of: .fourBytes), zero: UInt32(0))
        if prims.count > 0 { sum &+= UInt64(prims[0]) }
        let text = child.pointerField(at: 2).text()
        if text.count > 0 { sum &+= UInt64(text[0]) }
        let data = child.pointerField(at: 3).data()
        if data.count > 0 { sum &+= UInt64(data[0]) }
        return sum
    }

    if arena.error == .none { total &+= fromRoot }
    let unframed = Arena(bytes: raw, traversalLimitWords: 1024, segmentID: 0, nestingLimit: 16)
    total &+= unframed.remainingTraversalWords
    _ = consume unframed
    let opened = openArena(raw)
    total &+= opened.remainingTraversalWords
    return total
}
