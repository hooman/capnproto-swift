// EXPECT-ERROR: requires that 'StructReader' conform to 'Escapable'

import CapnpRuntime

@_lifetime(borrow arena)
private func bad(_ arena: borrowing Arena) -> StructReader {
    arena.withRoot { root in root.borrowed() }
}
