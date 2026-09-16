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

This is a **readers-only** library. There is no mutable builder yet and no RPC layer;
see the [project roadmap](https://github.com/hooman/capnproto-swift) for what's tracked
and what's deliberately out of scope.

## Topics

### Essentials

- <doc:WhyCapnProto>
- <doc:GettingStarted>
- ``Arena``

### Reading a message

- ``StructReader``
- ``ListReader``
- ``PrimitiveList``
- ``PointerReader``
- ``TextReader``
- ``DataReader``

### Limits and errors

- ``ReaderOptions``
- ``ReadError``
- ``ElementSize``

### Wire format

- ``RawPointer``
