// EXPECT-ERROR: type 'TextListBuilder' does not conform to.*'Sendable'

import CapnpRuntime

private func requireSendable<T: Sendable & ~Copyable & ~Escapable>(_: borrowing T) {}

private func bad(_ list: borrowing TextListBuilder) {
    requireSendable(list)
}
