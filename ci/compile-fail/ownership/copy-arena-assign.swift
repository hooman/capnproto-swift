// EXPECT-ERROR: 'first' used after consume

import CapnpRuntime

private func bad(_ bytes: RawSpan) -> UInt64 {
    let first = Arena(framedBytes: bytes)
    let second = first
    let a = first.remainingTraversalWords
    let b = second.remainingTraversalWords
    return a &+ b
}
