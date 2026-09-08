// Intentionally allocating: the Embedded gate must reject this exported entry point.
// Keep it outside Sources so it cannot enter the product. Do not replace the class
// with a value type; that would stop checking whether -no-allocations is effective.
public final class _NegativeControlBox { public var x: Int = 0; public init() {} }

@_cdecl("_negative_control")
public func _negativeControl() -> Int { _NegativeControlBox().x }
