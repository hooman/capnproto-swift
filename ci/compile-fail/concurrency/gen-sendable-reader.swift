// REQUIRES: generated
// EXPECT-ERROR: type 'Capnp_9eb32e19f86f3a01\.ExampleReader' does not conform to.*'Sendable'

import CapnpRuntime

private func requireSendable<T: Sendable & ~Escapable>(_: borrowing T) {}

private func bad(_ arena: borrowing Arena) {
    arena.withRoot { root in
        let example = Capnp_9eb32e19f86f3a01.ExampleReader(root.borrowed())
        requireSendable(example)
    }
}
