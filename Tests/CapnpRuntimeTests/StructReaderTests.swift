// Hand-built data and pointer regions isolate scalar addressing from pointer resolution.
// Distinct adjacent values make wrong strides and data-section overruns observable.
// ResolverTests covers framed navigation; ci/check-readers.py separately requires the
// compiler to reject escaping reader lifetimes.

import Testing
@testable import CapnpRuntime

private func writeLE<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8], at offset: Int) {
    var v = value.littleEndian
    withUnsafeBytes(of: &v) { src in
        for i in 0..<src.count { bytes[offset + i] = src[i] }
    }
}

// Fixture layout (field offsets count elements of that field's type):
//   data bytes  0...3: UInt32 offset 0, raw 0x12345678
//               4...7: UInt32 offset 1, raw 0xAAAAAAAA (nonzero XOR mask)
//              8...15: Double offset 1, raw bits of 3.5
//             16...17: UInt16 offset 8, raw 7
//                  18: Bool offsets 144...146, raw bits 1, 0, 0
//             24...27: UInt32 offset 6, stored zero (schema default)
//             28...31: UInt32 offset 7, last complete data slot
//   pointer bytes 32...39: struct, relative offset 1, two data words, one pointer
//                 40...47: single-far, position 5 in segment 3
// The first pointer has nonzero low bits so reading past the data section cannot
// accidentally return the expected default. These pointers are decoded, not followed.
private func makeRegion() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 48)
    writeLE(UInt32(0x1234_5678), to: &b, at: 0)
    writeLE(UInt32(0xAAAA_AAAA), to: &b, at: 4)
    writeLE(Double(3.5).bitPattern, to: &b, at: 8)
    writeLE(UInt16(7), to: &b, at: 16)
    b[18] = 0x01
    writeLE(UInt32(0x600D_F00D), to: &b, at: 28)
    writeLE((UInt64(0x0001_0002) << 32) | 4, to: &b, at: 32)
    writeLE((UInt64(3) << 32) | 42, to: &b, at: 40)
    return b
}

struct StructReaderTests {

    @Test func dataFieldsReadWrittenValues() {
        makeRegion().withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw), segmentID: 0)
            let r = StructReader(
                arena: arena, dataStartByte: 0, dataSizeBits: 256, ptrStartByte: 32, ptrCount: 2)

            #expect(r.data(at: 0, default: UInt32(0)) == 0x1234_5678)
            #expect(r.data(at: 1, default: Double(0)) == 3.5)
            #expect(r.data(at: 8, default: UInt16(0)) == 7)

            #expect(Wire.bytesPerWord == 8)
            #expect(Wire.bitsPerWord == 64)
            #expect(Wire.pointerSizeInWords == 1)
            #expect(Wire.elementSizeBitsFourBytes == 32)
            #expect(Wire.elementSizeBitsEightBytes == 64)
        }
    }

    @Test func xorDefaultUnmasking() {
        makeRegion().withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw), segmentID: 0)
            let r = StructReader(
                arena: arena, dataStartByte: 0, dataSizeBits: 256, ptrStartByte: 32, ptrCount: 2)

            #expect(r.data(at: 1, default: UInt32(0x0F0F_0F0F)) == 0xA5A5_A5A5)
            #expect(r.data(at: 6, default: UInt32(0xCAFE_BABE)) == 0xCAFE_BABE)
            #expect(r.data(at: 6, default: UInt32(0x1357_9BDF)) == 0x1357_9BDF)
        }
    }

    @Test func versionToleranceZeroExtension() {
        makeRegion().withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw), segmentID: 0)
            let r = StructReader(
                arena: arena, dataStartByte: 0, dataSizeBits: 256, ptrStartByte: 32, ptrCount: 2)

            #expect(r.data(at: 1000, default: UInt32(0xDEAD_BEEF)) == 0xDEAD_BEEF)
            #expect(r.data(at: 7, default: UInt32(0)) == 0x600D_F00D)
            #expect(r.data(at: 8, default: UInt32(0xFEED_FACE)) == 0xFEED_FACE)
        }
    }

    // Moving the same field to offset zero in a subregion isolates the base-address term.
    @Test func dataStartByteShiftsAddressing() {
        makeRegion().withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw), segmentID: 0)
            let atEight = StructReader(
                arena: arena, dataStartByte: 8, dataSizeBits: 64, ptrStartByte: 40, ptrCount: 1)
            #expect(atEight.data(at: 0, default: Double(0)) == 3.5)

            let atSixteen = StructReader(
                arena: arena, dataStartByte: 16, dataSizeBits: 16, ptrStartByte: 40, ptrCount: 1)
            #expect(atSixteen.data(at: 0, default: UInt16(0)) == 7)
        }
    }

    @Test func boolBitExtraction() {
        makeRegion().withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw), segmentID: 0)
            let r = StructReader(
                arena: arena, dataStartByte: 0, dataSizeBits: 256, ptrStartByte: 32, ptrCount: 2)

            #expect(r.data(at: 144, default: false) == true)
            #expect(r.data(at: 145, default: true) == true)
            #expect(r.data(at: 146, default: false) == false)
            #expect(r.data(at: 5000, default: true) == true)
        }
    }

    @Test func pointerDecodeOnly() {
        makeRegion().withUnsafeBytes { raw in
            let arena = Arena(bytes: RawSpan(_unsafeBytes: raw), segmentID: 0)
            let r = StructReader(
                arena: arena, dataStartByte: 0, dataSizeBits: 256, ptrStartByte: 32, ptrCount: 2)

            let p0 = r.pointer(at: 0)
            #expect(p0.kind == .structure)
            #expect(p0.isNull == false)
            #expect(p0.signedOffsetWords == 1)
            #expect(p0.structDataWords == 2)
            #expect(p0.structPointerWords == 1)

            let p1 = r.pointer(at: 1)
            #expect(p1.kind == .far)
            #expect(p1.farIsDoubleFar == false)
            #expect(p1.farPositionWords == 5)
            #expect(p1.farSegmentID == 3)

            #expect(r.pointer(at: 2).isNull == true)
            #expect(r.pointer(at: -1).isNull == true)
        }
    }
}
