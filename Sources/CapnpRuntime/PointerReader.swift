struct ResolvedPointer {
    let pointer: RawPointer
    let segmentID: UInt32
    let targetByte: Int
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct PointerReader: ~Escapable {
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

    public var isNull: Bool {
        guard pointerByte >= 0 else { return true }
        guard let segment = context.segment(segmentID),
              segment.contains(pointerByte, words: 1) else {
            context.report(.invalidPointer)
            return true
        }
        return context.word(at: pointerByte).isNull
    }

    func resolve() -> ResolvedPointer? {
        if pointerByte < 0 { return nil }
        guard let segment = context.segment(segmentID),
              segment.contains(pointerByte, words: 1) else {
            context.report(.invalidPointer)
            return nil
        }
        var pointer = context.word(at: pointerByte)
        if pointer.isNull || pointer.kind == .other { return nil }
        guard nestingLimit > 0 else { context.report(.nestingLimit); return nil }
        var id = segmentID
        var origin = pointerByte
        if pointer.kind == .far {
            id = pointer.farSegmentID
            guard let landing = context.segment(id) else {
                context.report(.invalidPointer); return nil
            }
            let position = widen(pointer.farPositionWords) * 8 + widen(landing.start)
            guard position <= widen(Int.max) else { context.report(.invalidPointer); return nil }
            origin = Int(position._lowWord)
            let doubleFar = pointer.farIsDoubleFar
            guard landing.contains(origin, words: doubleFar ? 2 : 1),
                  context.charge(doubleFar ? 2 : 1) else {
                context.report(.invalidPointer); return nil
            }
            pointer = context.word(at: origin)
            if doubleFar {
                let tag = context.word(at: origin + 8)
                guard pointer.kind == .far, !pointer.farIsDoubleFar,
                      tag.kind == .structure || tag.kind == .list,
                      tag.signedOffsetWords == 0,
                      let target = context.segment(pointer.farSegmentID) else {
                    context.report(.invalidPointer); return nil
                }
                let byte = widen(target.start) + widen(pointer.farPositionWords) * 8
                guard byte <= widen(Int.max) else { context.report(.invalidPointer); return nil }
                return ResolvedPointer(pointer: tag, segmentID: pointer.farSegmentID,
                                       targetByte: Int(byte._lowWord))
            }
            guard pointer.kind == .structure || pointer.kind == .list else {
                context.report(.invalidPointer); return nil
            }
        }
        let (offset, overflow1) = Int(pointer.signedOffsetWords).multipliedReportingOverflow(by: 8)
        let (after, overflow2) = origin.addingReportingOverflow(8)
        let (target, overflow3) = after.addingReportingOverflow(offset)
        guard !overflow1, !overflow2, !overflow3, target >= 0 else {
            context.report(.invalidPointer); return nil
        }
        return ResolvedPointer(pointer: pointer, segmentID: id, targetByte: Int(target))
    }

    @_lifetime(copy self)
    public func structure(default defaultPointer: RawPointer? = nil) -> StructReader {
        let empty = StructReader(context: context)
        if let d = defaultPointer, !d.isNull {
            context.report(.unsupportedDefault); return empty
        }
        guard let resolved = resolve() else { return empty }
        let p = resolved.pointer
        guard p.kind == .structure else { context.report(.typeMismatch); return empty }
        let dataWords = Int(p.structDataWords)
        let pointerWords = Int(p.structPointerWords)
        guard let segment = context.segment(resolved.segmentID),
              segment.contains(resolved.targetByte, words: widen(dataWords + pointerWords)) else {
            context.report(.invalidPointer); return empty
        }
        guard context.charge(widen(dataWords + pointerWords)) else { return empty }
        return StructReader(context: context, dataStartByte: resolved.targetByte,
                            dataSizeBits: dataWords * 64,
                            ptrStartByte: resolved.targetByte + dataWords * 8,
                            ptrCount: pointerWords, segmentID: resolved.segmentID,
                            nestingLimit: nestingLimit - 1)
    }

    @_lifetime(copy self)
    public func list(of expected: ElementSize) -> ListReader {
        let empty = ListReader(context: context)
        guard let resolved = resolve() else { return empty }
        let p = resolved.pointer
        guard p.kind == .list else { context.report(.typeMismatch); return empty }
        guard let segment = context.segment(resolved.segmentID) else {
            context.report(.invalidPointer); return empty
        }
        let encoding = ElementSize(rawValue: p.listElementSizeCode)!
        var count = Int(p.listElementCount)
        var dataBits = encoding.dataBits
        var pointerCount = encoding.pointerCount
        var start = resolved.targetByte
        var step = dataBits + pointerCount * 64
        var words: UInt64
        if encoding == .inlineComposite {
            words = widen(p.listInlineCompositeWordCount) + 1
            guard segment.contains(start, words: words) else {
                context.report(.invalidPointer); return empty
            }
            let tag = context.word(at: start)
            guard tag.kind == .structure else { context.report(.invalidPointer); return empty }
            count = Int(tag.lowWord >> 2)
            dataBits = Int(tag.structDataWords) * 64
            pointerCount = Int(tag.structPointerWords)
            step = dataBits + pointerCount * 64
            guard widen(count) * widen(step / 64) <= widen(p.listInlineCompositeWordCount) else {
                context.report(.invalidPointer); return empty
            }
            start += 8
        } else {
            words = (widen(count) * widen(step) + 63) / 64
            guard segment.contains(start, words: words) else {
                context.report(.invalidPointer); return empty
            }
        }
        guard (encoding != .bit || expected == .bit),
              (expected != .bit || encoding != .inlineComposite),
              expected.dataBits <= dataBits,
              expected.pointerCount <= pointerCount else {
            context.report(.typeMismatch); return empty
        }
        // Charge padding/tag words too, plus virtual words for zero-sized elements.
        if step == 0 { words += widen(count) }
        guard context.charge(words) else { return empty }
        return ListReader(context: context, startByte: start, count: count, stepBits: step,
                          dataBits: dataBits, pointerCount: pointerCount,
                          encoding: encoding, segmentID: resolved.segmentID,
                          nestingLimit: nestingLimit - 1)
    }

    @_lifetime(copy self)
    public func data() -> DataReader {
        let list = list(of: .byte)
        guard list.encoding == .byte || list.encoding == .void else {
            context.report(.typeMismatch); return DataReader(context: context)
        }
        return DataReader(context: context, start: list.startByte, count: list.count)
    }

    @_lifetime(copy self)
    public func text() -> TextReader {
        let list = list(of: .byte)
        if list.count == 0 {
            if list.encoding != .void { context.report(.invalidText) }
            return TextReader(context: context)
        }
        guard list.encoding == .byte,
              context.bytes.unsafeLoadUnaligned(fromByteOffset: list.startByte + list.count - 1,
                                               as: UInt8.self) == 0 else {
            context.report(.invalidText); return TextReader(context: context)
        }
        let data = DataReader(context: context, start: list.startByte, count: list.count - 1)
        guard data.validUTF8() else { context.report(.invalidText); return TextReader(context: context) }
        return TextReader(context: context, start: list.startByte, count: list.count - 1)
    }
}
