/// Limits applied to one message arena. The segment cap bounds framing and lookup work.
public struct ReaderOptions {
    public var traversalLimitWords: UInt64
    public var nestingLimit: Int
    public var segmentLimit: UInt32

    public init(
        traversalLimitWords: UInt64 = Wire.traversalLimitWords,
        nestingLimit: Int = Wire.nestingLimit,
        segmentLimit: UInt32 = 512
    ) {
        self.traversalLimitWords = traversalLimitWords
        self.nestingLimit = max(0, nestingLimit)
        self.segmentLimit = segmentLimit
    }
}

/// First failure observed while opening or traversing an arena; null is not an error.
public enum ReadError: UInt32 {
    case none, invalidFrame, invalidPointer, typeMismatch
    case traversalLimit, nestingLimit, invalidText, invalidIndex, unsupportedDefault
}

public enum ElementSize: UInt8 {
    case void, bit, byte, twoBytes, fourBytes, eightBytes, pointer, inlineComposite

    var dataBits: Int {
        switch self {
        case .bit: return 1
        case .byte: return 8
        case .twoBytes: return 16
        case .fourBytes: return 32
        case .eightBytes: return 64
        default: return 0
        }
    }

    var pointerCount: Int { self == .pointer ? 1 : 0 }
}
