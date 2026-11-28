// CapnpRuntime: allocation-free reading and building of Cap'n Proto messages, unpacked and
// packed.
// Arena owns shared traversal state and borrows caller-owned storage. Immutable
// reader views retain compiler-enforced nonescapable lifetime dependencies.
// Concrete Embedded coverage lives in ci/runtime-entry.swift and ci/fixtures/.
