# ``CapnpRuntime``

An allocation-free Swift runtime for reading Cap'n Proto messages, with generated
readers that borrow message bytes directly instead of copying them.

## Overview

`CapnpRuntime` is the reader half of capnproto-swift: the runtime library that generated
code (from `capnpc-swift`) builds on to decode a Cap'n Proto message. It has no
Foundation dependency, never allocates on the heap, and is verified to compile under
Embedded Swift's `-no-allocations` mode — see <doc:WhyCapnProto> for why that's the point
of the whole design, not an incidental feature.

Every reader (`StructReader`, `ListReader`, `TextReader`, and the generated types built
from them) is `~Escapable`: it borrows the byte buffer supplied to ``Arena``, and the
compiler enforces that it cannot outlive the ``Arena/withRoot(_:)`` scope it was read in.
Reads are lazy and fail soft — a malformed field returns its schema default and records
the *first* error on the arena, rather than throwing or crashing partway through a
message. Check ``Arena/error`` after you've read what you need.

Writing messages is arriving in v2: ``MessageBuilder`` already builds structs and scalars into
caller storage, with the same allocation-free, compiler-checked model, but generated builders,
text, data and lists are not in yet. RPC is out of scope. The
[package README](https://github.com/hooman/capnproto-swift#readme) has the current status.

## Topics

### Essentials

- <doc:WhyCapnProto>
- <doc:GettingStarted>
- ``Arena``
- ``Packed``

### Reading a message

- ``StructReader``
- ``ListReader``
- ``CapnpList``
- ``PrimitiveList``
- ``EnumList``
- ``VoidList``
- ``PointerReader``
- ``TextReader``
- ``DataReader``

### Building a message

- ``MessageBuilder``
- ``StructBuilder``
- ``BuildError``

### Generated-code support

These are public because generated readers live in your module and call them. They are
source-stable within a minor release, but they are not designed as a hand-written API.
Read messages through generated readers where you can.

- ``CapnpStructReader``
- ``CapnpListElement``
- ``CapnpPrimitive``
- ``CapnpEnum``
- ``ElementSize``

### Limits and errors

- ``ReaderOptions``
- ``ReadError``
