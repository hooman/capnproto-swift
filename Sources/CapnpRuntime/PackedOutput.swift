// Packed output (encoding.md "Packing"): the inverse of `Packed.unpackFrame`, byte-identical to
// the C++ encoder (capnp/serialize-packed.c++, PackedOutputStream::write), which
// `check-readers.py` verifies against `capnp encode --packed`. The C++ writer packs each buffer
// handed to `write` on its own, and `writeMessage` hands it the segment table and then each
// segment, so runs restart at every piece boundary; this packer parses the frame's table and
// packs piece by piece to match. One walker serves the size query and the pack, so the two
// cannot disagree. The table is validated in UInt64 before any size becomes an `Int`, so 32-bit
// targets reject hostile tables instead of trapping.

extension Packed {
    /// Returns the packed size of the first frame of `framed`, or `nil` if `framed` does not
    /// start with a whole frame (a segment table and every segment it declares).
    public static func packedFrameByteCount(_ framed: RawSpan) -> Int? {
        var none = InlineArray<0, UInt8>(repeating: 0)
        var span = none.mutableSpan
        var output = span.mutableBytes
        return packFrame(framed, into: &output, writing: false)?.written
    }

    /// Packs exactly the first frame of `framed` into the start of `output`.
    ///
    /// Returns the bytes of `framed` consumed (the frame's size; any bytes after it belong to the
    /// next message) and the packed bytes written, or `nil` if `framed` does not start with a
    /// whole frame or `output` is too small. Use ``packedFrameByteCount(_:)`` to size `output`.
    /// Nothing is written past `output`; after a `nil` return its contents are unspecified. The
    /// output is the same as `capnp encode --packed` produces, byte for byte.
    ///
    /// ```swift
    /// let framed = message.framedBytes  // a MessageBuilder's message
    /// var storage = InlineArray<640, UInt8>(repeating: 0)
    /// var bytes = storage.mutableSpan
    /// var output = bytes.mutableBytes
    /// if let (_, written) = Packed.pack(framed, into: &output) {
    ///     // send output.bytes.extracting(0..<written)
    /// }
    /// ```
    public static func pack(_ framed: RawSpan, into output: inout MutableRawSpan) -> (
        consumed: Int, written: Int
    )? {
        packFrame(framed, into: &output, writing: true)
    }

    private static func packFrame(
        _ framed: RawSpan, into output: inout MutableRawSpan, writing: Bool
    ) -> (consumed: Int, written: Int)? {
        // The table, as Frame.parse reads it: count - 1, then the sizes, padded to a whole word.
        guard framed.byteCount >= 8 else { return nil }
        let available = widen(framed.byteCount)
        let count = widen(framed.load(fromByteOffset: 0, as: UInt32.self, .littleEndian)) + 1
        let tableBytes = (count + 2) / 2 * 8
        guard tableBytes <= available else { return nil }
        var frameBytes = tableBytes
        var index: UInt64 = 0
        while index < count {
            frameBytes += widen(size(of: index, in: framed)) * 8
            guard frameBytes <= available else { return nil }
            index += 1
        }
        // Every size now fits an `Int`: the frame lies inside `framed`. The output is at most
        // 10 bytes per 8-byte word (a lone 0xFF word: tag, 8 bytes, count), and a RawSpan holds
        // under `Int.max` bytes, so `written` cannot overflow either.
        var writer = PackWriter(writing: writing)
        var start = Int(bitPattern: tableBytes._lowWord)
        guard writer.pack(framed, from: 0, to: start, into: &output) else { return nil }
        index = 0
        while index < count {
            let end = start + Int(bitPattern: widen(size(of: index, in: framed))._lowWord) * 8
            guard writer.pack(framed, from: start, to: end, into: &output) else { return nil }
            start = end
            index += 1
        }
        return (start, writer.written)
    }

    /// The size in words of segment `index`, from the table at the start of `framed`. The
    /// caller has checked that the table lies inside `framed`.
    private static func size(of index: UInt64, in framed: RawSpan) -> UInt32 {
        framed.load(
            fromByteOffset: 4 + Int(bitPattern: index._lowWord) * 4, as: UInt32.self, .littleEndian)
    }
}

/// Writes packed bytes, or only counts them for the size query.
struct PackWriter {
    let writing: Bool
    /// Packed bytes produced so far.
    var written = 0

    /// Write one byte at `written`, if writing; false if `output` is full.
    private mutating func emit(_ byte: UInt8, into output: inout MutableRawSpan) -> Bool {
        if writing {
            guard written < output.byteCount else { return false }
            output.storeBytes(of: byte, toByteOffset: written, as: UInt8.self)
        }
        written += 1
        return true
    }

    /// Pack the words of `input[start..<end]` as one C++ `write` call: runs end at `end`.
    /// Returns false if `output` is full.
    mutating func pack(
        _ input: RawSpan, from start: Int, to end: Int, into output: inout MutableRawSpan
    ) -> Bool {
        var at = start
        while at < end {
            // The tag goes first but is known last: reserve its byte, then fill it in.
            let tagAt = written
            guard emit(0, into: &output) else { return false }
            var tag: UInt8 = 0
            var bit: UInt8 = 1  // a same-typed mask: a generic shift would allocate on 32-bit
            for offset in 0..<8 {
                let byte = input.load(fromByteOffset: at + offset, as: UInt8.self)
                if byte != 0 {
                    tag |= bit
                    guard emit(byte, into: &output) else { return false }
                }
                bit &<<= 1
            }
            if writing { output.storeBytes(of: tag, toByteOffset: tagAt, as: UInt8.self) }
            at += 8

            if tag == 0x00 {
                // The count of further all-zero words, at most 255.
                var run: UInt8 = 0
                while run < 255, at < end,
                    input.load(fromByteOffset: at, as: UInt64.self, .littleEndian) == 0
                {
                    run += 1
                    at += 8
                }
                guard emit(run, into: &output) else { return false }
            } else if tag == 0xFF {
                // The count of further words with at most one zero byte, at most 255, then those
                // words verbatim. Two zero bytes end the run: from there, packing saves space.
                let runStart = at
                var run: UInt8 = 0
                while run < 255, at < end, zeroBytes(in: input, at: at) < 2 {
                    run += 1
                    at += 8
                }
                guard emit(run, into: &output) else { return false }
                var byte = runStart
                while byte < at {
                    guard emit(input.load(fromByteOffset: byte, as: UInt8.self), into: &output)
                    else { return false }
                    byte += 1
                }
            }
        }
        return true
    }

    private func zeroBytes(in input: RawSpan, at word: Int) -> Int {
        var zeros = 0
        for offset in 0..<8 where input.load(fromByteOffset: word + offset, as: UInt8.self) == 0 {
            zeros += 1
        }
        return zeros
    }
}
