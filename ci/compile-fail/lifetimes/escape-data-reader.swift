// EXPECT-ERROR: requires that 'DataReader' conform to 'Escapable'

import CapnpRuntime

@_lifetime(borrow arena)
private func bad(_ arena: borrowing Arena) -> DataReader {
    arena.withRoot { root in root.pointerField(at: 0).data() }
}
