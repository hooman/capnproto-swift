# Reader architecture

## Storage and lifetimes

`Arena: ~Copyable, ~Escapable` borrows caller-owned `RawSpan` storage and owns two
atomics: a remaining traversal-word budget and a sticky first-error code. The
arena cannot be copied or sent across concurrency domains. `withRoot` borrows its
state through the standard library’s `withUnsafePointer` scope and a nonescapable
`Span<ReadState>`. No raw state pointer is stored in a reader. Every derived
`ReadContext` retains both the message span and state span lifetime dependencies.
The closure result must be escapable, so reader views cannot leave that scope.

Reader views are immutable, copyable, and nonescapable. Copying a view copies
positions and lifetime dependencies, not the message or limiter. This is deliberate:
The verified Swift 6.3.1 build synthesizes coroutine accessors with allocator references when computed
properties return noncopyable views. Copyable views compile without those allocator
references and keep the compiler-enforced lifetime proof. Arena ownership remains
unique. Lifetime-positive and escape-negative compiler fixtures guard this boundary.

## Wire access

`Frame` validates the entire segment-size table before traversal. Segment lookup
scans that table without allocating an index; the configurable segment-count cap
bounds lookup work. The implementation accepts trailing bytes and reports the
first frame’s byte count. `Arena(bytes:)` accepts one unframed segment.

`RawPointer` decodes the pointer word; `PointerReader` follows offsets and validates
single/double-far landing pads, segment IDs, object sizes, and list tags. Every
arithmetic conversion to an address follows range checks. Frame size is capped at
`Int.max / 8` so bit-addressed scalar loads cannot overflow an `Int`.

The small internal `widen` helpers and `_lowWord` conversions avoid a Swift 6.2/6.3
32-bit generic-integer conversion path that instantiates allocating `Words` storage.
The constant 64-bit pointer shift uses the masking operator for the same reason.
Both supported compilers exercise these paths through the ARM Embedded gate.

`StructReader` zero-extends absent fields and XORs scalar defaults. `ListReader`
uses a bit stride and per-element data/pointer sizes for all eight wire encodings.
Primitive-list views and generated concrete view-list wrappers provide indexed
access. Lists can be viewed through compatible older/newer struct layouts without
copying. Text requires a byte-list encoding, NUL termination, and valid UTF-8.

## Limits and failure semantics

Non-null pointer traversal consumes nesting depth. Reading a list’s struct element
consumes another level, matching the C++ reader. Struct/list bodies and far landing
pads charge the shared word budget; zero-sized lists additionally charge virtual
words per element. Bounds checks precede loads. The first error wins; later reads
can still inspect valid fields, so this is lazy validation, not an eager verifier.
Clients must check `Arena.error` after using the fields they intend to trust.

The runtime uses typed empty/default returns and a POD error enum instead of
throwing across Embedded boundaries. Null and capability pointers are empty without
error. Non-empty pointer defaults are explicitly unsupported. Custom conformances
to `CapnpPrimitive` are trusted code: their size and load implementation must obey
the protocol’s documented load contract.

## Generator

The host executable buffers at most 64 MiB from stdin and decodes exactly one
unpacked `CodeGeneratorRequest` through the runtime. Bootstrap offsets are
transcribed from upstream `schema.capnp.h`. It builds an owned schema model,
validates the supported subset, renders all files, then writes output. Unsupported
features produce a nonzero exit with a `capnpc-swift:` diagnostic. Output filenames
must be relative; normalized/symlink-resolved destinations must stay under the
compiler output directory. Rendering validates all requested files before writes;
filesystem errors during a multi-file write can still leave earlier files updated.
Path validation assumes the output directory is not concurrently mutated; it is not a
race-resistant filesystem sandbox. Schema source documentation is not yet emitted.

File IDs namespace generated readers. Unions use a raw discriminant enum without
borrowed associated values; group readers share the parent struct layout. The
same generated code imports the runtime on host and Embedded builds. There is no
Foundation, reflection, existential dispatch, or mutable message storage in the
runtime or generated output.

## Validation boundaries

Host tests cover scalar decoding, framing, far pointers, all list encodings,
UTF-8, malformed ranges, shared budgets, nesting, and deterministic malformed
traversal. `ci/check-readers.py` uses the upstream C++ compiler for end-to-end
fixtures and compiles generated readers against a separately compiled runtime.
`ci/check-cross.py` also roots that generated path in an exported C function.
The Embedded gate requires `-no-allocations` compilation, absence of allocator
symbols, and rejection of an allocating negative control. These tests are a bounded
suite, not exhaustive wire-format certification or a security audit.

## Revisiting implementation choices

Swift 6.2 remains the package floor; the release compilers exercised by CI are 6.2.4
and 6.3.1. Experimental `Lifetimes` and `Embedded` features are explicit build inputs.
The no-existentials/no-Foundation policy describes this runtime, not every capability
of newer Embedded Swift releases.

Revisit a workaround with a concrete replacement: preserve error/default behavior,
run the generated cross-module and lifetime tests, compile with -no-allocations, and
audit emitted symbols on every supported target. A compiler accepting a new syntax
or a proposal being accepted is insufficient evidence to change these guarantees.

For a new Embedded toolchain, inspect its platform ABI and allocator entry points
before trusting the existing symbol pattern. For a new SDK, separately prove build,
link and execution: current Linux glibc and ARM object checks do not establish Static
Linux SDK (musl), Wasm/WASI, or physical-device support. Host allocation by the compiler,
fixture encoder and test harness does not relax the runtime's allocation constraint.
