// Scalar decoding uses unaligned little-endian loads because borrowed message storage
// need not satisfy Swift alignment. XOR with the schema default makes zero wire bits
// decode as that default. Floats XOR integer bit patterns, preserving NaNs and signed
// zero; Bool extracts one bit rather than loading a possibly invalid Bool representation.
// Generic constraints let Embedded specialize this path without existential dispatch.

/// A data-section scalar whose wire bits can be loaded little-endian and XOR-unmasked
/// against its schema default.
@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
public protocol CapnpPrimitive {
    /// Positive bit width used for field addressing and bounds checks (Bool uses one bit).
    static var sizeInBits: Int { get }

    /// Load the element at carrier-relative `bit`, XOR-unmasking with `default`.
    /// Caller must validate the complete element range in `span` before calling.
    /// `bit` is a multiple of 8 for every supported type except Bool.
    static func loadUnmasked(from span: RawSpan, atBitOffset bit: Int, default: Self) -> Self
}

// MARK: - Integers

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

// MARK: - Floating point

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

// MARK: - Bool

@available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
extension Bool: CapnpPrimitive {
    public static var sizeInBits: Int { 1 }
    public static func loadUnmasked(from span: RawSpan, atBitOffset bit: Int, default d: Bool) -> Bool {
        let byte = span.unsafeLoadUnaligned(fromByteOffset: bit / 8, as: UInt8.self)
        let isSet = (byte >> UInt8(bit % 8)) & 1 == 1
        return isSet != d
    }
}

// Void has no wire storage; generated getters return () without a scalar load.
