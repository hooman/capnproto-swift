// EXPECT-ERROR: lifetime-dependent value escapes its scope

import CapnpRuntime

@_lifetime(copy anchor)
private func bad(_ anchor: RawSpan) -> Arena {
    let bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]
    return Arena(framedBytes: bytes.span.bytes)
}
