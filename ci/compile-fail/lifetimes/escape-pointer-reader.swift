// EXPECT-ERROR: requires that 'PointerReader' conform to 'Escapable'

import CapnpRuntime

@_lifetime(borrow arena)
private func bad(_ arena: borrowing Arena) -> PointerReader {
    arena.withRoot { root in root.pointerField(at: 0) }
}
