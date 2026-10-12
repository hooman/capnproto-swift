import CapnpRuntime

// Bytes an encoder produced for you. In a real program these might arrive over a
// socket, come from a file, or be encoded at build time — the reader doesn't care.
let messageBytes: [UInt8] = [
    0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0,
    34, 0, 0, 0, 5, 0, 0, 0, 22, 0, 0, 0, 65, 100, 97, 0, 0, 0, 0, 0, 5, 0, 0, 0, 42, 0,
    0, 0, 5, 0, 0, 0, 66, 0, 0, 0, 109, 97, 116, 104, 0, 0, 0, 0, 101, 110, 103, 105,
    110, 101, 115, 0,
]

// TextReader exposes validated UTF-8 bytes, not a String — copy them only if you
// need to keep the value past the decode scope.
func string(from reader: CapnpRuntime.TextReader) -> String {
    var scalars = String.UnicodeScalarView()
    for i in 0..<reader.count { scalars.append(UnicodeScalar(reader[i])) }
    return String(scalars)
}

func readPerson(_ bytes: [UInt8]) {
    let arena = Arena(framedBytes: bytes.span.bytes)
    guard arena.error == .none else {
        print("could not even read the frame: \(arena.error)")
        return
    }

    arena.withRoot { root in
        let person = Capnp_9c3f8a1b2c4d5e6f.PersonReader(root)
        print("id: \(person.id)")
        print("name: \(string(from: person.name))")

        var hobbies: [String] = []
        for i in 0..<person.hobbies.count {
            hobbies.append(string(from: person.hobbies[i]))
        }
        print("hobbies: \(hobbies)")
    }

    guard arena.error == .none else {
        print("decode error: \(arena.error)")
        return
    }
}

readPerson(messageBytes)
