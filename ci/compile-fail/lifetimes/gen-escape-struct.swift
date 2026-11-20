// REQUIRES: generated
// EXPECT-ERROR: requires that 'Capnp_9eb32e19f86f3a01\.ExampleReader' conform to 'Escapable'

import CapnpRuntime

@_lifetime(borrow arena)
private func bad(_ arena: borrowing Arena) -> Capnp_9eb32e19f86f3a01.ExampleReader {
    arena.withRoot { root in
        Capnp_9eb32e19f86f3a01.ExampleReader(root.borrowed())
    }
}
