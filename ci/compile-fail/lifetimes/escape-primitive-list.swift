// EXPECT-ERROR: requires that 'PrimitiveList<UInt32>' conform to 'Escapable'

import CapnpRuntime

@_lifetime(borrow arena)
private func bad(_ arena: borrowing Arena) -> PrimitiveList<UInt32> {
    arena.withRoot { root in
        PrimitiveList(root.pointerField(at: 0).list(of: .fourBytes), zero: UInt32(0))
    }
}
