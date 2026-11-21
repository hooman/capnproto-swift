// Each arena owns one budget and first-error slot; every derived view borrows them.
// Atomics permit mutation through a shared borrow without a heap-owned reference box.
// Relaxed ordering suffices for these independent counters; it does not make readers
// a public concurrency API or synchronize access to the caller's message storage.

import Synchronization

struct ReadState: ~Copyable, ~Sendable {
    // Word-sized atomic: 64-bit on 64-bit targets, 32-bit on 32-bit targets (UInt32.max
    // words = 32 GiB, 512x the 64 MiB default and 128x the 32-bit address space). Enables
    // riscv32 (ESP32-C6) where UInt64 is not AtomicRepresentable, and uses native 32-bit
    // atomics on Cortex-M4 (armv7em) without software __atomic_*_8 helpers.
    let remaining: Atomic<UInt>
    let failure: Atomic<UInt32>

    init(words: UInt64, error: ReadError) {
        let cap = UInt64(_truncatingBits: UInt.max)
        let clamped = words >= cap ? UInt.max : words._lowWord
        remaining = Atomic(clamped)
        failure = Atomic(error.rawValue)
    }

    borrowing func report(_ error: ReadError) {
        // Keep the first failure: later empty-view fallbacks must not obscure its cause.
        _ = failure.compareExchange(expected: 0, desired: error.rawValue, ordering: .relaxed)
    }

    borrowing func charge(_ words: UInt64) -> Bool {
        let cap = UInt64(_truncatingBits: UInt.max)
        guard words <= cap else {
            report(.traversalLimit)
            return false
        }
        let cost = words._lowWord
        // Retry both contention and spurious weak-CAS failure. Subtract only after the
        // comparison so hostile traversal sizes cannot wrap the unsigned budget.
        var current = remaining.load(ordering: .relaxed)
        while current >= cost {
            let result = remaining.weakCompareExchange(
                expected: current, desired: current - cost, ordering: .relaxed)
            if result.exchanged { return true }
            current = result.original
        }
        report(.traversalLimit)
        return false
    }
}

/// Owns traversal state, borrowing the caller's message storage.
/// Readers are constructed inside withRoot; neither they nor their children can escape it.
public struct Arena: ~Copyable, ~Escapable, ~Sendable {
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
        state = ReadState(
            words: options.traversalLimitWords,
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

    /// First failure since initialization; fallback values alone do not imply success.
    public var error: ReadError {
        ReadError(rawValue: state.failure.load(ordering: .relaxed)) ?? .invalidPointer
    }

    /// Bytes occupied by the first frame, or zero if framing failed.
    public var consumedByteCount: Int { frame.valid ? frame.byteCount : 0 }
    /// Shared work budget, not unread input size: following a pointer again charges again.
    public var remainingTraversalWords: UInt64 {
        UInt64(_truncatingBits: state.remaining.load(ordering: .relaxed))
    }

    /// Reserve additional traversal work; failure records `.traversalLimit`.
    @discardableResult
    public borrowing func charge(words: UInt64) -> Bool { state.charge(words) }

    /// Borrow the root and shared accounting state for the closure. Check `error` afterward,
    /// even when the closure returns normally: invalid reads return empty/default values.
    public borrowing func withRoot<Result>(
        _ body: (borrowing StructReader) -> Result
    ) -> Result {
        // SE-0519: a safe, nonescapable borrow of the shared accounting state. Every derived
        // view copies this dependency, so none can outlive the borrow of the arena.
        let context = ReadContext(bytes: bytes, state: Ref(state), frame: frame, baseID: segmentID)
        let root = PointerReader(
            context: context, segmentID: segmentID,
            pointerByte: frame.valid ? frame.headerBytes : -1,
            nestingLimit: nestingLimit
        ).structure()
        return body(root)
    }
}
