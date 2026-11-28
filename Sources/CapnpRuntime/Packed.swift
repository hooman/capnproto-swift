// Packed framing (encoding.md "Packing") decoded one frame at a time into caller storage.
// One word producer serves both entry points, so the size query and the unpack cannot
// disagree. The packed stream is one byte sequence: runs may cross the segment table, the
// table/body boundary and segment boundaries, but not the end of the frame, where no
// packed offset exists at which the next frame could start. Segment counts and sizes are
// 32-bit wire values; every size is computed in UInt64 and checked before it becomes Int,
// so 32-bit targets reject hostile tables instead of trapping.

/// Decodes standard packed framing into storage the caller provides.
///
/// Unpack one frame, then open it as an arena over the bytes written:
///
/// ```swift
/// var storage = InlineArray<512, UInt64>(repeating: 0)
/// var words = storage.mutableSpan
/// var output = words.mutableBytes
/// if let (consumed, written) = Packed.unpackFrame(packed, into: &output) {
///     let arena = Arena(framedBytes: output.bytes.extracting(0..<written))
///     // Read through arena.withRoot; the next packed frame starts at `consumed`.
/// }
/// ```
public enum Packed {
    /// Returns the unpacked size of the first packed frame, walking its tags without
    /// writing, or `nil` if the frame is malformed, truncated or over `options`' limits.
    public static func unpackedFrameByteCount(
        _ packed: RawSpan, options: ReaderOptions = ReaderOptions()
    ) -> Int? {
        var none = InlineArray<0, UInt8>(repeating: 0)
        var span = none.mutableSpan
        var output = span.mutableBytes
        return walk(packed, into: &output, writing: false, options: options)?.written
    }

    /// Unpacks exactly the first frame of `packed` into the start of `output`.
    ///
    /// Returns the packed bytes consumed and the unpacked bytes written, or `nil` if the
    /// frame is malformed, truncated, over `options`' limits, or larger than `output`.
    /// The frame's total segment size must not exceed `options.traversalLimitWords`, and its
    /// segment count must not exceed `options.segmentLimit`. Nothing is written past
    /// `output`; after a `nil` return its contents are unspecified.
    public static func unpackFrame(
        _ packed: RawSpan, into output: inout MutableRawSpan,
        options: ReaderOptions = ReaderOptions()
    ) -> (consumed: Int, written: Int)? {
        walk(packed, into: &output, writing: true, options: options)
    }

    private static func walk(
        _ packed: RawSpan, into output: inout MutableRawSpan, writing: Bool,
        options: ReaderOptions
    ) -> (consumed: Int, written: Int)? {
        var words = PackedWords()
        var written = 0

        // Word 0 holds the segment count minus one and segment 0's size.
        guard let first = words.next(packed) else { return nil }
        let count = widen(UInt32(truncatingIfNeeded: first._lowWord)) + 1
        // As in Frame.parse: a table this long cannot fit in `Int` bytes, and rejecting it
        // here keeps `written` from overflowing a 32-bit `Int` while the size query walks it.
        guard count <= widen(options.segmentLimit), count <= widen(Int.max / 8) else { return nil }
        guard store(first, into: &output, at: &written, writing: writing) else { return nil }
        var bodyWords = widen(UInt32(truncatingIfNeeded: (first &>> 32)._lowWord))

        // The remaining sizes, two per word, padded to a whole word. Only the declared
        // count of sizes contributes; padding is ignored, as in Frame.parse.
        let headerWords = (count + 2) / 2
        var size: UInt64 = 1
        var word: UInt64 = 1
        while word < headerWords {
            guard let next = words.next(packed) else { return nil }
            guard store(next, into: &output, at: &written, writing: writing) else { return nil }
            if size < count { bodyWords += widen(UInt32(truncatingIfNeeded: next._lowWord)) }
            if size + 1 < count {
                bodyWords += widen(UInt32(truncatingIfNeeded: (next &>> 32)._lowWord))
            }
            size += 2
            word += 1
        }

        // At most 2^32 - 1 sizes of at most 2^32 - 1 words each: the sum fits in UInt64.
        // Reject before walking the body, as C++ InputStreamMessageReader does.
        guard bodyWords <= options.traversalLimitWords else { return nil }
        guard let frameBytes = frameByteCount(headerWords: headerWords, bodyWords: bodyWords)
        else { return nil }
        if writing { guard frameBytes <= output.byteCount else { return nil } }

        var remaining = bodyWords
        while remaining > 0 {
            guard let next = words.next(packed) else { return nil }
            guard store(next, into: &output, at: &written, writing: writing) else { return nil }
            remaining -= 1
        }
        // A run that extends past the frame's last word leaves no place for the next frame.
        guard words.zeros == 0 && words.literals == 0 else { return nil }
        return (words.position, frameBytes)
    }

    /// The frame's size in bytes, or `nil` if it does not fit in `Int`. A frame that large
    /// can only arrive as megabytes of zero runs, so this is tested directly as well as
    /// through the hostile tables the 32-bit Wasm suite runs.
    static func frameByteCount(headerWords: UInt64, bodyWords: UInt64) -> Int? {
        // headerWords <= 2^31 + 1 and bodyWords <= (2^32 - 1)^2, so the sum cannot wrap.
        let words = headerWords + bodyWords
        guard words <= widen(Int.max / 8) else { return nil }
        return Int(bitPattern: words._lowWord) * 8
    }

    @inline(__always)
    private static func store(
        _ word: UInt64, into output: inout MutableRawSpan, at written: inout Int, writing: Bool
    ) -> Bool {
        if writing {
            guard output.byteCount - written >= 8 else { return false }
            output.storeBytes(of: word.littleEndian, toByteOffset: written, as: UInt64.self)
        }
        written += 8
        return true
    }
}

/// Produces unpacked words from a packed byte stream, one tag or run word at a time.
struct PackedWords {
    /// Input bytes consumed so far.
    var position = 0
    /// Zero words still owed by the last 0x00 tag's run.
    var zeros = 0
    /// Literal words still owed by the last 0xFF tag's run.
    var literals = 0

    /// The next word in host byte order, or `nil` if the input ends inside it.
    mutating func next(_ packed: RawSpan) -> UInt64? {
        if zeros > 0 {
            zeros -= 1
            return 0
        }
        let available = packed.byteCount - position
        if literals > 0 {
            guard available >= 8 else { return nil }
            let word = packed.load(fromByteOffset: position, as: UInt64.self, .littleEndian)
            position += 8
            literals -= 1
            return word
        }
        guard available >= 1 else { return nil }
        let tag = packed.load(fromByteOffset: position, as: UInt8.self)
        position += 1
        // Each set tag bit, from the low bit up, takes the next input byte as that byte of
        // the word; clear bits are zero bytes. Each half is built with concrete UInt32
        // shifts: generic shifts allocate on 32-bit Embedded targets (see Widen.swift), and
        // a variable UInt64 shift needs a compiler-rt helper (__aeabi_llsl) on armv7em.
        var halves: (low: UInt32, high: UInt32) = (0, 0)
        var bits = tag
        var index: UInt32 = 0
        while bits != 0 {
            if bits & 1 != 0 {
                guard position < packed.byteCount else { return nil }
                let byte = UInt32(packed.load(fromByteOffset: position, as: UInt8.self))
                if index < 4 {
                    halves.low |= byte &<< (index * 8)
                } else {
                    halves.high |= byte &<< ((index - 4) * 8)
                }
                position += 1
            }
            bits &>>= 1
            index += 1
        }
        let word = widen(halves.high) &<< 32 | widen(halves.low)
        if tag == 0x00 || tag == 0xFF {
            guard position < packed.byteCount else { return nil }
            let run = Int(
                bitPattern: widen(packed.load(fromByteOffset: position, as: UInt8.self))._lowWord)
            position += 1
            if tag == 0x00 { zeros = run } else { literals = run }
        }
        return word
    }
}
