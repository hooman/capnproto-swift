// StructReader tests — hand-built data + pointer-section bytes (NOT a full framed
// message: no stream header, no root pointer; full-message navigation needs the resolver
// and is milestone 2). Host tests run with the full stdlib; the Embedded gate is the
// separate compile check in ci/check-embedded-clean.sh.
//
// Lifetime correctness is COMPILE-TIME: the `~Escapable` reader compiling under its
// `@_lifetime(borrow arena)` is the proof. Every reader is built and used inside a single
// `withUnsafeBytes` scope, so it cannot escape the buffer it views.
//
// Building an `Arena` requires `Atomic` (macOS 15 / iOS 18 / … — see Arena.swift's
// availability finding). swift-testing's `@Test` cannot sit on an `@available` function,
// so each test runtime-guards with `#available` instead; on a current host this always
// passes.

import Testing
@testable import CapnpRuntime

// MARK: - Fixture

/// Little-endian byte writer (no-op byte-swap on the LE targets Swift supports).
private func writeLE<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8], at offset: Int) {
    var v = value.littleEndian
    withUnsafeBytes(of: &v) { src in
        for i in 0..<src.count { bytes[offset + i] = src[i] }
    }
}

/// A known region: 4 data words (32 B) + 2 pointer words (16 B) = 48 B. Field offsets
/// are in units of each field's own size (the schema's convention), laid at DISJOINT
/// bit-intervals so nothing overlaps:
///
///   data section (bytes 0…31, dataSizeBits = 256):
///     elem-off  0  (UInt32)  bytes  0…3    0x12345678   (plain value, default 0)
///     elem-off  1  (UInt32)  bytes  4…7    0xAAAAAAAA   (XOR test, default 0x0F0F0F0F)
///     elem-off  1  (Double)  bytes  8…15   3.5          (bit-pattern path, default 0)
///     elem-off  8  (UInt16)  bytes 16…17   7            (enum raw value, default 0)
///     byte 18 = 0x01         bits 144…146  bool triple  (see boolBits test)
///     elem-off  6  (UInt32)  bytes 24…27   0            (XOR: stored 0 ⇒ reads default)
///     elem-off  7  (UInt32)  bytes 28…31   0x600DF00D   (LAST valid slot: ends exactly at
///                                                        bit 256 = dataSizeBits — pins the
///                                                        `>` vs `>=` boundary off-by-one)
///   pointer section (bytes 32…47, ptrCount = 2):
///     ptr 0  struct pointer: offset 1, dataWords 2, ptrWords 1  (low word = 4, NON-zero:
///            makes byte 32 a discriminating value for the past-section bounds check)
///     ptr 1  far pointer:    position 5, segment 3, not double-far
private func makeRegion() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 48)
    writeLE(UInt32(0x1234_5678), to: &b, at: 0)
    writeLE(UInt32(0xAAAA_AAAA), to: &b, at: 4)
    writeLE(Double(3.5).bitPattern, to: &b, at: 8)
    writeLE(UInt16(7), to: &b, at: 16)
    b[18] = 0x01                                        // bit 0 set; bits 1,2 clear
    // bytes 24…27 left zero (stored-zero XOR-default case)
    writeLE(UInt32(0x600D_F00D), to: &b, at: 28)        // last valid data slot (offset 7)
    writeLE((UInt64(0x0001_0002) << 32) | 4, to: &b, at: 32)  // struct ptr: high=0x00010002, low=4
    writeLE((UInt64(3) << 32) | 42, to: &b, at: 40)     // far ptr: high=3, low=42
    return b
}

// MARK: - Tests

struct StructReaderTests {

    /// Each `data<T>(at:default:)` returns the written value; offsets follow `Wire` strides.
    @Test func dataFieldsReadWrittenValues() {
        guard #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) else { return }
        makeRegion().withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw), segmentID: 0)
            let r = StructReader(
                arena: arena, dataStartByte: 0, dataSizeBits: 256, ptrStartByte: 32, ptrCount: 2)

            #expect(r.data(at: 0, default: UInt32(0)) == 0x1234_5678)   // bytes 0…3
            #expect(r.data(at: 1, default: Double(0)) == 3.5)           // bytes 8…15
            #expect(r.data(at: 8, default: UInt16(0)) == 7)            // bytes 16…17 (enum raw)

            // Stride sanity: the FourBytes field at elem-offset 1 lands at byte 4.
            #expect(Wire.bytesPerWord == 8)
            #expect(Wire.bitsPerWord == 64)
            #expect(Wire.pointerSizeInWords == 1)
            #expect(Wire.elementSizeBitsFourBytes == 32)
            #expect(Wire.elementSizeBitsEightBytes == 64)
        }
    }

    /// XOR-default unmasking: stored bits XOR the schema default; stored-zero ⇒ default.
    @Test func xorDefaultUnmasking() {
        guard #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) else { return }
        makeRegion().withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw), segmentID: 0)
            let r = StructReader(
                arena: arena, dataStartByte: 0, dataSizeBits: 256, ptrStartByte: 32, ptrCount: 2)

            // Stored 0xAAAAAAAA, default 0x0F0F0F0F ⇒ 0xAAAAAAAA ^ 0x0F0F0F0F = 0xA5A5A5A5.
            #expect(r.data(at: 1, default: UInt32(0x0F0F_0F0F)) == 0xA5A5_A5A5)
            // Stored bits zero ⇒ 0 ^ default = default (absent ≡ defaulted within section).
            #expect(r.data(at: 6, default: UInt32(0xCAFE_BABE)) == 0xCAFE_BABE)
            // Same field, different default ⇒ that default (proves it is XOR, not the raw bits).
            #expect(r.data(at: 6, default: UInt32(0x1357_9BDF)) == 0x1357_9BDF)
        }
    }

    /// Version-tolerant zero-extension: a field past `dataSizeBits` reads its default and
    /// never reads beyond the data section (even into the pointer section).
    @Test func versionToleranceZeroExtension() {
        guard #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) else { return }
        makeRegion().withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw), segmentID: 0)
            let r = StructReader(
                arena: arena, dataStartByte: 0, dataSizeBits: 256, ptrStartByte: 32, ptrCount: 2)

            // Far past the section ⇒ default.
            #expect(r.data(at: 1000, default: UInt32(0xDEAD_BEEF)) == 0xDEAD_BEEF)
            // LAST valid slot: offset 7 ends exactly at bit 256 == dataSizeBits ⇒ in range,
            // reads its written value. Catches a `>=` off-by-one that would wrongly reject it.
            #expect(r.data(at: 7, default: UInt32(0)) == 0x600D_F00D)
            // ONE PAST: offset 8 = bit 256, last bit 288 > 256 ⇒ default. This now
            // DISCRIMINATES — byte 32 (the struct ptr's low word) is 4, so if the bounds
            // check failed to fire it would return 4 ^ 0xFEEDFACE = 0xFEEDFACA, not the default.
            #expect(r.data(at: 8, default: UInt32(0xFEED_FACE)) == 0xFEED_FACE)
        }
    }

    /// `dataStartByte` actually shifts addressing — a reader based at a non-zero offset
    /// reads the bytes at that base. (Every other test uses base 0, so without this the
    /// `dataStartByte * 8 + fieldBit` term would be untested; m2's resolver feeds it in anger.)
    @Test func dataStartByteShiftsAddressing() {
        guard #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) else { return }
        makeRegion().withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw), segmentID: 0)
            // The Double 3.5 lives at byte 8; the UInt16 7 at byte 16. Read each via a
            // reader whose data section is BASED there at offset 0 — only correct if the
            // base term is applied (else these would read byte 0 and mismatch).
            let atEight = StructReader(
                arena: arena, dataStartByte: 8, dataSizeBits: 64, ptrStartByte: 40, ptrCount: 1)
            #expect(atEight.data(at: 0, default: Double(0)) == 3.5)

            let atSixteen = StructReader(
                arena: arena, dataStartByte: 16, dataSizeBits: 16, ptrStartByte: 40, ptrCount: 1)
            #expect(atSixteen.data(at: 0, default: UInt16(0)) == 7)
        }
    }

    /// Bool is bit-addressed; extraction + XOR-default are correct.
    @Test func boolBitExtraction() {
        guard #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) else { return }
        makeRegion().withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw), segmentID: 0)
            let r = StructReader(
                arena: arena, dataStartByte: 0, dataSizeBits: 256, ptrStartByte: 32, ptrCount: 2)

            // byte 18 = 0b00000001.
            #expect(r.data(at: 144, default: false) == true)   // bit 0 set,  default false ⇒ true
            #expect(r.data(at: 145, default: true) == true)    // bit 1 clear, default true  ⇒ true
            #expect(r.data(at: 146, default: false) == false)  // bit 2 clear, default false ⇒ false
            // A bool past the data section zero-extends to its default too.
            #expect(r.data(at: 5000, default: true) == true)
        }
    }

    /// `pointer(at:)` decodes (does not follow) the pointer word; out-of-range ⇒ null.
    @Test func pointerDecodeOnly() {
        guard #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) else { return }
        makeRegion().withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw), segmentID: 0)
            let r = StructReader(
                arena: arena, dataStartByte: 0, dataSizeBits: 256, ptrStartByte: 32, ptrCount: 2)

            let p0 = r.pointer(at: 0)
            #expect(p0.kind == .structure)
            #expect(p0.isNull == false)
            #expect(p0.signedOffsetWords == 1)   // low word 4 ⇒ Int32(4) >> 2 == 1
            #expect(p0.structDataWords == 2)
            #expect(p0.structPointerWords == 1)

            let p1 = r.pointer(at: 1)
            #expect(p1.kind == .far)
            #expect(p1.farIsDoubleFar == false)
            #expect(p1.farPositionWords == 5)
            #expect(p1.farSegmentID == 3)

            // Out-of-range index ⇒ null pointer (matches data-field version tolerance).
            #expect(r.pointer(at: 2).isNull == true)
            #expect(r.pointer(at: -1).isNull == true)
        }
    }
}
