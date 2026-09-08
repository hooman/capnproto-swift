import Foundation

struct CompilerFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

enum Scalar: UInt16 {
    case void, bool, int8, int16, int32, int64, uint8, uint16, uint32, uint64, float32, float64

    var swift: String {
        ["Void", "Bool", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16",
         "UInt32", "UInt64", "Float", "Double"][Int(rawValue)]
    }
    var zero: String { self == .void ? "()" : self == .bool ? "false" : "\(swift)(0)" }
    var encoding: String {
        ["void", "bit", "byte", "twoBytes", "fourBytes", "eightBytes", "byte",
         "twoBytes", "fourBytes", "eightBytes", "fourBytes", "eightBytes"][Int(rawValue)]
    }
}

indirect enum FieldType {
    case scalar(Scalar), text, data, structure(UInt64), list(FieldType), unsupported(UInt16)
    var encoding: String {
        switch self {
        case .scalar(let scalar): return scalar.encoding
        case .structure: return "inlineComposite"
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
}

struct SchemaNode {
    let id: UInt64
    let scope: UInt64
    let kind: UInt16
    let nested: [(id: UInt64, name: String)]
    let generic: Bool
    let group: Bool
    let fields: [SchemaField]
    let discriminantCount: UInt16
    let discriminantOffset: Int
    let dataWords: UInt16
    let pointerCount: UInt16
}

struct RequestedFile {
    let id: UInt64
    let filename: String
}

struct SchemaRequest {
    let nodes: [UInt64: SchemaNode]
    let files: [RequestedFile]
}
