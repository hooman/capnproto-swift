// Owned intermediate representation separates borrowed request decoding from rendering
// and file I/O. References remain node IDs rather than expanded trees, so recursive
// schemas terminate and imported declarations can be qualified without re-emission.

import Foundation

struct CompilerFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

// Raw values match schema.capnp Type discriminants; the lookup tables share that order.
enum Scalar: UInt16 {
    case void, bool, int8, int16, int32, int64, uint8, uint16, uint32, uint64, float32, float64

    var swift: String {
        [
            "Void", "Bool", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16",
            "UInt32", "UInt64", "Float", "Double",
        ][Int(rawValue)]
    }
    var zero: String { self == .void ? "()" : self == .bool ? "false" : "\(swift)(0)" }
    var encoding: String {
        [
            "void", "bit", "byte", "twoBytes", "fourBytes", "eightBytes", "byte",
            "twoBytes", "fourBytes", "eightBytes", "fourBytes", "eightBytes",
        ][Int(rawValue)]
    }
}

indirect enum FieldType {
    case scalar(Scalar)
    case text, data
    case structure(UInt64)
    case enumeration(UInt64)
    case list(FieldType)
    case unsupported(UInt16)
    var encoding: String {
        switch self {
        case .scalar(let scalar): return scalar.encoding
        case .structure: return "inlineComposite"
        case .enumeration: return "twoBytes"
        default: return "pointer"
        }
    }
}

struct SchemaField {
    let name: String
    let offset: Int
    let type: FieldType
    let defaultExpression: String
    let discriminant: UInt16
    let groupID: UInt64?
    let unsupportedDefault: Bool
    var doc: String? = nil
}

struct SchemaEnumerant {
    let name: String
    var doc: String? = nil
}

// Const nodes (kind 4). Only the value's discriminant and its scalar expression or enum
// ordinal are kept; the generator diagnoses deferred types and mismatches at render time, so
// an imported file that is not generated may hold any constant.
struct SchemaConstant {
    let type: FieldType
    let valueKind: UInt16
    let expression: String
    let ordinal: UInt16
}

struct SchemaNode {
    let id: UInt64
    let scope: UInt64
    let kind: UInt16
    let nested: [(id: UInt64, name: String)]
    let generic: Bool
    let group: Bool
    var fields: [SchemaField]
    let discriminantCount: UInt16
    let discriminantOffset: Int
    let dataWords: UInt16
    let pointerCount: UInt16
    // Enum nodes (kind 2) only, in ordinal order: an enumerant's ordinal is its index.
    var enumerants: [SchemaEnumerant] = []
    var constant: SchemaConstant? = nil
    var doc: String? = nil
    // Set when sourceInfo lists a different number of members than the struct has fields or
    // the enum has enumerants; member docs are dropped and the generator warns if it renders
    // this node.
    var memberDocMismatch: (members: Int, expected: Int)? = nil
}

struct RequestedFile {
    let id: UInt64
    let filename: String
}

struct SchemaRequest {
    let nodes: [UInt64: SchemaNode]
    let files: [RequestedFile]
}
