// Wire layout uses separate data-bit and pointer-word counts. A zero data stride
// does not imply an empty element: pointer lists have one pointer, and composite
// lists get their layout from a tag. Keep these units distinct in address arithmetic.

/// Cap'n Proto wire units (internal to CapnpRuntime; not public API).
enum Wire {
    /// Bytes in one Cap'n Proto word. The whole format is word-granular.
    static var bytesPerWord: Int { 8 }
    /// Bits in one word.
    static var bitsPerWord: Int { 64 }
    /// A pointer is exactly one word.
    static var pointerSizeInWords: Int { 1 }

    // Data bits per element for the eight wire size codes. Pointer slots are separate.
    /// C=0 · void: no storage.
    static var elementSizeBitsVoid: Int { 0 }
    /// C=1 · bit: bit-addressed (the only sub-byte stride).
    static var elementSizeBitsBit: Int { 1 }
    /// C=2 · byte.
    static var elementSizeBitsByte: Int { 8 }
    /// C=3 · two bytes.
    static var elementSizeBitsTwoBytes: Int { 16 }
    /// C=4 · four bytes.
    static var elementSizeBitsFourBytes: Int { 32 }
    /// C=5 · eight bytes.
    static var elementSizeBitsEightBytes: Int { 64 }
    /// C=6 · pointer: carries one pointer, zero data bits.
    static var elementSizeBitsPointer: Int { 0 }
    /// C=7 · inline composite: per-element shape is carried by a tag word, not a stride.
    static var elementSizeBitsInlineComposite: Int { 0 }
}
