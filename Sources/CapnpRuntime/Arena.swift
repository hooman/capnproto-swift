import Synchronization

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct ReadState: ~Copyable {
    let remaining: Atomic<UInt64>
    let failure: Atomic<UInt32>

    init(words: UInt64, error: ReadError) {
        remaining = Atomic(words)
        failure = Atomic(error.rawValue)
    }

    borrowing func report(_ error: ReadError) {
        _ = failure.compareExchange(expected: 0, desired: error.rawValue, ordering: .relaxed)
    }

    borrowing func charge(_ words: UInt64) -> Bool {
        var current = remaining.load(ordering: .relaxed)
        while current >= words {
            let result = remaining.weakCompareExchange(
                expected: current, desired: current - words, ordering: .relaxed)
            if result.exchanged { return true }
            current = result.original
        }
        report(.traversalLimit)
        return false
    }
}

/// Owns traversal state, borrowing the caller's message storage.
/// Readers are constructed inside withRoot; neither they nor their children can escape it.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct Arena: ~Copyable, ~Escapable {
    let bytes: RawSpan
    let state: ReadState
    let frame: Frame
    let segmentID: UInt32
    let nestingLimit: Int

    /// Open one standard, unpacked frame. Trailing bytes belong to the next message.
    /// Check error before traversal and again after withRoot returns.
    @_lifetime(copy framedBytes)
    public init(framedBytes: RawSpan, options: ReaderOptions = ReaderOptions()) {
        bytes = framedBytes
        frame = Frame.parse(framedBytes, segmentLimit: options.segmentLimit)
        segmentID = 0
        nestingLimit = options.nestingLimit
        state = ReadState(words: options.traversalLimitWords,
                          error: frame.valid ? .none : .invalidFrame)
    }

    /// Open a single unframed segment (for canonical messages and caller-managed framing).
    @_lifetime(copy bytes)
    public init(
        bytes: RawSpan,
        traversalLimitWords: UInt64 = Wire.traversalLimitWords,
        segmentID: UInt32 = 0,
        nestingLimit: Int = Wire.nestingLimit
    ) {
        self.bytes = bytes
        self.segmentID = segmentID
        self.nestingLimit = max(0, nestingLimit)
        let valid = bytes.byteCount % 8 == 0 && bytes.byteCount <= Int.max / 8
        frame = Frame(headerBytes: 0, segmentCount: 1, byteCount: bytes.byteCount, valid: valid)
        state = ReadState(words: traversalLimitWords, error: valid ? .none : .invalidFrame)
    }

    public var error: ReadError {
        ReadError(rawValue: state.failure.load(ordering: .relaxed)) ?? .invalidPointer
    }

    public var consumedByteCount: Int { frame.valid ? frame.byteCount : 0 }
    public var remainingTraversalWords: UInt64 { state.remaining.load(ordering: .relaxed) }

    @discardableResult
    public borrowing func charge(words: UInt64) -> Bool { state.charge(words) }

    public borrowing func withRoot<Result>(
        _ body: (borrowing StructReader) -> Result
    ) -> Result {
        // The pointer exists only inside its standard-library borrowing scope. Span and
        // all derived views are nonescapable; no pointer or reader is returned from it.
        withUnsafePointer(to: state) { pointer in
            let state = Span(_unsafeStart: pointer, count: 1)
            let context = ReadContext(bytes: bytes, state: state, frame: frame, baseID: segmentID)
            let root = PointerReader(context: context, segmentID: segmentID,
                                     pointerByte: frame.valid ? frame.headerBytes : -1,
                                     nestingLimit: nestingLimit).structure()
            return body(root)
        }
    }
}
