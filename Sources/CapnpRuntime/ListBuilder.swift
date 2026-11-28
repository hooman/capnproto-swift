// List, text and data builders (ARCHITECTURE.md, "Builders"). A list is allocated in one piece by
// `Builder.linkList`, which checks every size before multiplying: counts and inline-composite
// word totals are limited to 2^29 - 1 (`.listTooLong`), and byte sizes that would overflow an
// `Int` on a 32-bit target are `.outOfSpace`, never a trap. Text is a byte list with its NUL;
// data has none. Element views borrow their list exclusively, as struct views borrow their
// parent. A list costs one nesting level and a struct element another, as in the reader, so
// anything built stays readable at the default nesting limit.

/// Largest element count, and inline-composite word total, a list pointer can encode.
let maxListCount = (1 << 29) - 1

/// The wire shape of a list: its element size, and the struct sizes of an inline-composite
/// element. Only `CapnpRuntime` creates shapes, but a conformance can return any of them, so
/// each typed builder checks the shape it is given (`ListBuilder.checked(_:)`).
public struct ListShape {
    let elementSize: ElementSize
    let dataWords: Int
    let pointerCount: Int

    init(_ elementSize: ElementSize, dataWords: Int = 0, pointerCount: Int = 0) {
        self.elementSize = elementSize
        self.dataWords = dataWords
        self.pointerCount = pointerCount
    }

    /// Internal, rather than a public `Equatable` conformance, which would be new API.
    func matches(_ other: ListShape) -> Bool {
        elementSize == other.elementSize && dataWords == other.dataWords
            && pointerCount == other.pointerCount
    }
}

/// A typed list builder. `CapnpRuntime` provides every conformance; this is not an extension
/// point, and its requirements may change in a minor release.
public protocol CapnpListBuilder: ~Copyable, ~Escapable {
    /// The wire shape this builder writes: what `initList` allocates.
    static var _capnpListShape: ListShape { get }
    /// Wrap a list of this builder's shape. A runtime builder given a list of another shape
    /// records ``BuildError/invalidLayout`` and writes nothing.
    @_lifetime(copy list)
    init(_ list: consuming ListBuilder)
}

/// Where a list's elements are. `start < 0` marks a list with no storage, handed out after a
/// failure: writes to it are no-ops. Once its count and shape were valid, it keeps its count,
/// so a caller that loops over `count` still has every element's subtree counted, and
/// `requiredByteCount` stays the exact size to retry with.
struct ListLayout {
    /// Storage offset of the first element (after the tag word, for inline composite).
    let start: Int
    let count: Int
    let shape: ListShape
    let depth: Int

    var live: Bool { start >= 0 }
    var compositeWords: Int { shape.dataWords + shape.pointerCount }

    static func phantom(_ shape: ListShape, depth: Int, count: Int = 0) -> ListLayout {
        ListLayout(start: -1, count: count, shape: shape, depth: depth)
    }
}

/// An exclusive, writable view of one list in a ``MessageBuilder``. Use a typed builder such as
/// ``PrimitiveListBuilder`` or ``StructListBuilder``; this untyped view is what they wrap.
///
/// Every typed builder's element accessors share one contract:
/// - An index outside `0..<count` records ``BuildError/invalidLayout``: a write does nothing,
///   and a read returns zero (or `nil`, for an enum).
/// - After any failure, writes do nothing and reads return zero, but the subtrees a write would
///   have created are still counted, so ``MessageBuilder/requiredByteCount`` stays exact.
/// - `count` is the count the list was initialized with, even when it has no storage because
///   the build ran out of space. It is 0 only when that count, or the list's shape, was
///   invalid.
public struct ListBuilder: ~Copyable, ~Escapable, ~Sendable {
    var segment: MutableRawSpan
    var state: MutableRef<BuildState>
    let layout: ListLayout

    @_lifetime(copy segment, copy state)
    init(
        segment: consuming MutableRawSpan, state: consuming MutableRef<BuildState>,
        layout: ListLayout
    ) {
        self.segment = segment
        self.state = state
        self.layout = layout
    }

    /// The number of elements (see the type's contract for `count` after a failure).
    public var count: Int { layout.count }

    /// Whether element `index` can be written: it is in range, the list has storage and no
    /// failure happened. An index out of range also records `.invalidLayout`.
    mutating func check(_ index: Int) -> Bool {
        guard index >= 0, index < layout.count else {
            state.value.fail(.invalidLayout)
            return false
        }
        return layout.live && state.value.error == .none
    }

    func primitive<T: CapnpPrimitive>(at index: Int) -> T {
        guard layout.live, index >= 0, index < layout.count else { return T.zero }
        // The bit offset fits an `Int`: storage is under `Int.max / 8` bytes (builderCapacity).
        return T.loadUnmasked(
            from: segment.bytes, atBitOffset: layout.start * 8 + index * T.sizeInBits,
            default: T.zero)
    }

    mutating func setPrimitive<T: CapnpPrimitive>(_ value: T, at index: Int) {
        guard check(index) else { return }
        // The bit offset fits an `Int`, as in `primitive(at:)`.
        T.storeMasked(
            value, into: &segment, atBitOffset: layout.start * 8 + index * T.sizeInBits,
            default: T.zero)
    }

    /// The pointer slot of element `index` of a pointer list, or -1.
    mutating func slot(_ index: Int) -> Int {
        check(index) ? layout.start + index * 8 : -1
    }

    /// This list, if it has `shape`. Otherwise `.invalidLayout`, and a list with no storage:
    /// a hand-written `CapnpListBuilder` can declare one shape and wrap the list in the
    /// typed builder of another, whose accessors would then index past the list's storage.
    @_lifetime(copy self)
    consuming func checked(_ shape: ListShape) -> ListBuilder {
        guard !layout.shape.matches(shape) else { return self }
        state.value.fail(.invalidLayout)
        return ListBuilder(
            segment: segment, state: state, layout: .phantom(shape, depth: layout.depth))
    }
}

// MARK: - Typed list builders

/// Builds `List(T)` for a scalar `T`, including `List(Bool)` (one bit per element).
public struct PrimitiveListBuilder<Element: CapnpPrimitive>: ~Copyable, ~Escapable, ~Sendable,
    CapnpListBuilder
{
    var list: ListBuilder
    public static var _capnpListShape: ListShape { ListShape(Element.listElementSize) }
    @_lifetime(copy list)
    public init(_ list: consuming ListBuilder) { self.list = list.checked(Self._capnpListShape) }

    /// The number of elements; see ``ListBuilder`` for its value after a failure.
    public var count: Int { list.count }
    /// Element `index`, or zero; see ``ListBuilder`` for the contract.
    public func element(at index: Int) -> Element { list.primitive(at: index) }
    /// Write element `index`; see ``ListBuilder`` for the contract.
    public mutating func setElement(_ value: Element, at index: Int) {
        list.setPrimitive(value, at: index)
    }
}

/// Builds `List(SomeEnum)`, two bytes per element.
public struct EnumListBuilder<Element: CapnpEnum>: ~Copyable, ~Escapable, ~Sendable,
    CapnpListBuilder
{
    var list: ListBuilder
    public static var _capnpListShape: ListShape { ListShape(.twoBytes) }
    @_lifetime(copy list)
    public init(_ list: consuming ListBuilder) { self.list = list.checked(Self._capnpListShape) }

    /// The number of elements; see ``ListBuilder`` for its value after a failure.
    public var count: Int { list.count }
    /// The element, or nil for an ordinal unknown to this schema version.
    public func element(at index: Int) -> Element? {
        Element(rawValue: list.primitive(at: index) as UInt16)
    }
    /// Write element `index`; see ``ListBuilder`` for the contract.
    public mutating func setElement(_ value: Element, at index: Int) {
        list.setPrimitive(value.rawValue, at: index)
    }
}

/// Builds `List(Void)`: only a count, with no element storage.
public struct VoidListBuilder: ~Copyable, ~Escapable, ~Sendable, CapnpListBuilder {
    var list: ListBuilder
    public static var _capnpListShape: ListShape { ListShape(.void) }
    @_lifetime(copy list)
    public init(_ list: consuming ListBuilder) { self.list = list.checked(Self._capnpListShape) }

    /// The number of elements; see ``ListBuilder`` for its value after a failure.
    public var count: Int { list.count }
}

/// Builds `List(Text)`.
public struct TextListBuilder: ~Copyable, ~Escapable, ~Sendable, CapnpListBuilder {
    var list: ListBuilder
    public static var _capnpListShape: ListShape { ListShape(.pointer) }
    @_lifetime(copy list)
    public init(_ list: consuming ListBuilder) { self.list = list.checked(Self._capnpListShape) }

    /// The number of elements; see ``ListBuilder`` for its value after a failure.
    public var count: Int { list.count }
    /// Copy `text` and its NUL terminator into the message as element `index`, zeroing any
    /// object already there.
    public mutating func setElement(_ text: UTF8Span, at index: Int) {
        let slot = list.slot(index)
        Builder.setBlob(
            text.span, nul: true, in: &list.segment, state: &list.state.value, slot: slot,
            depth: list.layout.depth + 1)
    }
}

/// Builds `List(Data)`.
public struct DataListBuilder: ~Copyable, ~Escapable, ~Sendable, CapnpListBuilder {
    var list: ListBuilder
    public static var _capnpListShape: ListShape { ListShape(.pointer) }
    @_lifetime(copy list)
    public init(_ list: consuming ListBuilder) { self.list = list.checked(Self._capnpListShape) }

    /// The number of elements; see ``ListBuilder`` for its value after a failure.
    public var count: Int { list.count }
    /// Copy `bytes` into the message as element `index`, zeroing any object already there.
    public mutating func setElement(_ bytes: Span<UInt8>, at index: Int) {
        let slot = list.slot(index)
        Builder.setBlob(
            bytes, nul: false, in: &list.segment, state: &list.state.value, slot: slot,
            depth: list.layout.depth + 1)
    }
}

/// Builds `List(SomeStruct)` as an inline-composite list of `Element`'s layout.
public struct StructListBuilder<Element: CapnpStructBuilder & ~Copyable & ~Escapable>: ~Copyable,
    ~Escapable, ~Sendable, CapnpListBuilder
{
    var list: ListBuilder
    public static var _capnpListShape: ListShape {
        ListShape(
            .inlineComposite, dataWords: Element._capnpDataWords,
            pointerCount: Element._capnpPointerCount)
    }
    @_lifetime(copy list)
    public init(_ list: consuming ListBuilder) { self.list = list.checked(Self._capnpListShape) }

    /// The number of elements; see ``ListBuilder`` for its value after a failure.
    public var count: Int { list.count }

    /// An exclusive view of element `index`. Elements are allocated with the list and start
    /// zeroed, so there is nothing to initialize.
    @_lifetime(&self)
    public mutating func element(at index: Int) -> Element {
        let layout = list.layout
        let live = list.check(index)
        let element = StructLayout(
            start: live ? layout.start + index * layout.compositeWords * 8 : -1,
            dataWords: layout.shape.dataWords, pointerCount: layout.shape.pointerCount,
            depth: layout.depth + 1)
        return Element(
            StructBuilder(
                segment: list.segment._mutatingExtracting(0..<list.segment.byteCount),
                state: MutableRef(&list.state.value), layout: element))
    }
}

/// Builds `List(List(…))`: each element is a list of `Inner`'s shape.
public struct ListListBuilder<Inner: CapnpListBuilder & ~Copyable & ~Escapable>: ~Copyable,
    ~Escapable, ~Sendable, CapnpListBuilder
{
    var list: ListBuilder
    public static var _capnpListShape: ListShape { ListShape(.pointer) }
    @_lifetime(copy list)
    public init(_ list: consuming ListBuilder) { self.list = list.checked(Self._capnpListShape) }

    /// The number of elements; see ``ListBuilder`` for its value after a failure.
    public var count: Int { list.count }

    /// Initialize element `index` as a list of `count` elements, zeroing any list already
    /// there, and return an exclusive view of it.
    @_lifetime(&self)
    public mutating func initElement(at index: Int, count: Int) -> Inner {
        let slot = list.slot(index)
        let inner = Builder.linkList(
            in: &list.segment, state: &list.state.value, slot: slot, shape: Inner._capnpListShape,
            count: count, depth: list.layout.depth + 1)
        return Inner(
            ListBuilder(
                segment: list.segment._mutatingExtracting(0..<list.segment.byteCount),
                state: MutableRef(&list.state.value), layout: inner))
    }
}

// MARK: - Pointer fields of a struct

extension StructBuilder {
    /// The storage offset of pointer `index`, or -1 (recording `.invalidLayout` if out of range).
    mutating func pointerSlot(_ index: Int) -> Int {
        guard index >= 0, index < layout.pointerCount else {
            state.value.fail(.invalidLayout)
            return -1
        }
        return layout.live && state.value.error == .none ? layout.pointerStart + index * 8 : -1
    }

    /// Copy `text` and its NUL terminator into the message at pointer `index`, zeroing any
    /// object already there.
    public mutating func setText(_ text: UTF8Span, at index: Int) {
        let slot = pointerSlot(index)
        Builder.setBlob(
            text.span, nul: true, in: &segment, state: &state.value, slot: slot,
            depth: layout.depth + 1)
    }

    /// Copy `bytes` into the message as Data at pointer `index`, zeroing any object already
    /// there.
    public mutating func setBytes(_ bytes: Span<UInt8>, at index: Int) {
        let slot = pointerSlot(index)
        Builder.setBlob(
            bytes, nul: false, in: &segment, state: &state.value, slot: slot,
            depth: layout.depth + 1)
    }

    /// Initialize a list of `count` elements at pointer `index`, zeroing any object already
    /// there, and return an exclusive typed view of it.
    @_lifetime(&self)
    public mutating func initList<List: CapnpListBuilder & ~Copyable & ~Escapable>(
        _: List.Type, at index: Int, count: Int
    ) -> List {
        let slot = pointerSlot(index)
        let list = Builder.linkList(
            in: &segment, state: &state.value, slot: slot, shape: List._capnpListShape,
            count: count, depth: layout.depth + 1)
        return List(
            ListBuilder(
                segment: segment._mutatingExtracting(0..<segment.byteCount),
                state: MutableRef(&state.value), layout: list))
    }
}

// MARK: - Wire writing

extension BuildState {
    /// Count and reserve `words` words; a byte size that overflows `Int` is too large for
    /// any storage.
    mutating func allocate(words: Int) -> Int? {
        let (bytes, overflow) = words.multipliedReportingOverflow(by: 8)
        guard !overflow else {
            required = Int.max
            failTooLarge()
            return nil
        }
        return allocate(bytes: bytes)
    }
}

extension Builder {
    /// Validate, allocate and link a list of `count` elements of `shape` at pointer `slot`
    /// (-1 for a view without storage), and return its layout.
    static func linkList(
        in span: inout MutableRawSpan, state: inout BuildState, slot: Int, shape: ListShape,
        count: Int, depth: Int
    ) -> ListLayout {
        let phantom = ListLayout.phantom(shape, depth: depth)
        guard count >= 0 else {
            state.fail(.invalidLayout)
            return phantom
        }
        guard count <= maxListCount else {
            state.fail(.listTooLong)
            return phantom
        }
        let composite = shape.elementSize == .inlineComposite
        // A hand-written CapnpStructBuilder can declare any sizes; the tag word holds 16 bits
        // each, and a negative size would shrink the allocation.
        guard
            !composite
                || (0...0xFFFF).contains(shape.dataWords)
                    && (0...0xFFFF).contains(shape.pointerCount)
        else {
            state.fail(.invalidLayout)
            return phantom
        }
        guard depth + (composite ? 1 : 0) <= builderNestingLimit else {
            state.fail(.nestingLimit)
            return phantom
        }
        // Body words, computed without overflow: a count is at most 2^29 - 1.
        var words: Int
        let countField: Int
        switch shape.elementSize {
        case .void: words = 0
        case .bit: words = (count + 63) / 64
        case .byte: words = (count + 7) / 8
        case .twoBytes: words = (count + 3) / 4
        case .fourBytes: words = (count + 1) / 2
        case .eightBytes, .pointer: words = count
        case .inlineComposite: words = 0
        }
        if composite {
            let (total, overflow) = count.multipliedReportingOverflow(
                by: shape.dataWords + shape.pointerCount)
            guard !overflow, total <= maxListCount else {
                state.fail(.listTooLong)
                return phantom
            }
            countField = total
            words = total + 1  // the tag word
        } else {
            countField = count
        }
        // From here the count and shape are valid: a failed list keeps its count (ListLayout).
        let counted = ListLayout.phantom(shape, depth: depth, count: count)
        guard slot >= 0 else {
            _ = state.allocate(words: words)  // count only: a failure already happened
            return counted
        }
        zeroObject(in: &span, at: slot, used: state.used, depth: depth - 1)
        guard let start = state.allocate(words: words) else { return counted }
        var word = start
        while word < start + words * 8 {
            span.storeBytes(of: UInt64(0), toByteOffset: word, as: UInt64.self)
            word += 8
        }
        // The truncations below drop no bits: the segment is under 2^29 words and the list
        // follows its pointer (builderCapacity), counts are below 2^29, and the element
        // sizes were checked above.
        span.storeBytes(
            of: UInt32(truncatingIfNeeded: (state.used - 8) / 8), toByteOffset: 4,
            as: UInt32.self, .littleEndian)
        let offsetWords = (start - slot - 8) / 8
        storePointer(
            in: &span, at: slot, low: UInt32(truncatingIfNeeded: offsetWords &<< 2) | 1,
            high: UInt32(truncatingIfNeeded: countField) &<< 3 | UInt32(shape.elementSize.rawValue))
        var first = start
        if composite {
            storePointer(
                in: &span, at: start, low: UInt32(truncatingIfNeeded: count &<< 2),
                high: UInt32(truncatingIfNeeded: shape.dataWords)
                    | UInt32(truncatingIfNeeded: shape.pointerCount) &<< 16)
            first += 8
        }
        return ListLayout(start: first, count: count, shape: shape, depth: depth)
    }

    /// Write `bytes` (plus a NUL for text) as a byte list at pointer `slot`.
    static func setBlob(
        _ bytes: Span<UInt8>, nul: Bool, in span: inout MutableRawSpan, state: inout BuildState,
        slot: Int, depth: Int
    ) {
        // Check before adding the NUL: on a 32-bit target a text of Int.max bytes would
        // overflow `count + 1`.
        guard bytes.count <= maxListCount - (nul ? 1 : 0) else {
            state.fail(.listTooLong)
            return
        }
        let list = linkList(
            in: &span, state: &state, slot: slot, shape: ListShape(.byte),
            count: bytes.count + (nul ? 1 : 0), depth: depth)
        guard list.live else { return }
        // Word at a time, then the tail; the allocation is already zeroed, so the NUL is too.
        let source = bytes.bytes
        var i = 0
        while i + 8 <= bytes.count {
            let word = source.load(fromByteOffset: i, as: UInt64.self, .littleEndian)
            span.storeBytes(of: word, toByteOffset: list.start + i, as: UInt64.self, .littleEndian)
            i += 8
        }
        while i < bytes.count {
            span.storeBytes(of: bytes[i], toByteOffset: list.start + i, as: UInt8.self)
            i += 1
        }
    }

    /// Zero the list body a list pointer (`low`, `high`) at `slot` points to, with the
    /// subtrees of its pointer and struct elements. Called from `zeroObject`, which clears the
    /// pointer itself.
    static func zeroList(
        in span: inout MutableRawSpan, at slot: Int, low: UInt32, high: UInt32, used: Int,
        depth: Int
    ) {
        let code = Int(high & 7)
        let countField = Int(high >> 3)
        let start = slot + 8 + Int(Int32(bitPattern: low) >> 2) * 8
        guard start >= 16, start <= used else { return }
        let available = (used - start) / 8
        var words: Int
        switch code {
        case 0: words = 0
        case 1: words = (countField + 63) / 64
        case 2: words = (countField + 7) / 8
        case 3: words = (countField + 3) / 4
        case 4: words = (countField + 1) / 2
        case 7: words = countField + 1
        default: words = countField
        }
        guard words <= available else { return }
        if code == 6 {
            var index = 0
            while index < countField {
                zeroObject(in: &span, at: start + index * 8, used: used, depth: depth + 1)
                index += 1
            }
        } else if code == 7 {
            let tagLow = span.bytes.load(fromByteOffset: start, as: UInt32.self, .littleEndian)
            let tagHigh = span.bytes.load(fromByteOffset: start + 4, as: UInt32.self, .littleEndian)
            let elements = Int(tagLow >> 2)
            let dataWords = Int(tagHigh & 0xFFFF)
            let pointerCount = Int(tagHigh >> 16)
            let stride = dataWords + pointerCount
            if stride > 0, elements <= countField / stride {
                var element = 0
                while element < elements {
                    var index = 0
                    let base = start + 8 + element * stride * 8
                    while index < pointerCount {
                        zeroObject(
                            in: &span, at: base + (dataWords + index) * 8, used: used,
                            depth: depth + 2)
                        index += 1
                    }
                    element += 1
                }
            }
        }
        var word = start
        while word < start + words * 8 {
            span.storeBytes(of: UInt64(0), toByteOffset: word, as: UInt64.self)
            word += 8
        }
    }
}
