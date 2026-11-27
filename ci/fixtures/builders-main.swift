// Host driver for generated builders (D-18 item 2), written against the intended generated
// API before the generator change (answer key). Each argument is `mode:path`: build message
// `mode` with the generated builders of builders.capnp and write its framed bytes to `path`.
// ci/check-readers.py compares each with `capnp encode` of the same content in canonical form,
// requires every word no pointer reaches to be zero, and decodes it with `capnp decode`.
//
// Naming rule: a field `foo` gets `foo()` (scalars and enums), `setFoo(_:)`, `initFoo()` and
// `clearFoo()` (structs), `foo()` (non-union groups and named unions) and `initFoo()` (union
// groups), with the first letter of the field name uppercased.
//
// Modes 0-4 set each field once (the reverse oracle). Modes 10-15 switch union members,
// re-initialize groups and structs, and clear pointers; their oracle is the final content.

import CapnpRuntime
import Foundation

typealias B = Capnp_b0b1d0e2c3a4f501

/// `check` is false for the deliberately too-small first pass: after `.outOfSpace` views
/// have no storage and read back defaults, so read-back checks only run on the real build.
func build(_ mode: Int, into message: inout CapnpRuntime.MessageBuilder, check: Bool) {
    var root = message.initRoot(B.RootBuilder.self)
    switch mode {
    case 0:
        break
    case 1:
        root.setFlag(false)
        root.setI8(100)
        root.setI16(-2)
        root.setI32(0)
        root.setI64(-9_000_000_000)
        root.setU8(255)
        root.setU16(0)
        root.setU32(4_000_000_000)
        root.setU64(1)
        root.setF32(2.5)
        root.setF64(-0.0)
        root.setLevel(.high)
        do {
            var child = root.initChild()
            child.setId(3)
            child.setLevel(.low)
            var inner = child.initInner()
            inner.setId(4)
        }
        do {
            var info = root.info()
            info.setAge(40)
            info.setKnown(true)
        }
        root.setCount(0)
        do {
            var extra = root.extra()
            extra.setB(77)
        }
        if check {
            precondition(root.flag() == false && root.i32() == 0 && root.level() == .high)
            precondition(root._capnpWhich() == .count)
        }
    case 2:
        do {
            var pick = root.initPick()
            pick.setId(11)
            _ = pick.initInner()
        }
        do {
            var extra = root.extra()
            extra.setA(5)
        }
    case 3:
        do {
            var pair = root.initPair()
            pair.setLeft(7)
        }
        do {
            var info = root.info()
            info.setKnown(false)
        }
    case 4:
        root.setNone()
        root.setF64(Double.nan)  // the default: stored as zero bits
    case 10:  // a scalar member, then a group member that overlaps it
        root.setCount(0xABCD_0005)
        do {
            var pair = root.initPair()
            pair.setLeft(7)
        }
    case 11:  // a struct member with a subtree, then a scalar member
        do {
            var pick = root.initPick()
            pick.setId(11)
            var inner = pick.initInner()
            inner.setId(1)
        }
        root.setCount(9)
    case 12:  // a union group initialized twice: the second clears the first's fields
        do {
            var pair = root.initPair()
            pair.setLeft(1)
            pair.setRight(2)
        }
        do {
            var pair = root.initPair()
            pair.setLeft(3)
        }
    case 13:  // a struct field re-initialized: the old subtree is zeroed
        do {
            var child = root.initChild()
            child.setId(5)
            var inner = child.initInner()
            inner.setId(6)
        }
        do {
            var child = root.initChild()
            child.setId(7)
        }
    case 14:  // a struct field cleared
        do {
            var child = root.initChild()
            child.setId(5)
        }
        root.clearChild()
    case 15:  // a named union switched between members that don't overlap
        do {
            var extra = root.extra()
            extra.setB(1)
        }
        do {
            var extra = root.extra()
            extra.setA(2)
        }
    default:
        preconditionFailure("unknown mode \(mode)")
    }
}

/// Keyword field names and runtime-like struct names compile and work.
func keywordsAndShadowing() {
    var storage = [UInt8](repeating: 0, count: 64)
    var span = storage.mutableSpan
    var message = CapnpRuntime.MessageBuilder(storage: span.mutableBytes)
    do {
        var keywords = message.initRoot(B.KeywordsBuilder.self)
        keywords.setInit(1)
        keywords.setSelf(2)
        keywords.setDefault(3)
        keywords.setType(4)
        precondition(
            keywords.`init`() == 1 && keywords.`self`() == 2 && keywords.`default`() == 3
                && keywords.type() == 4)
    }
    do {
        var shadow = message.initRoot(B.MessageBuilder.self)
        shadow.setX(5)
    }
    do {
        var shadow = message.initRoot(B.StructBuilder.self)
        shadow.setY(6)
    }
    precondition(message.error == .none)
}

@main
struct BuildersMain {
    static func main() throws {
        keywordsAndShadowing()
        for argument in CommandLine.arguments.dropFirst() {
            let parts = argument.split(separator: ":", maxSplits: 1)
            let mode = Int(parts[0])!
            // Too small first, then retry with requiredByteCount: the retry must succeed.
            var required = 0
            do {
                var small = [UInt8](repeating: 0, count: 24)
                var span = small.mutableSpan
                var message = CapnpRuntime.MessageBuilder(storage: span.mutableBytes)
                build(mode, into: &message, check: false)
                precondition(message.error == .outOfSpace, "mode \(mode): expected outOfSpace")
                required = message.requiredByteCount
            }
            var storage = [UInt8](repeating: 0xAA, count: required)
            var framed = Data()
            do {
                var span = storage.mutableSpan
                var message = CapnpRuntime.MessageBuilder(storage: span.mutableBytes)
                build(mode, into: &message, check: true)
                precondition(message.error == .none, "mode \(mode): \(message.error)")
                let bytes = message.framedBytes
                precondition(bytes.byteCount == required, "mode \(mode): retry size differs")
                for i in 0..<bytes.byteCount {
                    framed.append(bytes.load(fromByteOffset: i, as: UInt8.self))
                }
            }
            try framed.write(to: URL(fileURLWithPath: String(parts[1])))
        }
        print("PASS generated builders: keywords, shadowing, retry with requiredByteCount")
    }
}
