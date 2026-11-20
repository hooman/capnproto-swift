// EXPECT-ERROR: requires that 'TextReader' conform to 'Escapable'

import CapnpRuntime

@_lifetime(borrow arena)
private func bad(_ arena: borrowing Arena) -> TextReader {
    arena.withRoot { root in root.pointerField(at: 0).text() }
}
