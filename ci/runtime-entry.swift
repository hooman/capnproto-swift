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
        let primitives = PrimitiveList(root.pointerField(at: 2).list(of: .fourBytes), zero: UInt32(0))
        for i in 0..<primitives.count { sum &+= widen(primitives[i]) }
        let text = root.pointerField(at: 3).text()
        for i in 0..<text.count { sum &+= widen(text[i]) }
        let data = root.pointerField(at: 4).data()
        for i in 0..<data.count { sum &+= widen(data[i]) }
        return sum
    }
    return result &+ widen(arena.error.rawValue)
}
