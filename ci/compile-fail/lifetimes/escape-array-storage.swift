// EXPECT-ERROR: type 'StructReader' does not conform to protocol 'Escapable'

import CapnpRuntime

private func bad(_ arena: borrowing Arena) {
    arena.withRoot { root in
        let items: [StructReader] = [root.borrowed()]
        _ = items
    }
}
