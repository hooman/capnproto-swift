// EXPECT-ERROR: not marked with 'unsafe'

import CapnpRuntime

private func bad(_ pointer: UnsafeRawPointer, _ count: Int) -> UInt64 {
    let bytes = unsafe UnsafeRawBufferPointer(start: pointer, count: count)
    let arena = Arena(framedBytes: RawSpan(_unsafeBytes: bytes))
    return arena.withRoot { root in root.data(at: 0, default: UInt64(0)) }
}
