// EXPECT-ERROR: requires that 'ListReader' conform to 'Escapable'

import CapnpRuntime

@_lifetime(borrow arena)
private func bad(_ arena: borrowing Arena) -> ListReader {
    arena.withRoot { root in root.pointerField(at: 0).list(of: .inlineComposite) }
}
