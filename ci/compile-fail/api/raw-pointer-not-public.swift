// EXPECT-ERROR: (cannot find type 'RawPointer' in scope|'RawPointer' is inaccessible due to 'internal' protection level)

// 0.1.0 API tiering: decoded pointer words are internal, not public API.
import CapnpRuntime

private func bad(_ pointer: RawPointer) -> Bool { pointer.isNull }
