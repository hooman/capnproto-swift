// Builders (D-18) write one single-segment framed message into storage the caller provides.
// The frame header occupies storage bytes 0..<8, the root pointer 8..<16, and the segment
// grows from byte 8 by bump allocation, so every pointer the builder writes points forward.
// Allocation zeroes what it hands out; nothing outside the storage is ever written.
//
// Views are exclusive: `MessageBuilder` and `StructBuilder` are `~Copyable, ~Escapable`, and a
// child borrows its parent through `mutating` + `@_lifetime(&self)`. Each view holds a
// reborrowed `MutableRawSpan` of the whole storage plus a `MutableRef` to the shared
// allocation state, so no `unsafe` is needed (2026-11-26 probe, design *Probe*).
//
// Failure is sticky and never traps: the first error is kept, later writes are no-ops, and
// allocation keeps counting, so `requiredByteCount` is the exact size a successful build of
// the same calls needs. Accessors are methods, not properties: on Swift 6.4.2 a public
// get/set property on these views emits an allocating `modify` coroutine.

/// The first failure while building a message.
public enum BuildError: UInt8 {
    case none
    /// The storage is too small. `MessageBuilder.requiredByteCount` gives the size needed.
    case outOfSpace
    /// A list or text is longer than the wire format allows (lists arrive in a later release).
    case listTooLong
    /// A struct would be nested deeper than 64 levels (the root is level 1), the default
    /// `ReaderOptions` nesting limit, so a default reader could not read it.
    case nestingLimit
    /// A field offset or pointer index outside the struct, or a size outside 0...65535.
    /// Generated code never does this.
    case invalidLayout
}

/// Deepest struct a builder creates; matches `ReaderOptions.defaultNestingLimit`.
let builderNestingLimit = 64

/// Usable bytes of a builder storage of `byteCount` bytes: whole words, at most
/// `Int.max / 8` bytes so bit offsets fit an `Int`, and at most 2^29 words (4 GiB): the
/// header word plus a 2^29 - 1 word segment. Every object lies after its pointer in that
/// one segment, so every near-pointer offset is below 2^29 and fits the signed 30-bit
/// offset field (encoding.md "Structs"), and the segment size fits the 32-bit header field.
/// A larger message needs far pointers and more segments, which this builder doesn't write.
func builderCapacity(byteCount: Int) -> Int {
    min(byteCount / 8, Int.max / 64, 1 << 29) * 8
}

/// Allocation state shared by a `MessageBuilder` and its views.
struct BuildState: ~Copyable {
    /// Usable storage bytes, from `builderCapacity(byteCount:)`.
    let capacity: Int
    /// Bytes handed out so far, header included.
    var used: Int
    /// Bytes a successful build needs, still counted after a failure; saturating.
    var required: Int
    var error: BuildError

    mutating func fail(_ failure: BuildError) {
        if error == .none { error = failure }
    }

    /// Count `bytes`, and reserve them unless a failure already happened or they don't
    /// fit. Returns the storage offset of the reserved bytes.
    mutating func allocate(bytes: Int) -> Int? {
        let (sum, overflow) = required.addingReportingOverflow(bytes)
        required = overflow ? Int.max : sum
        guard error == .none else { return nil }
        guard bytes <= capacity - used else {
            fail(.outOfSpace)
            return nil
        }
        let start = used
        used += bytes
        return start
    }
}

/// Where a struct view's sections are. `start < 0` marks a view with no storage, handed out
/// after a failure: it still knows its sizes, so its children are counted and checked.
struct StructLayout {
    let start: Int
    let dataWords: Int
    let pointerCount: Int
    let depth: Int

    var live: Bool { start >= 0 }
    var pointerStart: Int { start + dataWords * 8 }

    static func phantom(dataWords: Int, pointerCount: Int, depth: Int) -> StructLayout {
        StructLayout(start: -1, dataWords: dataWords, pointerCount: pointerCount, depth: depth)
    }
}

/// Builds one single-segment framed message into caller storage.
///
/// Open it over writable storage, initialize the root, set fields, then check ``error``
/// before using ``framedBytes``. Storage need not be aligned or zeroed. If it is too small,
/// ``error`` is ``BuildError/outOfSpace`` and ``requiredByteCount`` is the exact size to retry
/// with, provided the same build steps run again.
public struct MessageBuilder: ~Copyable, ~Escapable, ~Sendable {
    var storage: MutableRawSpan
    var state: BuildState

    /// Start an empty message in `storage`. It writes only the frame header and a null
    /// root (16 bytes); the rest of `storage` is zeroed as it is allocated.
    @_lifetime(copy storage)
    public init(storage: consuming MutableRawSpan) {
        let capacity = builderCapacity(byteCount: storage.byteCount)
        var state = BuildState(capacity: capacity, used: 0, required: 16, error: .none)
        if capacity >= 16 {
            // Header: segment count - 1 = 0, segment size 1 word (the null root pointer).
            storage.storeBytes(of: UInt32(0), toByteOffset: 0, as: UInt32.self)
            storage.storeBytes(of: UInt32(1), toByteOffset: 4, as: UInt32.self, .littleEndian)
            storage.storeBytes(of: UInt64(0), toByteOffset: 8, as: UInt64.self)
            state.used = 16
        } else {
            state.error = .outOfSpace
        }
        self.storage = storage
        self.state = state
    }

    /// The first failure, or `.none`.
    public var error: BuildError { state.error }

    /// Bytes the framed message needs: equal to ``framedBytes``' count after a successful
    /// build, and the exact size to retry with after ``BuildError/outOfSpace``.
    public var requiredByteCount: Int { state.required }

    /// The framed message (header and segment), or empty if building failed.
    public var framedBytes: RawSpan {
        @_lifetime(borrow self)
        get {
            let count = state.error == .none ? state.used : 0
            return storage.bytes.extracting(0..<count)
        }
    }

    /// Initialize the root struct and return an exclusive view of it. Initializing the
    /// root again zeroes the previous root and everything below it.
    @_lifetime(&self)
    public mutating func initRoot(dataWords: Int, pointerCount: Int) -> StructBuilder {
        let slot = state.error == .none ? 8 : -1
        let layout = Builder.linkStruct(
            in: &storage, state: &state, slot: slot, dataWords: dataWords,
            pointerCount: pointerCount, depth: 1)
        return StructBuilder(
            segment: storage._mutatingExtracting(0..<storage.byteCount), state: MutableRef(&state),
            layout: layout)
    }
}

/// An exclusive, writable view of one struct in a ``MessageBuilder``.
///
/// While a view returned by ``initStruct(at:dataWords:pointerCount:)`` is alive, this view
/// cannot be used: the compiler rejects it. Build children one after another.
public struct StructBuilder: ~Copyable, ~Escapable, ~Sendable {
    var segment: MutableRawSpan
    var state: MutableRef<BuildState>
    let layout: StructLayout

    @_lifetime(copy segment, copy state)
    init(
        segment: consuming MutableRawSpan, state: consuming MutableRef<BuildState>,
        layout: StructLayout
    ) {
        self.segment = segment
        self.state = state
        self.layout = layout
    }

    /// Whether a `T` at `offset` (in units of `T`; bits for `Bool`) lies in the data section.
    private func fieldFits<T: CapnpPrimitive>(_: T.Type, at offset: Int) -> Bool {
        let width = T.sizeInBits
        let bits = layout.dataWords * 64
        return offset >= 0 && bits >= width && offset <= (bits - width) / width
    }

    /// Read back a scalar, applying the schema default as a reader does.
    public func data<T: CapnpPrimitive>(at offset: Int, default value: T) -> T {
        guard layout.live, fieldFits(T.self, at: offset) else { return value }
        return T.loadUnmasked(
            from: segment.bytes, atBitOffset: layout.start * 8 + offset * T.sizeInBits,
            default: value)
    }

    /// Write a scalar at `offset` (in units of `T`; bits for `Bool`), stored XOR `default`.
    public mutating func setData<T: CapnpPrimitive>(_ value: T, at offset: Int, default d: T) {
        guard fieldFits(T.self, at: offset) else {
            state.value.fail(.invalidLayout)
            return
        }
        guard layout.live, state.value.error == .none else { return }
        T.storeMasked(
            value, into: &segment, atBitOffset: layout.start * 8 + offset * T.sizeInBits,
            default: d)
    }

    /// Initialize the struct at pointer `index` and return an exclusive view of it. An
    /// object already there is zeroed first, with everything below it.
    @_lifetime(&self)
    public mutating func initStruct(at index: Int, dataWords: Int, pointerCount: Int)
        -> StructBuilder
    {
        var slot = -1
        if index < 0 || index >= layout.pointerCount {
            state.value.fail(.invalidLayout)
        } else if layout.live && state.value.error == .none {
            slot = layout.pointerStart + index * 8
        }
        let child = Builder.linkStruct(
            in: &segment, state: &state.value, slot: slot, dataWords: dataWords,
            pointerCount: pointerCount, depth: layout.depth + 1)
        return StructBuilder(
            segment: segment._mutatingExtracting(0..<segment.byteCount),
            state: MutableRef(&state.value), layout: child)
    }

    /// Reset pointer `index` to null, zeroing the object it pointed to. The space is not
    /// reclaimed.
    public mutating func clearPointer(at index: Int) {
        guard index >= 0, index < layout.pointerCount else {
            state.value.fail(.invalidLayout)
            return
        }
        guard layout.live, state.value.error == .none else { return }
        Builder.zeroObject(
            in: &segment, at: layout.pointerStart + index * 8, used: state.value.used,
            depth: layout.depth)
    }
}

/// Wire writing shared by the builder views.
enum Builder {
    /// Validate, allocate and link a struct of the given size at pointer `slot` (a storage
    /// offset, or -1 for a view without storage), and return its layout.
    static func linkStruct(
        in span: inout MutableRawSpan, state: inout BuildState, slot: Int, dataWords: Int,
        pointerCount: Int, depth: Int
    ) -> StructLayout {
        guard (0...0xFFFF).contains(dataWords), (0...0xFFFF).contains(pointerCount) else {
            state.fail(.invalidLayout)
            return .phantom(dataWords: 0, pointerCount: 0, depth: depth)
        }
        let phantom = StructLayout.phantom(
            dataWords: dataWords, pointerCount: pointerCount, depth: depth)
        guard depth <= builderNestingLimit else {
            state.fail(.nestingLimit)
            return phantom
        }
        let bytes = (dataWords + pointerCount) * 8
        guard slot >= 0 else {
            _ = state.allocate(bytes: bytes)  // count only: a failure already happened
            return phantom
        }
        zeroObject(in: &span, at: slot, used: state.used, depth: depth - 1)
        if bytes == 0 {
            // Offset -1 so the pointer isn't all zeros, which would read as null.
            storePointer(in: &span, at: slot, low: 0xFFFF_FFFC, high: 0)
            return StructLayout(start: slot, dataWords: 0, pointerCount: 0, depth: depth)
        }
        guard let start = state.allocate(bytes: bytes) else { return phantom }
        var word = start
        while word < start + bytes {
            span.storeBytes(of: UInt64(0), toByteOffset: word, as: UInt64.self)
            word += 8
        }
        // The truncations below drop no bits: the segment is under 2^29 words and the
        // object follows its pointer (builderCapacity), and the sizes were checked above.
        span.storeBytes(
            of: UInt32(truncatingIfNeeded: (state.used - 8) / 8), toByteOffset: 4,
            as: UInt32.self, .littleEndian)
        let offsetWords = (start - slot - 8) / 8
        storePointer(
            in: &span, at: slot, low: UInt32(truncatingIfNeeded: offsetWords &<< 2),
            high: UInt32(truncatingIfNeeded: dataWords)
                | UInt32(truncatingIfNeeded: pointerCount) &<< 16)
        return StructLayout(
            start: start, dataWords: dataWords, pointerCount: pointerCount, depth: depth)
    }

    /// Write a pointer word as two 32-bit halves (no 64-bit shifts on 32-bit targets).
    static func storePointer(in span: inout MutableRawSpan, at slot: Int, low: UInt32, high: UInt32)
    {
        span.storeBytes(of: low, toByteOffset: slot, as: UInt32.self, .littleEndian)
        span.storeBytes(of: high, toByteOffset: slot + 4, as: UInt32.self, .littleEndian)
    }

    /// Zero the object pointer `slot` points to, everything below it, and the pointer.
    /// Only this builder wrote the segment, so every non-null pointer is a near struct or
    /// list pointer to an object before `used`; anything else just has its pointer cleared.
    /// Recursion is bounded by the nesting limit, because nothing deeper is ever built.
    static func zeroObject(in span: inout MutableRawSpan, at slot: Int, used: Int, depth: Int) {
        let low = span.bytes.load(fromByteOffset: slot, as: UInt32.self, .littleEndian)
        let high = span.bytes.load(fromByteOffset: slot + 4, as: UInt32.self, .littleEndian)
        guard low != 0 || high != 0 else { return }
        storePointer(in: &span, at: slot, low: 0, high: 0)
        guard depth < builderNestingLimit else { return }
        if low & 3 == 1 {
            zeroList(in: &span, at: slot, low: low, high: high, used: used, depth: depth)
            return
        }
        guard low & 3 == 0 else { return }
        let dataWords = Int(high & 0xFFFF)
        let pointerCount = Int(high >> 16)
        let offsetWords = Int(Int32(bitPattern: low) >> 2)
        let start = slot + 8 + offsetWords * 8
        let end = start + (dataWords + pointerCount) * 8
        guard dataWords + pointerCount > 0, start >= 16, end <= used else { return }
        var index = 0
        while index < pointerCount {
            zeroObject(
                in: &span, at: start + (dataWords + index) * 8, used: used, depth: depth + 1)
            index += 1
        }
        var word = start
        while word < end {
            span.storeBytes(of: UInt64(0), toByteOffset: word, as: UInt64.self)
            word += 8
        }
    }
}

// MARK: - Generated builders (D-18 item 2)

/// A generated struct builder. Conformances come from `capnpc-swift`; this is not an
/// extension point, and its requirements may change in a minor release.
public protocol CapnpStructBuilder: ~Copyable, ~Escapable {
    /// Data-section size of the struct, in words.
    static var _capnpDataWords: Int { get }
    /// Pointer-section size of the struct.
    static var _capnpPointerCount: Int { get }
    /// Wrap a runtime view of a struct of this layout.
    @_lifetime(copy builder)
    init(_ builder: consuming StructBuilder)
}

extension MessageBuilder {
    /// Initialize the root as a generated struct builder, for example
    /// `message.initRoot(Capnp_….PersonBuilder.self)`.
    @_lifetime(&self)
    public mutating func initRoot<Root: CapnpStructBuilder & ~Copyable & ~Escapable>(
        _: Root.Type
    ) -> Root {
        Root(initRoot(dataWords: Root._capnpDataWords, pointerCount: Root._capnpPointerCount))
    }
}

extension StructBuilder {
    /// Another exclusive view of the same struct. Generated group builders use it: a group
    /// shares its parent's layout.
    @_lifetime(&self)
    public mutating func reborrow() -> StructBuilder {
        StructBuilder(
            segment: segment._mutatingExtracting(0..<segment.byteCount),
            state: MutableRef(&state.value), layout: layout)
    }
}
