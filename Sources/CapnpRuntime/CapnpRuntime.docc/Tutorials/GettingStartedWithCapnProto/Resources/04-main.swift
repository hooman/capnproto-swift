import CapnpRuntime

// Bytes an encoder produced for you. In a real program these might arrive over a
// socket, come from a file, or be encoded at build time — the reader doesn't care.
let messageBytes: [UInt8] = [
    0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0,
    34, 0, 0, 0, 5, 0, 0, 0, 22, 0, 0, 0, 65, 100, 97, 0, 0, 0, 0, 0, 5, 0, 0, 0, 42, 0,
    0, 0, 5, 0, 0, 0, 66, 0, 0, 0, 109, 97, 116, 104, 0, 0, 0, 0, 101, 110, 103, 105,
    110, 101, 115, 0,
]

func readPerson(_ bytes: [UInt8]) {
    bytes.withUnsafeBytes { raw in
        let arena = Arena(framedBytes: RawSpan(_unsafeBytes: raw))
        guard arena.error == .none else {
            print("could not even read the frame: \(arena.error)")
            return
        }

        arena.withRoot { root in
            let person = Capnp_9c3f8a1b2c4d5e6f.PersonReader(root)
            print("id: \(person.id)")
        }

        guard arena.error == .none else {
            print("decode error: \(arena.error)")
            return
        }
    }
}

readPerson(messageBytes)
