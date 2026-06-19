// CapnpPrimitive — typed unaligned little-endian load + XOR-default unmasking for
// data-section scalar element types.
//
// Used ONLY as a generic constraint (`<T: CapnpPrimitive>`), never `any CapnpPrimitive`,
// so it fully specializes under Embedded `-wmo` with no witness-table residue — verified
// by Gate-0 probe G2 (cross-file specialization, 6.3.1 + 6.2.4). Mirrors the merge of
// rust `PrimitiveElement` + `Mask` + `Zero`.
//
// `@available`-gated because `loadUnmasked` names `RawSpan`, whose Apple back-deployment
// floor is the SwiftCompatibilitySpan set (D-10 / DR-D). No-op off-Darwin.
//
// Two spec special cases (encoding.md §Value Encoding):
//   • floats XOR via BIT PATTERN — the mask type differs from `Self` (f32→UInt32,
//     f64→UInt64), so the unmask happens on the integer bits, then `init(bitPattern:)`.
//   • `Bool` is BIT-ADDRESSED — load the containing byte and extract the bit; never
//     `unsafeLoadUnaligned(as: Bool.self)` (a stray bit pattern would be an invalid Bool).

/// A data-section scalar whose wire bits can be loaded little-endian and XOR-unmasked
/// against its schema default.
@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
public protocol CapnpPrimitive {
    /// Width of one element in BITS — the data-section stride for this type
    /// (`UInt32` → 32, `Bool` → 1). Drives both field addressing and the
    /// version-tolerant bounds check in `StructReader.data`.
    static var sizeInBits: Int { get }

    /// Load the element at carrier-relative `bit`, XOR-unmasking with `default`.
    /// The caller (`StructReader.data`) guarantees the element's bits lie within the
    /// data section. `bit` is a multiple of 8 for every type except `Bool`.
    static func loadUnmasked(from span: RawSpan, atBitOffset bit: Int, default: Self) -> Self
}

// MARK: - Integer family (one constrained-extension witness; the verified G2 form)

// All fixed-width integers share the same path: unaligned LE load + XOR. A single
// constrained extension supplies the witnesses; each concrete conformance below is a
// one-liner. (`BitwiseCopyable` is required by `unsafeLoadUnaligned`; `FixedWidthInteger`
// gives `bitWidth`, `init(littleEndian:)`, and `^`.)
@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension CapnpPrimitive where Self: FixedWidthInteger & BitwiseCopyable {
    public static var sizeInBits: Int { Self.bitWidth }
    public static func loadUnmasked(from span: RawSpan, atBitOffset bit: Int, default d: Self) -> Self {
        Self(littleEndian: span.unsafeLoadUnaligned(fromByteOffset: bit / 8, as: Self.self)) ^ d
    }
}

@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension UInt8: CapnpPrimitive {}
@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension UInt16: CapnpPrimitive {}
@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension UInt32: CapnpPrimitive {}
@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension UInt64: CapnpPrimitive {}
@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension Int8: CapnpPrimitive {}
@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension Int16: CapnpPrimitive {}
@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension Int32: CapnpPrimitive {}
@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension Int64: CapnpPrimitive {}

// MARK: - Floating point (XOR via bit pattern; mask type differs from Self)

@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension Float: CapnpPrimitive {
    public static var sizeInBits: Int { 32 }
    public static func loadUnmasked(from span: RawSpan, atBitOffset bit: Int, default d: Float) -> Float {
        let raw = UInt32(littleEndian: span.unsafeLoadUnaligned(fromByteOffset: bit / 8, as: UInt32.self))
        return Float(bitPattern: raw ^ d.bitPattern)
    }
}

@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension Double: CapnpPrimitive {
    public static var sizeInBits: Int { 64 }
    public static func loadUnmasked(from span: RawSpan, atBitOffset bit: Int, default d: Double) -> Double {
        let raw = UInt64(littleEndian: span.unsafeLoadUnaligned(fromByteOffset: bit / 8, as: UInt64.self))
        return Double(bitPattern: raw ^ d.bitPattern)
    }
}

// MARK: - Bool (bit-addressed)

@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension Bool: CapnpPrimitive {
    public static var sizeInBits: Int { 1 }
    public static func loadUnmasked(from span: RawSpan, atBitOffset bit: Int, default d: Bool) -> Bool {
        let byte = span.unsafeLoadUnaligned(fromByteOffset: bit / 8, as: UInt8.self)
        let isSet = (byte >> UInt8(bit % 8)) & 1 == 1
        return isSet != d   // XOR against the default bit
    }
}

// NOTE on `Void` (encoding.md: void fields carry no storage). The milestone lists
// `Void` among the primitive set, but `Void` is the empty tuple `()`, and Swift tuples
// cannot be extended to conform to a protocol — `extension Void: CapnpPrimitive` is not
// expressible. This is harmless: a void field has nothing to load, so generated code
// returns `()` directly without a `data<T>` call. No conformance is (or can be) added.
// Likewise enums are not given a blanket conformance — a generated enum reads its raw
// `UInt16` via `data(at:default:)` and maps it; that is codegen (D-7), out of scope here.
