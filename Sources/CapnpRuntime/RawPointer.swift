// Decode pointer bits independently of storage ownership and target validation.
// Keeping the two raw halves lets the resolver interpret each kind without creating
// borrowed enum payloads; no decoded address is safe to access until bounds checked.

/// A decoded 64-bit pointer word. Construct from a host-endian word; read the
/// per-kind fields that match `kind`. The two raw halves are kept verbatim
/// (`lowWord` = `offset_and_kind`, `highWord` = `upper32`) and fields are computed.
struct RawPointer {
    /// Low 32 bits — rust `offset_and_kind`. Holds the kind tag and (for struct/list)
    /// the signed offset, or (for far) the double-far flag + segment position.
    let lowWord: UInt32
    /// High 32 bits — rust `upper32bits`. Holds struct sizes / list size+count /
    /// far segment id / capability index.
    let highWord: UInt32

    /// Decode a word already converted from wire little-endian to host byte order.
    init(_ word: UInt64) {
        // Concrete word extraction avoids allocating generic integer conversions on
        // 32-bit Embedded targets; see Widen.swift and ci/check-cross.py.
        self.lowWord = UInt32(truncatingIfNeeded: word._lowWord)
        self.highWord = UInt32(truncatingIfNeeded: (word &>> 32)._lowWord)
    }

    /// Pointer kind (encoding.md `A`): the low 2 bits of the word.
    enum Kind: UInt8 {
        case structure = 0
        case list = 1
        case far = 2
        case other = 3  // capability / "other"
    }

    /// `true` iff the entire word is zero — the canonical null pointer (field default).
    var isNull: Bool { lowWord == 0 && highWord == 0 }

    /// The kind tag (low 2 bits). Total over 0…3, so no failable lookup.
    var kind: Kind {
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
    var signedOffsetWords: Int32 { Int32(bitPattern: lowWord) >> 2 }

    // MARK: Struct (kind == .structure)

    /// Data-section size in words (encoding.md `C`).
    var structDataWords: UInt16 { UInt16(truncatingIfNeeded: highWord) }
    /// Pointer-section size in words (encoding.md `D`).
    var structPointerWords: UInt16 { UInt16(truncatingIfNeeded: highWord >> 16) }

    // MARK: List (kind == .list)

    /// Element-size class code (encoding.md `C`, 0…7 — see `Wire` strides).
    var listElementSizeCode: UInt8 { UInt8(highWord & 0b111) }
    /// Element count (encoding.md `D`), for every class except inline-composite.
    var listElementCount: UInt32 { highWord >> 3 }
    /// Word count of the list content, when the element-size class is inline-composite
    /// (code 7). Same field bits as `listElementCount`, different meaning.
    var listInlineCompositeWordCount: UInt32 { highWord >> 3 }

    // MARK: Far (kind == .far)

    /// Double-far flag (encoding.md `B`): the landing pad is itself a far pointer.
    var farIsDoubleFar: Bool { (lowWord >> 2) & 1 == 1 }
    /// Word offset of the target (or landing pad) within its segment (encoding.md `C`).
    var farPositionWords: UInt32 { lowWord >> 3 }
    /// Target segment id (encoding.md `D`).
    var farSegmentID: UInt32 { highWord }

    // MARK: Other / capability (kind == .other)

    /// Capability-table index. The v1 resolver deliberately returns empty views for
    /// capabilities because readers-only v1 has no RPC capability table.
    var capabilityIndex: UInt32 { highWord }
}
