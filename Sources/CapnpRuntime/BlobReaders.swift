// Blob readers retain a validated byte range instead of allocating Data or String.
// Text is validated once when opened; subsequent indexing returns UTF-8 code units,
// not characters, and excludes the wire terminator.

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct DataReader: ~Escapable {
    let context: ReadContext
    let start: Int
    public let count: Int

    @_lifetime(copy context)
    init(context: ReadContext, start: Int = 0, count: Int = 0) {
        self.context = context
        self.start = start
        self.count = count
    }

    public subscript(index: Int) -> UInt8 {
        guard index >= 0, index < count else { context.report(.invalidIndex); return 0 }
        return context.bytes.unsafeLoadUnaligned(fromByteOffset: start + index, as: UInt8.self)
    }

    // One pass, constant storage: the lead byte determines length and the allowed
    // second-byte interval. Those intervals exclude overlong encodings, surrogates
    // and scalars above U+10FFFF; remaining bytes need only be continuation bytes.
    // Check the complete sequence extent before accessing any continuation byte.
    func validUTF8() -> Bool {
        var i = 0
        while i < count {
            let a = self[i]
            if a < 0x80 { i += 1; continue }
            let n: Int
            var low: UInt8 = 0x80
            var high: UInt8 = 0xbf
            switch a {
            case 0xc2...0xdf: n = 2
            case 0xe0: n = 3; low = 0xa0
            case 0xe1...0xec, 0xee...0xef: n = 3
            case 0xed: n = 3; high = 0x9f
            case 0xf0: n = 4; low = 0x90
            case 0xf1...0xf3: n = 4
            case 0xf4: n = 4; high = 0x8f
            default: return false
            }
            guard n <= count - i, self[i + 1] >= low, self[i + 1] <= high else { return false }
            for j in 2..<n {
                guard self[i + j] >= 0x80, self[i + j] <= 0xbf else { return false }
            }
            i += n
        }
        return true
    }
}

/// Valid UTF-8 bytes, excluding the wire NUL terminator. No allocating String conversion.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct TextReader: ~Escapable {
    let data: DataReader

    @_lifetime(copy context)
    init(context: ReadContext, start: Int = 0, count: Int = 0) {
        data = DataReader(context: context, start: start, count: count)
    }

    public var count: Int { data.count }
    public subscript(index: Int) -> UInt8 { data[index] }
}
