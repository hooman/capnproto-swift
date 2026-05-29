// CapnpRuntime — allocation-free, Foundation-free Cap'n Proto runtime.
//
// Must stay Embedded-clean: compiles under `-no-allocations` (heap use = compile error).
// See the workspace anchors/INVARIANTS.md and decisions/DECISIONS.md (D-2, D-9).
//
// Implementation has not started. The first piece is the "keystone" reader:
// a `~Copyable, ~Escapable` struct over a caller-provided buffer with an
// `@_lifetime(borrow base)` init. See the roadmap "Runtime core" track.

// Intentionally empty for the bootstrap skeleton.
