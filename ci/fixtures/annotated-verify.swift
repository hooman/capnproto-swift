// Host-only check that readers generated from an annotated schema decode a C++-encoded
// message exactly like readers from its unannotated twin. Annotations carry no wire meaning.

import CapnpRuntime
import Foundation

@main
struct AnnotatedVerify {
    static func main() throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let arena = Arena(framedBytes: bytes.span.bytes)
        let ok = arena.withRoot { root -> Bool in
            let box = Capnp_a11071a7ed000002.BoxReader(root.borrowed())
            return box.value == 9 && box.thing.id == 42 && box.choice._capnpWhich == .count
                && box.choice.count == 3 && box.extra.flag
        }
        precondition(arena.error == .none && ok, "annotated readers decoded the wrong values")
        print("PASS annotated readers")
    }
}
