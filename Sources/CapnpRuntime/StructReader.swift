// Struct fields use separate data and pointer regions so older messages can omit
// trailing fields without making them invalid. Resolvers validate the region extents;
// getters check only the requested field against that layout and apply its default.

/// A borrowed struct data/pointer view. Missing fields read their schema defaults.
public struct StructReader: ~Escapable, ~Sendable {
    let context: ReadContext
    let dataStartByte: Int
    let dataSizeBits: Int
    let ptrStartByte: Int
    let ptrCount: Int
    let segmentID: UInt32
    let nestingLimit: Int

    @_lifetime(copy context)
    init(
        context: ReadContext, dataStartByte: Int = 0, dataSizeBits: Int = 0,
        ptrStartByte: Int = 0, ptrCount: Int = 0, segmentID: UInt32 = 0,
        nestingLimit: Int = 0
    ) {
        self.context = context
        self.dataStartByte = dataStartByte
        self.dataSizeBits = dataSizeBits
        self.ptrStartByte = ptrStartByte
        self.ptrCount = ptrCount
        self.segmentID = segmentID
        self.nestingLimit = nestingLimit
    }

    // Trusted fixture seam: supplied regions must already be in bounds. The nil state
    // disables pointer traversal and error reporting; this is not an input validation path.
    // TODO(test-fixtures): move trusted fixture construction into the test target and
    // remove this initializer from production sources.
    @_lifetime(borrow arena)
    init(
        arena: borrowing Arena, dataStartByte: Int, dataSizeBits: Int,
        ptrStartByte: Int, ptrCount: Int, nestingLimit: Int = Wire.nestingLimit
    ) {
        self.init(
            context: ReadContext(
                bytes: arena.bytes, state: nil,
                frame: arena.frame, baseID: arena.segmentID),
            dataStartByte: dataStartByte, dataSizeBits: dataSizeBits,
            ptrStartByte: ptrStartByte, ptrCount: ptrCount,
            segmentID: arena.segmentID, nestingLimit: nestingLimit)
    }

    /// Read an offset measured in units of T (bits for Bool), applying the schema XOR mask.
    /// A field not wholly present in the data section returns its default.
    public func data<T: CapnpPrimitive>(at offset: Int, default value: T) -> T {
        let width = T.sizeInBits
        // Divide before multiplying the field offset to avoid overflow on invalid offsets.
        guard width > 0, offset >= 0, dataSizeBits >= width,
            offset <= (dataSizeBits - width) / width
        else { return value }
        return T.loadUnmasked(
            from: context.bytes,
            atBitOffset: dataStartByte * 8 + offset * width, default: value)
    }

    public func pointer(at index: Int) -> RawPointer {
        guard index >= 0, index < ptrCount else { return RawPointer(0) }
        return context.word(at: ptrStartByte + index * 8)
    }

    @_lifetime(copy self)
    public func pointerField(at index: Int) -> PointerReader {
        PointerReader(
            context: context, segmentID: segmentID,
            pointerByte: index >= 0 && index < ptrCount ? ptrStartByte + index * 8 : -1,
            nestingLimit: nestingLimit)
    }

    /// Select an active union member, or an empty view whose fields read their defaults.
    /// The discriminant offset is measured in UInt16 elements.
    @_lifetime(copy self)
    public func unionMember(at discriminantOffset: Int, equals value: UInt16) -> StructReader {
        if data(at: discriminantOffset, default: UInt16(0)) == value { return borrowed() }
        return StructReader(context: context)
    }

    /// A second view of the same struct, used for generated group/union readers.
    @_lifetime(copy self)
    public func borrowed() -> StructReader {
        StructReader(
            context: context, dataStartByte: dataStartByte, dataSizeBits: dataSizeBits,
            ptrStartByte: ptrStartByte, ptrCount: ptrCount,
            segmentID: segmentID, nestingLimit: nestingLimit)
    }
}
