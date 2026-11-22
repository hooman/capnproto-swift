// Scalar decoding uses the checked, byte-order-explicit RawSpan loads of SE-0525: borrowed
// message storage need not satisfy Swift alignment, and the load itself traps rather than
// reading out of bounds. Callers still validate ranges first so malformed input reports
// an error instead of reaching that trap. XOR with the schema default makes zero wire bits
// decode as that default. Floats XOR integer bit patterns, preserving NaNs and signed
// zero; Bool extracts one bit rather than loading a possibly invalid Bool representation.
// Generic constraints let Embedded specialize this path without existential dispatch.

/// A data-section scalar whose wire bits can be loaded little-endian and XOR-unmasked
/// against its schema default.
///
/// `CapnpRuntime` provides the conformances for every Cap'n Proto scalar type
/// (`Bool`, fixed-width integers, `Float`, `Double`). The protocol is public so
/// generated code can name it as a generic constraint (for example
/// `PrimitiveList<UInt16>`); it is **not** an extension point. Conformances declared
/// outside `CapnpRuntime` are unsupported, and its requirements may change in a minor
/// release.
public protocol CapnpPrimitive {
    /// Positive bit width used for field addressing and bounds checks (Bool uses one bit).
    static var sizeInBits: Int { get }

    /// Wire zero value for list elements (which carry no per-field XOR default).
    static var zero: Self { get }

    /// Cap'n Proto wire list-element size code for a list of this primitive.
    static var listElementSize: ElementSize { get }

    /// Load the element at carrier-relative `bit`, XOR-unmasking with `default`.
    /// Caller must validate the complete element range in `span` before calling.
    /// `bit` is a multiple of 8 for every supported type except Bool.
    static func loadUnmasked(from span: RawSpan, atBitOffset bit: Int, default: Self) -> Self
}

// MARK: - Integers

extension CapnpPrimitive where Self: FixedWidthInteger & ConvertibleFromBytes {
    public static var sizeInBits: Int { Self.bitWidth }
    public static var zero: Self { 0 }
    public static var listElementSize: ElementSize {
        switch Self.bitWidth {
        case 8: return .byte
        case 16: return .twoBytes
        case 32: return .fourBytes
        default: return .eightBytes
        }
    }
    public static func loadUnmasked(from span: RawSpan, atBitOffset bit: Int, default d: Self)
        -> Self
    {
        span.load(fromByteOffset: bit / 8, as: Self.self, .littleEndian) ^ d
    }
}

extension UInt8: CapnpPrimitive {}
extension UInt16: CapnpPrimitive {}
extension UInt32: CapnpPrimitive {}
extension UInt64: CapnpPrimitive {}
extension Int8: CapnpPrimitive {}
extension Int16: CapnpPrimitive {}
extension Int32: CapnpPrimitive {}
extension Int64: CapnpPrimitive {}

// MARK: - Floating point

extension Float: CapnpPrimitive {
    public static var sizeInBits: Int { 32 }
    public static var zero: Float { 0 }
    public static var listElementSize: ElementSize { .fourBytes }
    public static func loadUnmasked(from span: RawSpan, atBitOffset bit: Int, default d: Float)
        -> Float
    {
        let raw = span.load(fromByteOffset: bit / 8, as: UInt32.self, .littleEndian)
        return Float(bitPattern: raw ^ d.bitPattern)
    }
}

extension Double: CapnpPrimitive {
    public static var sizeInBits: Int { 64 }
    public static var zero: Double { 0 }
    public static var listElementSize: ElementSize { .eightBytes }
    public static func loadUnmasked(from span: RawSpan, atBitOffset bit: Int, default d: Double)
        -> Double
    {
        let raw = span.load(fromByteOffset: bit / 8, as: UInt64.self, .littleEndian)
        return Double(bitPattern: raw ^ d.bitPattern)
    }
}

// MARK: - Bool

extension Bool: CapnpPrimitive {
    public static var sizeInBits: Int { 1 }
    public static var zero: Bool { false }
    public static var listElementSize: ElementSize { .bit }
    public static func loadUnmasked(from span: RawSpan, atBitOffset bit: Int, default d: Bool)
        -> Bool
    {
        let byte = span.load(fromByteOffset: bit / 8, as: UInt8.self)
        let isSet = (byte >> UInt8(bit % 8)) & 1 == 1
        return isSet != d
    }
}

// Void has no wire storage; generated getters return () without a scalar load.
