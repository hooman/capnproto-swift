// Generated constants against the C++ evaluation of the same constants, on the host and in a
// separate Embedded module. The message is `capnp eval -b constants-oracle.capnp values`: an
// Oracle struct whose fields reference the constants, so floats compare by bit pattern and
// -0.0, infinities and NaN cannot pass by accident. Enum constants are checked by name in the
// host driver, against `capnp eval` text.

import CapnpRuntime

typealias C = Capnp_c0c5000000000001

@c(verify_constants)
public func verifyConstants(_ pointer: UnsafeRawPointer, _ count: Int) -> UInt64 {
    let raw = unsafe UnsafeRawBufferPointer(start: pointer, count: count)
    let arena = Arena(framedBytes: unsafe RawSpan(_unsafeBytes: raw))
    let checked = arena.withRoot { root -> UInt64 in
        let o = C.OracleReader(root.borrowed())
        precondition(o.answer == C.answer && o.minInt64 == C.minInt64)
        precondition(o.maxUInt64 == C.maxUInt64 && o.minInt8 == C.minInt8)
        precondition(o.minInt16 == C.minInt16 && o.maxUInt8 == C.maxUInt8)
        precondition(o.maxUInt16 == C.maxUInt16 && o.maxUInt32 == C.maxUInt32)
        precondition(o.yes == C.yes && o.no == C.no)
        precondition(o.notANumber.bitPattern == C.notANumber.bitPattern && C.notANumber.isNaN)
        precondition(o.negativeInfinity.bitPattern == C.negativeInfinity.bitPattern)
        precondition(o.negativeZero.bitPattern == C.negativeZero.bitPattern)
        precondition(C.negativeZero == 0 && C.negativeZero.sign == .minus)
        precondition(o.subnormal.bitPattern == C.subnormal.bitPattern && C.subnormal.isSubnormal)
        precondition(o.large.bitPattern == C.large.bitPattern)
        precondition(o.third.bitPattern == C.third.bitPattern)
        precondition(o.floor == C.LimitsReader.floor)
        precondition(o.depth == C.LimitsReader.InnerReader.depth)
        let _: Void = C.nothing
        precondition(C.level == .high && C.color == .blue && C.LimitsReader.shade == .green)
        return 18
    }
    precondition(arena.error == .none, "oracle reader reported a wire error")
    return checked
}
