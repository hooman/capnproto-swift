// EXPECT-ERROR: (cannot find 'Wire' in scope|'Wire' is inaccessible due to 'internal' protection level)

// 0.1.0 API tiering: wire units are internal, not public API.
import CapnpRuntime

private func bad() -> Int { Wire.bytesPerWord }
