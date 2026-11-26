# Why Cap'n Proto

Learn what makes Cap'n Proto different from Protocol Buffers, and why that difference
matters most on embedded and other memory-constrained Swift targets.

## Overview

If you know Protocol Buffers (protobuf) but have never used Cap'n Proto, the two look
similar from a distance: both are schema-first, both generate typed code from a `.proto`-
or `.capnp`-style file, and both are used at Google-scale and in tiny embedded firmware
alike. The difference that matters is not in the schema language. It's in what happens
the moment you call "decode."

### The one-sentence version

Protocol Buffers' wire format is a compact encoding that a generated parser turns into
native objects. Cap'n Proto's wire format **is** the in-memory layout — reading a message
means walking pointers directly over the bytes you received, not building a parallel copy
of them. Cap'n Proto's own documentation calls this "infinitely faster," and while no
format is literally free, the mechanism is real and it's the reason this library exists.

### What that buys you, concretely

| | Protocol Buffers (typical Swift binding) | Cap'n Proto readers (this library) |
|---|---|---|
| Reading a message | Parses the wire encoding into new, heap-allocated Swift objects — one allocation graph per decode | Constructs lightweight views directly over the byte buffer you already have |
| Memory ownership | The decoded object tree is independent of the input bytes; the input can be freed | Every reader **borrows** the input buffer; the compiler enforces that it cannot outlive it |
| Runtime dependencies | Typically depends on Foundation and the standard heap allocator | The runtime (`CapnpRuntime`) depends on neither — see below |
| String/byte fields | Copied into owned `String`/`Data` during decode | Exposed as validated borrowed views (`TextReader`, `DataReader`) — no copy |
| Safety against malformed input | Depends on the implementation | Traversal budget, nesting-depth limit, and zero-size amplification guards are always on (see <doc:GettingStarted>) |

None of this makes Cap'n Proto strictly "better" — it's a different point in the design
space, and this table is not a knock on protobuf, which is a mature, capable format.
The distinction is that Cap'n Proto's zero-copy design lines up almost exactly with what
Swift's ownership features (`~Escapable`, borrowing, lifetime dependencies) were built to
express, and it lines up even more directly with what an embedded target actually needs.

## Why this matters more on embedded targets

A general-purpose protobuf runtime decodes into a tree of reference-counted or
heap-allocated model objects. That's a reasonable trade on a server or a phone, where
heap allocation is cheap and plentiful. It's not a reasonable trade on a microcontroller,
where the heap might be a few kilobytes — or might not exist as a general-purpose
allocator at all.

This project's runtime, `CapnpRuntime`, is built around that constraint directly, not as
an afterthought:

- **It never allocates.** This isn't a performance goal stated in prose — it's a compiled
  invariant. The runtime is required to build under Embedded Swift's `-no-allocations`
  mode, where any reachable heap allocation is a **compile error**. A three-stage gate
  (Embedded compilation, an `nm` symbol audit for allocator entry points, and a negative
  control that must be *rejected*) keeps that claim from silently rotting — the negative
  control exists because a synthesized coroutine allocation has, in the past, slipped
  past the compiler's own diagnostic on a real toolchain.
- **It has no Foundation and no C++ dependency.** Only the host-side code generator
  (`capnpc-swift`, which runs once, at build time, on your development machine) uses
  Foundation. What ships onto the device — `CapnpRuntime` plus your generated readers —
  is pure Swift standard library, so there's no C++ runtime to port and no Foundation
  subset to worry about on an unfamiliar embedded target.
- **Generics specialize; there's no existential dispatch.** Fields and list elements are
  read through concrete, monomorphized generic code, not `any`-boxed protocols or
  reflection. That keeps generated code size predictable and avoids the indirection an
  embedded target can't afford to hide.
- **Safety is compiler-enforced, not just runtime-checked.** A reader is `~Escapable`: the
  compiler — not a runtime assertion — refuses to let a decoded view outlive the buffer it
  borrows from. Swift's newest ownership features exist for exactly this shape of problem.

The trade this library makes for all of that: **v1 is readers only.** There is no
builder for writing messages yet (designed for v2, not implemented) and no RPC layer (out
of scope). If your
embedded device only needs to *read* Cap'n Proto messages — telemetry frames, sensor
config, firmware manifests, IPC payloads — that trade is likely invisible to you already.
If you need to *construct* messages on the same constrained device, that's not this
library yet; see the [roadmap](https://github.com/hooman/capnproto-swift) for where that
work stands.

## Where this leaves the server-side case

Everything above still holds off the embedded path. A server- or CLI-side Swift program
gets the same zero-copy reads, the same compiler-enforced lifetime safety, and the same
freedom from a decode-time allocation storm on the hot path of parsing untrusted network
input — traversal-budget and nesting-limit guards exist specifically because message
bytes are not assumed to come from a trusted encoder. You don't need Embedded Swift to
benefit from any of that; you only need it to run the same code on a target that has no
heap at all.

## Next steps

- Work through <doc:GettingStarted> to generate readers for a real schema and decode a
  message end to end.
- See the [package README](https://github.com/hooman/capnproto-swift#readme) for the
  full supported-scope list and current platform evidence.
- See ``CapnpRuntime`` for the reader API itself.
