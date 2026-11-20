// EXPECT-ERROR: type 'Arena' does not conform to.*'Sendable'

import CapnpRuntime

private func requireSendable<T: Sendable & ~Copyable & ~Escapable>(_: borrowing T) {}

private func bad(_ arena: borrowing Arena) {
    requireSendable(arena)
}
