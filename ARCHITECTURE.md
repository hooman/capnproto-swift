# Reader architecture

## Storage and lifetimes

`Arena: ~Copyable, ~Escapable, ~Sendable` borrows caller-owned `RawSpan` storage and
owns two atomics: a remaining traversal-word budget and a sticky first-error code. The
arena cannot be copied or sent across concurrency domains. `withRoot` borrows its
state as a non-optional SE-0519 `Ref<ReadState>`, a safe nonescapable borrow; no pointer
is formed. Every derived `ReadContext` retains both the message span and the state
reference lifetime dependencies.
The closure result must be escapable, so reader views cannot leave that scope.

Reader views are immutable, copyable, nonescapable, and explicitly `~Sendable` (SE-0518).
Copying a view copies positions and lifetime dependencies, not the message or limiter.
This is deliberate: computed properties and borrow accessors on noncopyable views still
synthesize coroutine allocator calls on verified Swift 6.4.x and `main` toolchains.
Copyable views compile without those allocator references and keep the compiler-enforced
lifetime proof. Arena ownership remains unique. The 38-fixture `ci/check-compile-fail.py`
suite guards lifetime, noncopyability, non-`Sendable`, and strict memory safety contracts.

## Wire access

`Frame` validates the entire segment-size table before traversal. Segment lookup
scans that table without allocating an index; the configurable segment-count cap
bounds lookup work. The implementation accepts trailing bytes and reports the
first frame’s byte count. `Arena(bytes:)` accepts one unframed segment.

`Packed` unpacks one packed frame into a caller-provided `MutableRawSpan`; the caller then
opens `Arena(framedBytes:)` over the bytes written. One word producer (`PackedWords`)
serves both `unpackFrame` and the size query `unpackedFrameByteCount`, so they cannot
disagree. The unpacker decodes the segment table first, checks the count against
`segmentLimit`, sums the 32-bit sizes in `UInt64`, and rejects a frame over
`traversalLimitWords` (as C++ `InputStreamMessageReader` does) or too large for `Int` or
the output before it walks the body. Runs may cross the table/body and segment boundaries;
a run still pending at the frame's last word is malformed, because no packed offset exists
where the next frame could start. C++ rejects runs that cross its separate reads of the
first word, the rest of the table, and the body. The C++ writer never emits them:
`writeMessage` passes the table and each segment as separate pieces, and
`PackedOutputStream` packs each piece on its own (upstream `851c45b`). Accepting them only
widens what this reader tolerates. Words are assembled from two `UInt32` halves:
a variable `UInt64` shift needs `__aeabi_llsl`, which the bare-metal link does not provide.

`Packed.pack` is the inverse, and matches `PackedOutputStream` byte for byte, which
`ci/check-readers.py` checks against `capnp encode --packed` for every oracle message and an
edge-case message (`ci/fixtures/packing.capnp`). Because the C++ writer packs the table and
each segment as separate pieces, the packer parses the frame's own table and packs piece by
piece, so its runs restart where the C++ runs do. An empty segment writes nothing. One walker,
`PackWriter`, serves both `pack` and the size query `packedFrameByteCount`. The table is
validated in `UInt64` before any size becomes an `Int`, and output is written a byte at a time
with a bounds check. Packed output is at most 10 bytes for every 8-byte word, so the count
cannot overflow.

`RawPointer` decodes the pointer word; `PointerReader` follows offsets and validates
single/double-far landing pads, segment IDs, object sizes, and list tags. Every
arithmetic conversion to an address follows range checks. Frame size is capped at
`Int.max / 8` so bit-addressed scalar loads cannot overflow an `Int`.

The small internal `widen` helpers and `_lowWord` conversions avoid a Swift 6.2/6.3
32-bit generic-integer conversion path that instantiates allocating `Words` storage
(kept on 6.4 until a probe shows the path is gone).
The constant 64-bit pointer shift uses the masking operator for the same reason.
The ARM Embedded gate exercises these paths on every supported compiler.

`StructReader` zero-extends absent fields and XORs scalar defaults. `ListReader`
uses a bit stride and per-element data/pointer sizes for all eight wire encodings.
`PrimitiveList<Element>`, `VoidList`, and unified generic `CapnpList<Element: CapnpListElement & ~Escapable>`
(with generated struct readers conforming to `CapnpStructReader`) provide indexed access
without per-field generated list wrapper structs, specializing cleanly across Embedded
module boundaries. Lists can be viewed through compatible older/newer struct layouts
without copying. `DataReader` exposes `bytes: Span<UInt8>` via an SE-0507 `borrow`
accessor and conforms to SE-0516 `Iterable`. `TextReader` requires a byte-list encoding,
NUL termination, and valid UTF-8 checked once through `UTF8Span(validating:)`, exposing
`utf8: UTF8Span` (`borrow`), `bytes: Span<UInt8>`, and `Iterable`.

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

## Builders

`MessageBuilder: ~Copyable, ~Escapable, ~Sendable` borrows a caller `MutableRawSpan` and
owns the allocation state: bytes used, bytes required, and a sticky `BuildError`. Storage bytes
0..<8 hold the frame header and 8..<16 the root pointer; the single segment grows from byte 8
by bump allocation, so every pointer written points forward. The usable size is rounded down
to whole words and capped at `Int.max / 8` bytes and at 2^29 words (4 GiB). Every object
follows its pointer in the one segment, so every offset fits the signed 30-bit pointer field
and the segment size fits the header; neither overflows an `Int` on 32-bit targets. Larger
messages need far pointers and more segments, which come later.

`StructBuilder` views are exclusive. Each holds a reborrowed `MutableRawSpan` of the whole
storage (`_mutatingExtracting`) and a SE-0519 `MutableRef<BuildState>`. `initRoot` and
`initStruct` are `mutating` and `@_lifetime(&self)`, so a child borrows its parent and the
compiler rejects aliased writes, copies and escapes; no `unsafe` is involved. A copyable
view would need raw pointers. Accessors are methods: on 6.4.2 a public get/set property on
these views emits an allocating `modify` coroutine that `-no-allocations` does not reject.

Allocation zeroes what it hands out and updates the header's segment size. A zero-sized
struct is encoded with offset −1. Re-initializing a pointer, or `clearPointer`, first zeroes
the old object and its subtree recursively; recursion is bounded because no struct deeper
than 64 levels (`.nestingLimit`, the default reader limit) is ever built. After a failure,
views carry their sizes but no storage: writes are no-ops, and allocation keeps counting, so
`requiredByteCount` is exact for a retry. Past the most any storage can hold, allocation
fails `.messageTooLarge` instead, replacing an earlier `.outOfSpace`, since no retry could
succeed. Lists are allocated whole by `Builder.linkList`: element counts and
inline-composite word totals are checked against 2^29 − 1 before any multiplication
(`.listTooLong`), word counts are derived by division so they cannot overflow, and a byte
size that would overflow a 32-bit `Int` is `.messageTooLarge`. Each typed list builder
checks that the list it wraps has its shape, so a hand-written `CapnpListBuilder` cannot pair
one shape with another builder's accessors (`.invalidLayout`). Text is a byte list with its NUL
and data has none; both are copied a word at a time. Typed list builders
(`PrimitiveListBuilder`, `EnumListBuilder`, `VoidListBuilder`, `TextListBuilder`,
`DataListBuilder`, `StructListBuilder`, `ListListBuilder`) wrap an untyped `ListBuilder` and
conform to `CapnpListBuilder`, whose static `ListShape` tells `initList` what to allocate.
Zeroing an old object follows list pointers too: pointer lists' elements and inline-composite
elements' pointer sections are zeroed first, then the body. Scalars are stored by `CapnpPrimitive.storeMasked`,
XOR the default; integer and float stores use the SE-0525 byte-order `storeBytes`, and words
are written as two `UInt32` halves to avoid 64-bit shifts on 32-bit targets.

## Generator

The host executable buffers at most 64 MiB from stdin and decodes exactly one
unpacked `CodeGeneratorRequest` through the runtime. Bootstrap offsets are
transcribed from upstream `schema.capnp.h`. It builds an owned schema model,
validates the supported subset, renders all files, then writes output. Annotations are
never read, and annotation declarations are skipped. Doc comments come from
`sourceInfo` and are read as bytes, not through `text()`: `text()` validates UTF-8 and
sets the arena's sticky error, so one bad comment would fail the request. Invalid UTF-8
becomes U+FFFD. Each of CR, LF and CRLF ends a `///` line; control characters other
than tab, the bidi override and isolate characters (U+202A–U+202E, U+2066–U+2069) and
trailing whitespace are dropped. Docs are cosmetic: a missing entry means no comment, an
empty member list means no member comments, and a member list whose length differs from a
rendered struct's fields drops that struct's member comments and prints a
`capnpc-swift: warning:` on stderr. Structural corruption inside `sourceInfo`, such as a
bad pointer, still fails the request like any other malformed message. Enums become Swift
enums with a `UInt16` raw value; an enum field's getter wraps a `_capnpRaw_` accessor that
applies the schema default, so unknown ordinals read as `nil` but stay readable. Enums
Swift cannot represent (no enumerants, or a name that would shadow one the generated code
uses unqualified) and duplicate generated type names are diagnosed when the declaration is
rendered, never while decoding, so an imported file that is not generated may contain them.
Scalar and enum constants render as computed `static var`s, with no global storage or lazy
initialization, reusing the field-default expressions; floats are written by bit pattern.
Constants of other types need an embedded default-message reader, the same mechanism as
non-empty pointer defaults, and are diagnosed at render time like unrepresentable enums.
Other unsupported declarations in a requested file, and fields whose own type is
unsupported (an interface, AnyPointer or generic type, even when imported), produce a
nonzero exit with a `capnpc-swift:` diagnostic. An imported struct is checked only when its own file is generated. Output filenames
must be relative with no empty, `.`, `..`, or control-character components; preflight
walks existing parent components via `lstat` so symlinked directories are resolved even
when the leaf file does not yet exist, and rejects escaping symlinks, symlink leaves,
and directory collisions. Rendering validates all requested files before writes; writes
are atomic per file and newly created files are rolled back on a mid-run write failure.
Path validation assumes the output directory is not concurrently mutated; it is not a
race-resistant filesystem sandbox.

Each struct's builder is one block after its reader, so reader output is unchanged; nested
structs' and groups' builders nest inside it. Builders wrap a `StructBuilder` and conform to
the generated-code-only `CapnpStructBuilder`, whose static sizes let
`MessageBuilder.initRoot(_:)` and `init…` methods allocate the right layout. A group builder
is a `reborrow()` of its parent's view. Accessors are methods named after the field (`foo()`,
`setFoo(_:)`, `initFoo()`, `clearFoo()`), and a name used twice in one builder, or a builder
type name that collides with a sibling, is diagnosed. Setting a union member first zeroes
every member's storage (data bits, pointer subtrees, a group's fields and own discriminant),
then writes the discriminant; this is stricter than C++, which leaves inactive members'
bits. Text setters take a `UTF8Span` and data setters a `Span<UInt8>`; list fields return a
typed list builder from `initFoo(count:)`. `ci/check-readers.py` holds
builders to the C++ encoder in reverse: each Swift-built message must equal `capnp encode` of
the same content in canonical form, decode to the same text, and leave every word that no
pointer reaches zero, which canonical form alone cannot see. With text, data and lists, the
same check rebuilds all 9 C++ oracle messages of the reader fixture from generated builders.

File IDs namespace generated readers, which emit `public import CapnpRuntime` so
consumers enabling `InternalImportsByDefault` can expose generated types directly. Unions
use a raw discriminant enum without borrowed associated values; group readers share the
parent struct layout. The same generated code imports the runtime on host and Embedded
builds. There is no Foundation, reflection, existential dispatch, or mutable message
storage in the runtime or generated output.

## Validation boundaries

Host tests (96 tests, 97.5% `CapnpRuntime` line coverage on 6.4.2) cover scalar decoding, framing,
packed framing (hand-packed frames, including boundary-crossing runs and hostile tables),
far pointers, all list encodings, nested generic lists, UTF-8/Span/Iterable blob views,
malformed ranges, shared budgets, nesting, and single- and multi-segment deterministic
malformed traversal, and the builder answer key (hand-computed frames, re-initialization, the
out-of-space sweep with guard bytes at aligned and unaligned offsets, limits). `ci/check-readers.py` uses the upstream C++ compiler for end-to-end
fixtures, unpacks the committed `capnp encode --packed` form of each oracle message and
requires it to equal the unpacked encoding byte for byte, runs output-boundary hardening tests (lexical/symlink escapes, collisions, and
read-only rollback), delegates the 38-fixture `ci/check-compile-fail.py` suite, and
compiles generated readers against a separately compiled Embedded runtime.
`ci/check-cross.py` roots that generated path in an exported C function, `ci/check-link.sh`
links a bare-metal ARMv7E-M firmware image against `stubs.c` only and reports both ELF
and loadable flash size, `ci/check-wasm.py` executes full and Embedded Wasm/WASI builds
under WasmKit, `ci/check-qemu.py` boots a `-no-allocations` reader image on emulated
Cortex-M4 and RV32 bare metal (QEMU `mps2-an386` and `virt`, semihosting for output and
exit status) with the same inputs and the 32-bit suites in `ci/fixtures/edges32.swift`, and `ci/check-static-linux.py` verifies `aarch64`/`x86_64` musl static
ELF binaries in `FROM scratch` Linux containers. The Embedded gate requires
`-no-allocations` compilation, absence of allocator symbols, and rejection of an
allocating negative control. These tests are a bounded suite, not exhaustive wire-format
certification or a security audit.

## Revisiting implementation choices

Swift 6.4 is the package floor and Apple targets require OS 27: the package is a
language-feature test bed and does not back-deploy. CI runs Swift.org 6.4.0 and a weekly
`main` snapshot (with local qualification on 6.4.2-RELEASE and `main-snapshot-2026-11-01`).
Scalar loads use SE-0525's checked `RawSpan.load(fromByteOffset:as:_:)`; the runtime
builds with strict memory safety and contains zero `unsafe` expressions: `Arena.withRoot`
lends the shared accounting state to every view as a non-optional SE-0519 `Ref<ReadState>`,
a safe, nonescapable borrow. Experimental `Lifetimes` and `Embedded` features are explicit
build inputs. The no-existentials/no-Foundation policy describes this runtime, not every
capability of newer Embedded Swift releases.

Revisit a workaround with a concrete replacement: preserve error/default behavior,
run the generated cross-module and lifetime tests, compile with -no-allocations, and
audit emitted symbols on every supported target. A compiler accepting a new syntax
or a proposal being accepted is insufficient evidence to change these guarantees.

For a new Embedded toolchain, inspect its platform ABI and allocator entry points
before trusting the existing symbol pattern. For a new SDK, separately prove build,
link and execution: current Linux glibc and ARM object checks do not establish Static
Linux SDK (musl), Wasm/WASI, or physical-device support. Host allocation by the compiler,
fixture encoder and test harness does not relax the runtime's allocation constraint.
