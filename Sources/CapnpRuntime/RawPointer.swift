// RawPointer — POD decode of a 64-bit Cap'n Proto pointer word.
//
// Plain `Copyable, Escapable` value: it decodes the word into a kind tag + per-kind
// integer fields and does NOTHING else. No resolution, no bounds checks, no segment
// lookup, no `~Escapable` — pointer *following* is the resolver (milestone 2); far
// pointers / multi-segment is milestone 2b. Being POD-only is also what sidesteps the
// parked noncopyable-enum problem (SE-0532): no associated-value enum is needed.
//
// No `RawSpan` appears here, so no `@available` gate (pure `UInt64` math). Bit layout
// cross-checked against capnproto-rust `private/layout.rs` `WirePointer` and
// encoding.md §Structs/§Lists/§Inter-Segment/§Capabilities. Mirrors rust `WirePointer`.

/// A decoded 64-bit pointer word. Construct from the little-endian word; read the
/// per-kind fields that match `kind`. The two raw halves are kept verbatim
/// (`lowWord` = `offset_and_kind`, `highWord` = `upper32`) and fields are computed.
public struct RawPointer {
    /// Low 32 bits — rust `offset_and_kind`. Holds the kind tag and (for struct/list)
    /// the signed offset, or (for far) the double-far flag + segment position.
    public let lowWord: UInt32
    /// High 32 bits — rust `upper32bits`. Holds struct sizes / list size+count /
    /// far segment id / capability index.
    public let highWord: UInt32

    /// Decode a pointer from its little-endian 64-bit word.
    public init(_ word: UInt64) {
        self.lowWord = UInt32(truncatingIfNeeded: word)
        self.highWord = UInt32(truncatingIfNeeded: word >> 32)
    }

    /// Pointer kind (encoding.md `A`): the low 2 bits of the word.
    public enum Kind: UInt8 {
        case structure = 0   // rust WirePointerKind::Struct
        case list = 1
        case far = 2
        case other = 3       // capability / "other"
    }

    /// `true` iff the entire word is zero — the canonical null pointer (field default).
    public var isNull: Bool { lowWord == 0 && highWord == 0 }

    /// The kind tag (low 2 bits). Total over 0…3, so no failable lookup.
    public var kind: Kind {
        switch lowWord & 0b11 {
        case 0: return .structure
        case 1: return .list
        case 2: return .far
        default: return .other
        }
    }

    // MARK: Struct / List — shared signed offset

    /// Signed word offset (encoding.md `B`) from the word *after* this pointer to the
    /// target, for struct and list pointers. Arithmetic shift sign-extends.
    /// (An empty struct encodes offset −1; the resolver applies the `+1` landing
    /// adjustment — decode keeps the raw signed value.)
    public var signedOffsetWords: Int32 { Int32(bitPattern: lowWord) >> 2 }

    // MARK: Struct (kind == .structure)

    /// Data-section size in words (encoding.md `C`).
    public var structDataWords: UInt16 { UInt16(truncatingIfNeeded: highWord) }
    /// Pointer-section size in words (encoding.md `D`).
    public var structPointerWords: UInt16 { UInt16(truncatingIfNeeded: highWord >> 16) }

    // MARK: List (kind == .list)

    /// Element-size class code (encoding.md `C`, 0…7 — see `Wire` strides).
    public var listElementSizeCode: UInt8 { UInt8(highWord & 0b111) }
    /// Element count (encoding.md `D`), for every class except inline-composite.
    public var listElementCount: UInt32 { highWord >> 3 }
    /// Word count of the list content, when the element-size class is inline-composite
    /// (code 7). Same field bits as `listElementCount`, different meaning.
    public var listInlineCompositeWordCount: UInt32 { highWord >> 3 }

    // MARK: Far (kind == .far)

    /// Double-far flag (encoding.md `B`): the landing pad is itself a far pointer.
    public var farIsDoubleFar: Bool { (lowWord >> 2) & 1 == 1 }
    /// Word offset of the target (or landing pad) within its segment (encoding.md `C`).
    public var farPositionWords: UInt32 { lowWord >> 3 }
    /// Target segment id (encoding.md `D`).
    public var farSegmentID: UInt32 { highWord }

    // MARK: Other / capability (kind == .other)

    /// Capability-table index, for capability pointers. RPC is out of v1 scope (D-3 /
    /// D-15): the resolver treats this as null/broken — `RawPointer` only decodes it.
    public var capabilityIndex: UInt32 { highWord }
}
