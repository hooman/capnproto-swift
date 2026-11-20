// EXPECT-ERROR: lifetime-dependent variable 'copy' escapes its scope

import CapnpRuntime

private func store(_ work: @escaping () -> UInt64) {
    _ = work
}

private func bad(_ arena: borrowing Arena) {
    arena.withRoot { root in
        let copy = root.borrowed()
        store { copy.data(at: 0, default: UInt64(0)) }
    }
}
