// negative-control.swift — NOT part of the product. It lives under ci/, never under
// Sources/, so SwiftPM never builds or links it. The Embedded-clean gate
// (ci/check-embedded-clean.sh) compiles THIS file under -no-allocations and asserts
// it is REJECTED. A heap allocation here MUST be a compile error; if it ever compiles,
// the gate has gone vacuous (e.g. a silently-ignored experimental flag) and CI fails.
public final class _NegativeControlBox { public var x: Int = 0; public init() {} }

@_cdecl("_negative_control")
public func _negativeControl() -> Int { _NegativeControlBox().x }  // class alloc → must error
