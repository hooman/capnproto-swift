// EXPECT-ERROR: 'arena' used after consume

import CapnpRuntime

private func bad(_ bytes: RawSpan) -> UInt64 {
    let arena = Arena(framedBytes: bytes)
    _ = consume arena
    return arena.withRoot { root in root.data(at: 0, default: UInt64(0)) }
}
