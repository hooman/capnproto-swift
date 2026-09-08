// Wire layout uses separate data-bit and pointer-word counts. A zero data stride
// does not imply an empty element: pointer lists have one pointer, and composite
// lists get their layout from a tag. Keep these units distinct in address arithmetic.

/// Cap'n Proto wire units and default reader limits.
public enum Wire {
    /// Bytes in one Cap'n Proto word. The whole format is word-granular.
    public static let bytesPerWord = 8
    /// Bits in one word.
    public static let bitsPerWord = 64
    /// A pointer is exactly one word.
    public static let pointerSizeInWords = 1

    // Data bits per element for the eight wire size codes. Pointer slots are separate.
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

    // Policy defaults, not wire limits. Traversal bounds repeated work and nesting
    // bounds logical descent, including inline struct elements reached through lists.
    /// Default traversal/read limit: 64 MiB = 8 Mi-words. Counts words down.
    public static let traversalLimitWords: UInt64 = 8 * 1024 * 1024
    /// Default logical nesting depth (stack-overflow guard).
    public static let nestingLimit = 64
}
