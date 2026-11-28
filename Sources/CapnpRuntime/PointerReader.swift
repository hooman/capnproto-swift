// Normalize near, single-far and double-far encodings into one target/layout pair,
// then let the typed accessor validate the entire body before constructing a view.
// Landing pads and bodies are charged separately; nesting tracks the logical object
// path, not the number of physical segments crossed. Failures preserve the arena's
// first error and return empty views so generated getters need no throwing branches.

// Resolution validates the pointer encoding, not the target body extent.
struct ResolvedPointer {
    let pointer: RawPointer
    let segmentID: UInt32
    let targetByte: Int
}

/// A borrowed pointer slot. Typed accessors validate and charge each traversal.
public struct PointerReader: ~Escapable, ~Sendable {
    let context: ReadContext
    let segmentID: UInt32
    let pointerByte: Int
    let nestingLimit: Int

    @_lifetime(copy context)
    init(context: ReadContext, segmentID: UInt32, pointerByte: Int, nestingLimit: Int) {
        self.context = context
        self.segmentID = segmentID
        self.pointerByte = pointerByte
        self.nestingLimit = nestingLimit
    }

    /// Test the literal wire null without following it. Invalid slots report an error
    /// and return true; capability pointers are non-null here but dereference as empty.
    public var isNull: Bool {
        guard pointerByte >= 0 else { return true }
        guard let segment = context.segment(segmentID),
            segment.contains(pointerByte, words: 1)
        else {
            context.report(.invalidPointer)
            return true
        }
        return context.word(at: pointerByte).isNull
    }

    func resolve() -> ResolvedPointer? {
        if pointerByte < 0 { return nil }
        guard let segment = context.segment(segmentID),
            segment.contains(pointerByte, words: 1)
        else {
            context.report(.invalidPointer)
            return nil
        }
        var pointer = context.word(at: pointerByte)
        // Capabilities deliberately behave as empty: this runtime has no RPC, so there is no
        // capability table to resolve them against.
        if pointer.isNull || pointer.kind == .other { return nil }
        guard nestingLimit > 0 else {
            context.report(.nestingLimit)
            return nil
        }
        var id = segmentID
        var origin = pointerByte
        if pointer.kind == .far {
            id = pointer.farSegmentID
            guard let landing = context.segment(id) else {
                context.report(.invalidPointer)
                return nil
            }
            let position = widen(pointer.farPositionWords) * 8 + widen(landing.start)
            guard position <= widen(Int.max) else {
                context.report(.invalidPointer)
                return nil
            }
            origin = Int(position._lowWord)
            let doubleFar = pointer.farIsDoubleFar
            guard landing.contains(origin, words: doubleFar ? 2 : 1),
                context.charge(doubleFar ? 2 : 1)
            else {
                context.report(.invalidPointer)
                return nil
            }
            pointer = context.word(at: origin)
            // A double-far pad carries an absolute object location and a separate layout
            // tag. Its tag offset is zero; applying normal relative addressing would be wrong.
            if doubleFar {
                let tag = context.word(at: origin + 8)
                guard pointer.kind == .far, !pointer.farIsDoubleFar,
                    tag.kind == .structure || tag.kind == .list,
                    tag.signedOffsetWords == 0,
                    let target = context.segment(pointer.farSegmentID)
                else {
                    context.report(.invalidPointer)
                    return nil
                }
                let byte = widen(target.start) + widen(pointer.farPositionWords) * 8
                guard byte <= widen(Int.max) else {
                    context.report(.invalidPointer)
                    return nil
                }
                return ResolvedPointer(
                    pointer: tag, segmentID: pointer.farSegmentID,
                    targetByte: Int(byte._lowWord))
            }
            guard pointer.kind == .structure || pointer.kind == .list else {
                context.report(.invalidPointer)
                return nil
            }
        }
        let (offset, overflow1) = Int(pointer.signedOffsetWords).multipliedReportingOverflow(by: 8)
        let (after, overflow2) = origin.addingReportingOverflow(8)
        let (target, overflow3) = after.addingReportingOverflow(offset)
        guard !overflow1, !overflow2, !overflow3, target >= 0 else {
            context.report(.invalidPointer)
            return nil
        }
        return ResolvedPointer(pointer: pointer, segmentID: id, targetByte: Int(target))
    }

    /// Open a struct. A null pointer reads as the empty struct (schema defaults).
    @_lifetime(copy self)
    public func structure() -> StructReader { structure(default: nil) }

    /// Open a struct with a schema default pointer; only a null default is supported today.
    @_lifetime(copy self)
    func structure(default defaultPointer: RawPointer?) -> StructReader {
        let empty = StructReader(context: context)
        if let d = defaultPointer, !d.isNull {
            context.report(.unsupportedDefault)
            return empty
        }
        guard let resolved = resolve() else { return empty }
        let p = resolved.pointer
        guard p.kind == .structure else {
            context.report(.typeMismatch)
            return empty
        }
        let dataWords = Int(p.structDataWords)
        let pointerWords = Int(p.structPointerWords)
        guard let segment = context.segment(resolved.segmentID),
            segment.contains(resolved.targetByte, words: widen(dataWords + pointerWords))
        else {
            context.report(.invalidPointer)
            return empty
        }
        guard context.charge(widen(dataWords + pointerWords)) else { return empty }
        return StructReader(
            context: context, dataStartByte: resolved.targetByte,
            dataSizeBits: dataWords * 64,
            ptrStartByte: resolved.targetByte + dataWords * 8,
            ptrCount: pointerWords, segmentID: resolved.segmentID,
            nestingLimit: nestingLimit - 1)
    }

    /// Open a list whose elements are read as `expected`. A null pointer reads as an empty list
    /// with no error. A list whose wire encoding cannot be read as `expected` (a bit list as
    /// structs, say) records `.typeMismatch` and reads as empty; one that a schema upgrade
    /// allows (a struct list read as scalars, which reads each element's first field) opens
    /// with its wire stride kept.
    @_lifetime(copy self)
    public func list(of expected: ElementSize) -> ListReader {
        let empty = ListReader(context: context)
        guard let resolved = resolve() else { return empty }
        let p = resolved.pointer
        guard p.kind == .list else {
            context.report(.typeMismatch)
            return empty
        }
        guard let segment = context.segment(resolved.segmentID) else {
            context.report(.invalidPointer)
            return empty
        }
        let encoding = ElementSize(code: p.listElementSizeCode)
        var count = Int(p.listElementCount)
        var dataBits = encoding.dataBits
        var pointerCount = encoding.pointerCount
        var start = resolved.targetByte
        var step = dataBits + pointerCount * 64
        var words: UInt64
        // Composite pointers count body words, while their tag counts elements. Validate
        // both extents, allowing advertised padding beyond the occupied element strides.
        if encoding == .inlineComposite {
            words = widen(p.listInlineCompositeWordCount) + 1
            guard segment.contains(start, words: words) else {
                context.report(.invalidPointer)
                return empty
            }
            let tag = context.word(at: start)
            guard tag.kind == .structure else {
                context.report(.invalidPointer)
                return empty
            }
            count = Int(tag.lowWord >> 2)
            dataBits = Int(tag.structDataWords) * 64
            pointerCount = Int(tag.structPointerWords)
            step = dataBits + pointerCount * 64
            guard widen(count) * widen(step / 64) <= widen(p.listInlineCompositeWordCount) else {
                context.report(.invalidPointer)
                return empty
            }
            start += 8
        } else {
            words = (widen(count) * widen(step) + 63) / 64
            guard segment.contains(start, words: words) else {
                context.report(.invalidPointer)
                return empty
            }
        }
        // Schema evolution may expose a smaller data/pointer prefix of each element.
        // Preserve the wire stride. A bit list cannot be read as any other element type, nor
        // any other list as bits (encoding.md, "Lists": no upgrade to or from List(Bool)).
        guard encoding != .bit || expected == .bit,
            expected != .bit || encoding != .inlineComposite,
            expected.dataBits <= dataBits,
            expected.pointerCount <= pointerCount
        else {
            context.report(.typeMismatch)
            return empty
        }
        // Charge padding/tag words too. Zero-sized elements consume virtual words so
        // a tiny input cannot request unbounded iteration without exhausting the budget.
        if step == 0 { words += widen(count) }
        guard context.charge(words) else { return empty }
        return ListReader(
            context: context, startByte: start, count: count, stepBits: step,
            dataBits: dataBits, pointerCount: pointerCount,
            encoding: encoding, segmentID: resolved.segmentID,
            nestingLimit: nestingLimit - 1)
    }

    /// Open a Data field. A null pointer reads as empty data with no error; anything but a
    /// byte list records `.typeMismatch` and reads as empty.
    @_lifetime(copy self)
    public func data() -> DataReader {
        let list = list(of: .byte)
        guard list.encoding == .byte || list.encoding == .void else {
            context.report(.typeMismatch)
            return DataReader(context: context)
        }
        return DataReader(context: context, start: list.startByte, count: list.count)
    }

    /// Open a Text field. A null pointer reads as empty text with no error. Anything but a
    /// byte list ending in its NUL terminator, and invalid UTF-8, records `.invalidText` and
    /// reads as empty.
    @_lifetime(copy self)
    public func text() -> TextReader {
        let list = list(of: .byte)
        // Null uses the empty .void sentinel. An encoded byte list still needs a NUL,
        // even for empty text; a zero-length byte list is therefore malformed.
        if list.count == 0 {
            if list.encoding != .void { context.report(.invalidText) }
            return TextReader(context: context)
        }
        guard list.encoding == .byte,
            context.bytes.load(fromByteOffset: list.startByte + list.count - 1, as: UInt8.self) == 0
        else {
            context.report(.invalidText)
            return TextReader(context: context)
        }
        let slice = Span<UInt8>(
            viewing: context.bytes.extracting(list.startByte..<(list.startByte + list.count - 1)))
        guard let utf8 = try? UTF8Span(validating: slice) else {
            context.report(.invalidText)
            return TextReader(context: context)
        }
        return TextReader(context: context, utf8: utf8)
    }
}
