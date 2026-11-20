// EXPECT-ERROR: requires that 'StructReader' conform to 'Escapable'

import CapnpRuntime

@_lifetime(copy bytes)
private func bad(_ bytes: RawSpan) -> StructReader {
    let arena = Arena(framedBytes: bytes)
    return arena.withRoot { root in root.borrowed() }
}
