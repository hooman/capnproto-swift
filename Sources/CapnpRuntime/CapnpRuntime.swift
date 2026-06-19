// CapnpRuntime — allocation-free, Foundation-free Cap'n Proto runtime.
//
// Must stay Embedded-clean: compiles under `-no-allocations` (heap use = compile error).
// See the workspace anchors/INVARIANTS.md and decisions/DECISIONS.md.
//
// Milestone 1 (keystone reader mechanics) ships, bottom-up:
//   • Wire.swift            — wire-format constants & strides.
//   • CapnpPrimitive.swift  — typed LE load + XOR-default (constraint, never `any`).
//   • RawPointer.swift      — POD decode of the 64-bit pointer word.
//   • Arena.swift           — ~Copyable, ~Escapable carrier + Atomic read-limiter.
//   • StructReader.swift    — the ~Escapable keystone reader (data fields + pointer decode).
//
// Out of this milestone (see DECISIONS.md): pointer *following* / the resolver
// (milestone 2), far pointers & multi-segment (2b, D-12), lists (D-13), text/data, the
// generated skin (D-7), and the writer (D-9).

/// Embedded-gate concrete root — replaces the throwaway `_gateCanary` with a drive of the
/// REAL reader surface.
///
/// Why this exists: the Embedded `-no-allocations` gate's strength is that any reachable
/// heap allocation is a compile error, and its `nm` audit inspects emitted symbols. But
/// under Embedded `-wmo` an *uncalled* generic emits no code, so `StructReader.data<T>`
/// would be invisible to the gate without a concrete call site. This function drives the
/// whole chain at concrete types — `Arena` → `StructReader` → `data<UInt32>` (FourBytes
/// load) + `data<Bool>` (bit-addressed load) + `pointer(at:)` (pointer decode) + a limiter
/// `charge` — so the gate actually covers the load path. (It is exercised at compile time
/// by the gate; it is not called at runtime.)
///
/// This is NOT the public "read the root from a framed message" entry — that needs the
/// resolver and is milestone 2. Gated at the Synchronization floor (it builds an `Arena`;
/// see Arena.swift's availability finding).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public func _embeddedGateRoot(_ ptr: UnsafeRawPointer, _ byteCount: Int) -> UInt64 {
    let span = RawSpan(_unsafeBytes: UnsafeRawBufferPointer(start: ptr, count: byteCount))
    let arena = Arena(bytes: span, segmentID: 0)
    arena.charge(words: 1)
    // One data word (bytes 0…7) then one pointer word (bytes 8…15).
    let reader = StructReader(
        arena: arena,
        dataStartByte: 0, dataSizeBits: Wire.bitsPerWord,
        ptrStartByte: Wire.bytesPerWord, ptrCount: 1)
    let u = reader.data(at: 0, default: UInt32(0))   // FourBytes (specializes data<UInt32>)
    let b = reader.data(at: 32, default: false)      // bit 32 = byte 4 (specializes data<Bool>)
    let p = reader.pointer(at: 0)                     // pointer decode
    return UInt64(u) &+ (b ? 1 : 0) &+ UInt64(p.lowWord)
}
