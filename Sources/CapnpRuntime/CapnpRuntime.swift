// CapnpRuntime — allocation-free, Foundation-free Cap'n Proto runtime.
//
// Must stay Embedded-clean: compiles under `-no-allocations` (heap use = compile error).
// See the workspace anchors/INVARIANTS.md and decisions/DECISIONS.md (D-2, D-9).
//
// Implementation has not started. The first piece is the "keystone" reader:
// a `~Copyable, ~Escapable` struct over a caller-provided buffer with an
// `@_lifetime(borrow base)` init. See the roadmap "Runtime core" track.

// Throwaway gate canary — removed/replaced when the runtime-core R1 lands. It gives
// the Embedded-clean CI gate a reachable, allocation-free public symbol (an empty
// module passes `-no-allocations` only vacuously). Deliberately NOT the real
// StructReader: a rigorously-designed generic core is the next R1, not baked in here.
//
// It also smoke-tests "RawSpan + a typed load survives the -no-allocations gate"
// (verified clean on 6.3.1 and 6.2.4). Carrier = RawSpan per decisions/DECISIONS.md.
@available(macOS 10.14.4, *)
public func _gateCanary(_ s: RawSpan) -> UInt32 {
    s.unsafeLoadUnaligned(fromByteOffset: 0, as: UInt32.self)
}
