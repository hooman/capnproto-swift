// Arena — the message-wide shared state every reader over one message borrows.
//
// Holds ALL caller-provided storage (INVARIANT 2 — the runtime allocates nothing):
//   • the `RawSpan` carrier over the message bytes (D-10);
//   • the read-limiter, an `Atomic<UInt64>` word budget (D-11 / option A);
//   • a segment id (single-segment v1 ⇒ 0; D-12).
//
// `~Copyable, ~Escapable`:
//   • `~Copyable` because `Atomic` is non-copyable (and a message arena is a unique
//     owner of its limiter state) — matches the milestone's "~Copyable Arena";
//   • `~Escapable` is FORCED by the `RawSpan` member (a `RawSpan` stored property is
//     illegal in an Escapable type) — a Gate-0 (G1) finding refining the milestone text.
//     It is also correct: an arena must not outlive the buffer its span views.
//
// Readers depend on the arena via `@_lifetime(borrow arena)`, so "the arena outlives
// every reader" is compiler-enforced (INVARIANT 3); the limiter's interior mutability
// rides `Atomic`'s defined `borrowing` operations, not an unsafe write. Mirrors rust
// `ReaderArena` + `ReadLimiter`.
//
// AVAILABILITY FINDING (supersedes D-10/DR-D's assumption — propose for DECISIONS.md):
// `Atomic` (Synchronization, SE-0410) back-deploys only to macOS 15.0 / iOS 18.0 /
// watchOS 11.0 / tvOS 18.0 / visionOS 2.0 — a HIGHER Apple floor than `RawSpan`'s
// 10.14.4 set. D-10/DR-D gated the reader surface at the RawSpan set assuming RawSpan was
// the binding constraint; the D-11/A `Atomic` limiter dominates it. So every
// Atomic-bearing symbol (this `Arena`, and `StructReader` since its only init takes an
// `Arena`) is gated at the Synchronization set. Off-Darwin this is a no-op (needs only a
// 6.2 compiler). `CapnpPrimitive`/`RawPointer`/`Wire` keep their true (lower / none) floors.
import Synchronization

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct Arena: ~Copyable, ~Escapable {
    /// The single-segment carrier. Multi-segment (a POD segment table materialising a
    /// span per id) is milestone 2b (D-12); the segment-id field below is present from
    /// day one so that B1→B2 is non-breaking.
    let bytes: RawSpan
    /// Read-limiter word budget (encoding.md §Security MUST). `Atomic` interior
    /// mutability INSIDE this lifetime-checked arena keeps INVARIANT 3 compiler-enforced
    /// (no raw pointer, no convention). Probe r1-L3 verified it Embedded-clean.
    let limiter: Atomic<UInt64>
    /// Segment id of this carrier. Single-segment ⇒ 0; unused this milestone (no table,
    /// no far-pointer following), carried for the non-breaking multi-segment transition.
    let segmentID: UInt32

    /// Build an arena over caller-provided bytes. `@_lifetime(copy bytes)`: the arena's
    /// lifetime is tied to the buffer the span views (verified pattern p3c / Gate-0 G1).
    @_lifetime(copy bytes)
    public init(
        bytes: RawSpan,
        traversalLimitWords: UInt64 = Wire.traversalLimitWords,
        segmentID: UInt32 = 0
    ) {
        self.bytes = bytes
        self.limiter = Atomic(traversalLimitWords)
        self.segmentID = segmentID
    }

    /// Charge `words` against the read-limiter, returning `false` if the budget is
    /// exhausted (amplification/traversal guard, encoding.md §Security).
    ///
    /// DEFERRED-ON, not forgotten (D-11 / option C): the method is present and correct
    /// (the r1-L3-verified relaxed CAS), but NOTHING drives it this milestone — there is
    /// no resolver yet to charge per object read. The stack-overflow guard
    /// (`nestingLimit`, a per-reader value on `StructReader`) is the half of the §Security
    /// pair that is live now. The amplification guard turns on when the resolver lands
    /// (milestone 2); it MUST be driven before any tagged release. `.relaxed` is correct
    /// for the single-threaded v1 (D-5); the `Atomic` form is already concurrency-ready.
    @discardableResult
    public borrowing func charge(words: UInt64) -> Bool {
        var current = limiter.load(ordering: .relaxed)
        while current >= words {
            let (exchanged, original) = limiter.weakCompareExchange(
                expected: current, desired: current &- words, ordering: .relaxed)
            if exchanged { return true }
            current = original
        }
        return false
    }
}
