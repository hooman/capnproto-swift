// Wire — Cap'n Proto wire-format constants and units.
//
// Plain integer values: trivially Embedded-clean, and no `RawSpan` appears here, so no
// `@available` back-deployment gate is needed (D-10 / DR-D — gating is only for the
// RawSpan-touching surface). Mirrors rust `private/units.rs` + C++ `common.h`.
//
// Sources: encoding.md §Messages/§Structs/§Lists/§Security; element-size classes and
// strides cross-checked against capnproto-rust `private/layout.rs` (`ElementSize`).

/// Caseless namespace of wire-format constants. `enum` with no cases cannot be
/// instantiated — it is a pure namespace.
public enum Wire {
    /// Bytes in one Cap'n Proto word. The whole format is word-granular.
    public static let bytesPerWord = 8
    /// Bits in one word.
    public static let bitsPerWord = 64
    /// A pointer is exactly one word.
    public static let pointerSizeInWords = 1

    // The eight element-size classes (encoding.md list element-size code C = 0…7),
    // each given as its DATA stride in BITS. Cross-checked against rust
    // `ElementSize` (`data_bits_per_element`). Consumed by the future `ListReader`
    // (lists are a later milestone); named here because Wire is their home.
    /// C=0 · void: no storage.
    public static let elementSizeBitsVoid = 0
    /// C=1 · bit: bit-addressed (the only sub-byte stride).
    public static let elementSizeBitsBit = 1
    /// C=2 · byte.
    public static let elementSizeBitsByte = 8
    /// C=3 · two bytes.
    public static let elementSizeBitsTwoBytes = 16
    /// C=4 · four bytes.
    public static let elementSizeBitsFourBytes = 32
    /// C=5 · eight bytes.
    public static let elementSizeBitsEightBytes = 64
    /// C=6 · pointer: carries one pointer, zero data bits.
    public static let elementSizeBitsPointer = 0
    /// C=7 · inline composite: per-element shape is carried by a tag word, not a stride.
    public static let elementSizeBitsInlineComposite = 0

    // Spec security defaults (encoding.md §Security). Both are MUSTs for a hardened
    // decoder; see D-11 (read-limiter) and the per-reader nesting limit.
    /// Default traversal/read limit: 64 MiB = 8 Mi-words. Counts words down.
    public static let traversalLimitWords: UInt64 = 8 * 1024 * 1024
    /// Default nesting limit: max pointer-follow depth (stack-overflow guard).
    public static let nestingLimit = 64
}
