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
lifetime proof. Arena ownership remains unique. The 25-fixture `ci/check-compile-fail.py`
suite guards lifetime, noncopyability, non-`Sendable`, and strict memory safety contracts.

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
bad pointer, still fails the request like any other malformed message. Other unsupported declarations in a
requested file, and fields whose own type is unsupported (an enum, interface, AnyPointer
or generic type, even when imported), produce a nonzero exit with a `capnpc-swift:`
diagnostic. An imported struct is checked only when its own file is generated. Output filenames
must be relative with no empty, `.`, `..`, or control-character components; preflight
walks existing parent components via `lstat` so symlinked directories are resolved even
when the leaf file does not yet exist, and rejects escaping symlinks, symlink leaves,
and directory collisions. Rendering validates all requested files before writes; writes
are atomic per file and newly created files are rolled back on a mid-run write failure.
Path validation assumes the output directory is not concurrently mutated; it is not a
race-resistant filesystem sandbox. Schema source documentation is not yet emitted.

File IDs namespace generated readers, which emit `public import CapnpRuntime` so
consumers enabling `InternalImportsByDefault` can expose generated types directly. Unions
use a raw discriminant enum without borrowed associated values; group readers share the
parent struct layout. The same generated code imports the runtime on host and Embedded
builds. There is no Foundation, reflection, existential dispatch, or mutable message
storage in the runtime or generated output.

## Validation boundaries

Host tests (31 tests, 98.7% `CapnpRuntime` line coverage) cover scalar decoding, framing,
far pointers, all list encodings, nested generic lists, UTF-8/Span/Iterable blob views,
malformed ranges, shared budgets, nesting, and single- and multi-segment deterministic
malformed traversal. `ci/check-readers.py` uses the upstream C++ compiler for end-to-end
fixtures, runs output-boundary hardening tests (lexical/symlink escapes, collisions, and
read-only rollback), delegates the 25-fixture `ci/check-compile-fail.py` suite, and
compiles generated readers against a separately compiled Embedded runtime.
`ci/check-cross.py` roots that generated path in an exported C function, `ci/check-link.sh`
links a bare-metal ARMv7E-M firmware image against `stubs.c` only and reports both ELF
and loadable flash size, `ci/check-wasm.py` executes full and Embedded Wasm/WASI builds
under WasmKit, and `ci/check-static-linux.py` verifies `aarch64`/`x86_64` musl static
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
