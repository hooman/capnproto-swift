// StructReader — the keystone reader: a transient, borrowed view over one struct's
// data + pointer sections inside an `Arena`.
//
// `~Copyable, ~Escapable` with `@_lifetime(borrow arena)`: the reader may not outlive
// the arena (and therefore the buffer), enforced by the compiler, not convention
// (INVARIANT 3). The two-level chain reader → arena → buffer is Gate-0 (G1) verified on
// 6.3.1 + 6.2.4. The reader physically stores a `RawSpan` copied out of the borrowed
// arena (a stored `borrowing Arena` is not expressible on the 6.2 floor); charging the
// shared limiter is the resolver's job (milestone 2), which holds the arena directly —
// the reader never reaches the limiter, so it carries only buffer-derived state plus the
// per-reader `nestingLimit` value.
//
// Mirrors rust `StructReader` / C++ `StructReader`. Gated at the Synchronization floor
// (macOS 15.0 / iOS 18.0 / …) rather than the lower RawSpan floor: the only initializer
// takes a `borrowing Arena`, and `Arena` carries the `Atomic` limiter (see Arena.swift's
// availability finding). The `data`/`pointer` methods themselves touch only `RawSpan`, but
// a reader cannot be constructed below the Arena's floor, so the type's effective floor is
// the Synchronization set.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct StructReader: ~Copyable, ~Escapable {
    /// The carrier (whole segment), lifetime-bound to the arena → buffer.
    let bytes: RawSpan
    /// Byte offset of this struct's data section within the carrier (word-aligned).
    let dataStartByte: Int
    /// Data-section size in BITS. Stored in bits (not words) because list-element
    /// upgrades produce sub-word data sections; also the unit the version-tolerant
    /// zero-extension check needs (encoding.md; rust `layout.rs`).
    let dataSizeBits: Int
    /// Byte offset of this struct's pointer section within the carrier (word-aligned).
    let ptrStartByte: Int
    /// Number of pointers in the pointer section.
    let ptrCount: Int
    /// Segment id this struct lives in (single-segment ⇒ 0; D-12).
    let segmentID: UInt32
    /// Per-reader nesting budget (encoding.md §Security). A value, copied into and
    /// decremented for children on descent — that happens in the resolver (milestone 2);
    /// here it is just carried.
    let nestingLimit: Int

    /// Internal/testable init placing the reader over an EXPLICIT region of the arena.
    /// The public "read the root from a framed message" entry needs the resolver
    /// (null/bounds/far/charge/child sequence) and is milestone 2; this is the low-level
    /// seam the tests and the resolver build on.
    ///
    /// `@_lifetime(borrow arena)` ties the reader to the arena (Gate-0 G1). `dataSizeBits`
    /// / section offsets come from a resolved struct pointer in real use; here they are
    /// supplied directly.
    @_lifetime(borrow arena)
    init(
        arena: borrowing Arena,
        dataStartByte: Int,
        dataSizeBits: Int,
        ptrStartByte: Int,
        ptrCount: Int,
        nestingLimit: Int = Wire.nestingLimit
    ) {
        self.bytes = arena.bytes
        self.dataStartByte = dataStartByte
        self.dataSizeBits = dataSizeBits
        self.ptrStartByte = ptrStartByte
        self.ptrCount = ptrCount
        self.segmentID = arena.segmentID
        self.nestingLimit = nestingLimit
    }

    /// Read a primitive data field at element-offset `offset` (in units of `T`'s own
    /// size — the schema assigns field offsets this way), XOR-unmasking with `default`.
    ///
    /// Version-tolerant zero-extension (encoding.md): a field whose element lies beyond
    /// the stored `dataSizeBits` reads as 0, and `0 XOR default == default`, so a field
    /// absent from an older sender's shorter struct is indistinguishable from one set to
    /// its default. This is what makes schema evolution free on the read side.
    public func data<T: CapnpPrimitive>(at offset: Int, default value: T) -> T {
        let fieldBit = offset * T.sizeInBits
        // Out of range (negative, or the element's last bit past the section) ⇒ default.
        if fieldBit < 0 || fieldBit + T.sizeInBits > dataSizeBits {
            return value
        }
        let carrierBit = dataStartByte * 8 + fieldBit
        return T.loadUnmasked(from: bytes, atBitOffset: carrierBit, default: value)
    }

    /// Decode the pointer at index `index` in the pointer section. DECODE ONLY — it
    /// returns a `RawPointer`; *following* it (resolving to a child reader) is the
    /// resolver (milestone 2). An out-of-range index returns a null `RawPointer`, matching
    /// the version-tolerance of data fields (absent pointer ⇒ null ⇒ field default).
    public func pointer(at index: Int) -> RawPointer {
        guard index >= 0, index < ptrCount else { return RawPointer(0) }
        let byteOffset = ptrStartByte + index * Wire.bytesPerWord
        let word = bytes.unsafeLoadUnaligned(fromByteOffset: byteOffset, as: UInt64.self)
        return RawPointer(UInt64(littleEndian: word))
    }
}
