// Preserve the wire stride separately from the visible element layout. This lets
// old schemas read prefixes of upgraded struct lists without repacking or allocation.
// Indexed access also keeps borrowed element lifetimes explicit; these views do not
// conform to Sequence, whose element requirements do not fit this v1 borrowed API.

/// Indexed view of all list encodings, including primitive/struct schema upgrades.
public struct ListReader: ~Escapable {
    let context: ReadContext
    let startByte: Int
    public let count: Int
    let stepBits: Int
    let dataBits: Int
    let pointerCount: Int
    let encoding: ElementSize
    let segmentID: UInt32
    let nestingLimit: Int

    @_lifetime(copy context)
    init(
        context: ReadContext, startByte: Int = 0, count: Int = 0, stepBits: Int = 0,
        dataBits: Int = 0, pointerCount: Int = 0, encoding: ElementSize = .void,
        segmentID: UInt32 = 0, nestingLimit: Int = 0
    ) {
        self.context = context
        self.startByte = startByte
        self.count = count
        self.stepBits = stepBits
        self.dataBits = dataBits
        self.pointerCount = pointerCount
        self.encoding = encoding
        self.segmentID = segmentID
        self.nestingLimit = nestingLimit
    }

    public func void(at index: Int) {
        if index < 0 || index >= count { context.report(.invalidIndex) }
    }

    public func data<T: CapnpPrimitive>(at index: Int, default value: T) -> T {
        guard index >= 0, index < count else {
            context.report(.invalidIndex)
            return value
        }
        guard T.sizeInBits <= dataBits else { return value }
        return T.loadUnmasked(
            from: context.bytes,
            atBitOffset: startByte * 8 + index * stepBits, default: value)
    }

    @_lifetime(copy self)
    public func structure(at index: Int) -> StructReader {
        guard index >= 0, index < count else {
            context.report(.invalidIndex)
            return StructReader(context: context)
        }
        guard encoding != .bit else {
            context.report(.typeMismatch)
            return StructReader(context: context)
        }
        guard nestingLimit > 0 else {
            context.report(.nestingLimit)
            return StructReader(context: context)
        }
        // The list body was charged when opened. Selecting an inline struct consumes
        // nesting depth, but does not charge the same body words a second time.
        let start = startByte + index * (stepBits / 8)
        return StructReader(
            context: context, dataStartByte: start, dataSizeBits: dataBits,
            ptrStartByte: start + dataBits / 8, ptrCount: pointerCount,
            segmentID: segmentID, nestingLimit: nestingLimit - 1)
    }

    @_lifetime(copy self)
    public func pointer(at index: Int) -> PointerReader {
        guard index >= 0, index < count else {
            context.report(.invalidIndex)
            return PointerReader(
                context: context, segmentID: segmentID,
                pointerByte: -1, nestingLimit: nestingLimit)
        }
        return PointerReader(
            context: context, segmentID: segmentID,
            pointerByte: pointerCount > 0
                ? startByte + index * (stepBits / 8) + dataBits / 8 : -1,
            nestingLimit: nestingLimit)
    }
}

/// By-value lists specialize at their concrete primitive element type.
public struct PrimitiveList<Element: CapnpPrimitive>: ~Escapable {
    let reader: ListReader
    let zero: Element

    /// Supply the element type's zero value, not a field default: primitive list elements
    /// have no schema XOR mask. A nonzero value would alter every decoded element.
    @_lifetime(copy reader)
    public init(_ reader: consuming ListReader, zero: Element) {
        self.reader = reader
        self.zero = zero
    }

    public var count: Int { reader.count }
    public subscript(index: Int) -> Element { reader.data(at: index, default: zero) }
}
