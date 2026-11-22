/// Limits applied to one message arena. The segment cap bounds framing and lookup work.
public struct ReaderOptions {
    /// Counts traversed work, including repeated pointer visits and zero-size list elements.
    public var traversalLimitWords: UInt64
    /// Per-path logical depth; negative values are clamped to zero at initialization.
    public var nestingLimit: Int
    public var segmentLimit: UInt32

    // Policy defaults, not wire limits. Traversal bounds repeated work and nesting
    // bounds logical descent, including inline struct elements reached through lists.
    /// Default traversal/read limit: 64 MiB = 8 Mi-words. Counts words down.
    public static var defaultTraversalLimitWords: UInt64 { 8 * 1024 * 1024 }
    /// Default logical nesting depth (stack-overflow guard).
    public static var defaultNestingLimit: Int { 64 }

    public init(
        traversalLimitWords: UInt64 = ReaderOptions.defaultTraversalLimitWords,
        nestingLimit: Int = ReaderOptions.defaultNestingLimit,
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

/// Wire list-size codes. Composite layouts come from their tag, not a fixed data stride.
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

    /// Total decode from a 3-bit wire element-size code (0…7) without an optional trap.
    init(code: UInt8) {
        switch code {
        case 0: self = .void
        case 1: self = .bit
        case 2: self = .byte
        case 3: self = .twoBytes
        case 4: self = .fourBytes
        case 5: self = .eightBytes
        case 6: self = .pointer
        default: self = .inlineComposite
        }
    }
}
