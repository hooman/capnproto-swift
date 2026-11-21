// Wire layout uses separate data-bit and pointer-word counts. A zero data stride
// does not imply an empty element: pointer lists have one pointer, and composite
// lists get their layout from a tag. Keep these units distinct in address arithmetic.

/// Cap'n Proto wire units and default reader limits.
public enum Wire {
    /// Bytes in one Cap'n Proto word. The whole format is word-granular.
    public static var bytesPerWord: Int { 8 }
    /// Bits in one word.
    public static var bitsPerWord: Int { 64 }
    /// A pointer is exactly one word.
    public static var pointerSizeInWords: Int { 1 }

    // Data bits per element for the eight wire size codes. Pointer slots are separate.
    /// C=0 · void: no storage.
    public static var elementSizeBitsVoid: Int { 0 }
    /// C=1 · bit: bit-addressed (the only sub-byte stride).
    public static var elementSizeBitsBit: Int { 1 }
    /// C=2 · byte.
    public static var elementSizeBitsByte: Int { 8 }
    /// C=3 · two bytes.
    public static var elementSizeBitsTwoBytes: Int { 16 }
    /// C=4 · four bytes.
    public static var elementSizeBitsFourBytes: Int { 32 }
    /// C=5 · eight bytes.
    public static var elementSizeBitsEightBytes: Int { 64 }
    /// C=6 · pointer: carries one pointer, zero data bits.
    public static var elementSizeBitsPointer: Int { 0 }
    /// C=7 · inline composite: per-element shape is carried by a tag word, not a stride.
    public static var elementSizeBitsInlineComposite: Int { 0 }

    // Policy defaults, not wire limits. Traversal bounds repeated work and nesting
    // bounds logical descent, including inline struct elements reached through lists.
    /// Default traversal/read limit: 64 MiB = 8 Mi-words. Counts words down.
    public static var traversalLimitWords: UInt64 { 8 * 1024 * 1024 }
    /// Default logical nesting depth (stack-overflow guard).
    public static var nestingLimit: Int { 64 }
}
