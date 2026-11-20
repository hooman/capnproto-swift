// EXPECT-ERROR: type 'StructReader' does not conform to.*'Sendable'

import CapnpRuntime

private func requireSendable<T: Sendable & ~Escapable>(_: borrowing T) {}

private func bad(_ arena: borrowing Arena) {
    arena.withRoot { root in
        requireSendable(root)
    }
}
