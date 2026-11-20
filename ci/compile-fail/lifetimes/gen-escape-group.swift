// REQUIRES: generated
// EXPECT-ERROR: requires that 'Capnp_9eb32e19f86f3a01\.ExampleReader\.detailReader' conform to 'Escapable'

import CapnpRuntime

private func bad(_ arena: borrowing Arena) -> UInt64 {
    let detail = arena.withRoot { root in
        return Capnp_9eb32e19f86f3a01.ExampleReader(root.borrowed()).detail
    }
    return detail.amount
}
