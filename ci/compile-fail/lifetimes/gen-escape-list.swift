// REQUIRES: generated
// EXPECT-ERROR: requires that 'Capnp_9eb32e19f86f3a01\.ExampleReader\._CapnpList[0-9]+' conform to 'Escapable'

import CapnpRuntime

private func bad(_ arena: borrowing Arena) -> Int {
    let list = arena.withRoot { root in
        return Capnp_9eb32e19f86f3a01.ExampleReader(root.borrowed()).children
    }
    return list.count
}
