import CapnpRuntime

let messageBytes: [UInt8] = [
    0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0,
    34, 0, 0, 0, 5, 0, 0, 0, 22, 0, 0, 0, 65, 100, 97, 0, 0, 0, 0, 0, 5, 0, 0, 0, 42, 0,
    0, 0, 5, 0, 0, 0, 66, 0, 0, 0, 109, 97, 116, 104, 0, 0, 0, 0, 101, 110, 103, 105,
    110, 101, 115, 0,
]

func string(from reader: CapnpRuntime.TextReader) -> String {
    var scalars = String.UnicodeScalarView()
    for i in 0..<reader.count { scalars.append(UnicodeScalar(reader[i])) }
    return String(scalars)
}

func readPerson(_ bytes: [UInt8], options: ReaderOptions = ReaderOptions()) {
    let arena = Arena(framedBytes: bytes.span.bytes, options: options)
    guard arena.error == .none else {
        print("could not even read the frame: \(arena.error)")
        return
    }

    arena.withRoot { root in
        let person = Capnp_9c3f8a1b2c4d5e6f.PersonReader(root)
        print("id: \(person.id), name: \(string(from: person.name))")
    }

    // Always check the error after traversal, not before: a malformed or hostile
    // message fails lazily, field by field, not up front at decode time.
    guard arena.error == .none else {
        print("decode error after traversal: \(arena.error)")
        return
    }
    print("clean decode")
}

print("--- a message truncated mid-frame ---")
readPerson(Array(messageBytes.prefix(10)))

print("--- the same message, but with almost no traversal budget ---")
readPerson(messageBytes, options: ReaderOptions(traversalLimitWords: 1))

print("--- the original message again ---")
readPerson(messageBytes)
