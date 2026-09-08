// Swift 6.2/6.3 generic integer widening instantiates an allocating Words
// collection on 32-bit targets, even when optimization would remove it later.
// These concrete word initializers lower directly to zero-extension. Int inputs
// are nonnegative, checked sizes/positions; UInt still checks that precondition.
// Despite the initializer name, none of these source widths loses bits in UInt64.
// Retire this workaround only after both supported compilers pass the 32-bit
// -no-allocations and symbol checks in ci/check-cross.py with ordinary conversions.
@inline(__always)
func widen(_ value: Int) -> UInt64 { UInt64(_truncatingBits: UInt(value)) }
@inline(__always)
func widen(_ value: UInt32) -> UInt64 { UInt64(_truncatingBits: UInt(value)) }
@inline(__always)
func widen(_ value: UInt8) -> UInt64 { UInt64(_truncatingBits: UInt(value)) }
