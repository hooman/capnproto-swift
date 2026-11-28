# Building messages

Write a Cap'n Proto message into storage you provide, without allocating.

## Overview

`capnpc-swift` generates a builder beside each struct's reader: `struct Person` gives
`PersonReader` and `PersonBuilder`. A ``MessageBuilder`` writes one single-segment framed
message into a `MutableRawSpan` you own. It never allocates, never writes outside that storage,
and never traps: the first failure is kept in ``MessageBuilder/error``, and later writes do
nothing.

This builds the tutorial's `Person` (<doc:GettingStarted>), retries once if the storage was too
small, and reads the result back:

```swift
import CapnpRuntime

/// Build a Person in `byteCount` bytes of storage; return the message, or why it failed.
func buildPerson(byteCount: Int) -> (bytes: [UInt8], error: BuildError, required: Int) {
    var storage = [UInt8](repeating: 0, count: byteCount)  // InlineArray on Embedded
    var bytes: [UInt8] = []
    var error = BuildError.none
    var required = 0
    do {
        var span = storage.mutableSpan
        var message = MessageBuilder(storage: span.mutableBytes)
        do {
            var person = message.initRoot(Capnp_9c3f8a1b2c4d5e6f.PersonBuilder.self)
            person.setId(1)
            person.setName("Ada".utf8Span)  // copied into the message, with its NUL
            var hobbies = person.initHobbies(count: 2)
            hobbies.setElement("math".utf8Span, at: 0)
            hobbies.setElement("engines".utf8Span, at: 1)
        }
        error = message.error
        required = message.requiredByteCount
        let framed = message.framedBytes
        for i in 0..<framed.byteCount { bytes.append(framed.load(fromByteOffset: i, as: UInt8.self)) }
    }
    return (bytes, error, required)
}

var attempt = buildPerson(byteCount: 32)
if attempt.error == .outOfSpace {
    attempt = buildPerson(byteCount: attempt.required)  // exact: the same steps fit
}
```

Here the first attempt fails ``BuildError/outOfSpace`` and reports 80 bytes, and the retry with
80 bytes succeeds. ``MessageBuilder/framedBytes`` opens directly in ``Arena``, so a message can
be read back without copying.

## Accessors are methods

A field `foo` gets:

- `foo()` and `setFoo(_:)` for scalars and enums
- `initFoo()` and `clearFoo()` for structs
- `setFoo(_:)` and `clearFoo()` for text (a `UTF8Span`, so only valid UTF-8 is written) and
  data (a `Span<UInt8>`)
- `initFoo(count:)` and `clearFoo()` for lists, which return a typed list builder such as
  ``PrimitiveListBuilder`` or ``StructListBuilder``

They are methods because a public get/set property on these views emits an allocating
`modify` coroutine on Swift 6.4.2.

## Views are exclusive

``MessageBuilder`` and every builder are `~Copyable` and `~Escapable`. A child view borrows its
parent, so the compiler rejects using the parent while the child is alive: build children one
after another, each in its own scope, as above.

## Errors

- ``BuildError/outOfSpace``: retry with ``MessageBuilder/requiredByteCount`` bytes, which is
  exact when the same build steps run again.
- ``BuildError/messageTooLarge``: no storage can hold the message, which happens past 4 GiB, or
  about 256 MiB on a 32-bit target, so don't retry.
- ``BuildError/listTooLong``: a list, text or data past the wire format's 2^29 - 1 elements.
- ``BuildError/nestingLimit``: deeper than the default reader's 64 levels, so the default
  reader could not read the message.
- ``BuildError/invalidLayout``: an index or count outside what the struct or list allows.
