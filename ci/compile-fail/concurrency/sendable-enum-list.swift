// EXPECT-ERROR: type 'EnumList<Color>' does not conform to.*'Sendable'

import CapnpRuntime

private enum Color: UInt16, CapnpEnum { case red = 0 }

private func requireSendable<T: Sendable & ~Escapable>(_: borrowing T) {}

private func bad(_ arena: borrowing Arena) {
    arena.withRoot { root in
        let colors = EnumList<Color>(root.pointerField(at: 0).list(of: .twoBytes))
        requireSendable(colors)
    }
}
