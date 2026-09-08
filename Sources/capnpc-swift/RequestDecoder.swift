import Foundation
import CapnpRuntime

// Bootstrap the compiler through CapnpRuntime without requiring a generated schema
// reader to build the generator itself. Offsets are transcribed from upstream
// capnp/schema.capnp.h Reader accessors: data offsets use the scalar's element width,
// pointer offsets count slots, and discriminants describe schema unions, not wire kinds.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum RequestDecoder {
    static func decode(_ data: Data) throws -> SchemaRequest {
        try data.withUnsafeBytes { raw in
            let arena = Arena(framedBytes: RawSpan(_unsafeBytes: raw),
                              options: ReaderOptions(traversalLimitWords: 32 * 1024 * 1024))
            guard arena.error == .none, arena.consumedByteCount == data.count else {
                throw CompilerFailure("expected exactly one complete unpacked CodeGeneratorRequest")
            }
            // Capture throwing decode inside the borrowing scope. Check the sticky runtime
            // error before accepting an IR: malformed reads may have yielded valid-looking defaults.
            let result = arena.withRoot { root in Result { try request(root) } }
            guard arena.error == .none else {
                throw CompilerFailure("invalid CodeGeneratorRequest: \(arena.error)")
            }
            return try result.get()
        }
    }

    static func string(_ reader: borrowing TextReader) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(reader.count)
        for i in 0..<reader.count { bytes.append(reader[i]) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // TODO(codegen-docs): decode CodeGeneratorRequest.sourceInfo and carry declaration
    // and member documentation through SchemaRequest into generated Swift doc comments.
    static func request(_ root: borrowing StructReader) throws -> SchemaRequest {
        var nodes: [UInt64: SchemaNode] = [:]
        let list = root.pointerField(at: 0).list(of: .inlineComposite)
        for i in 0..<list.count {
            let node = try node(list.structure(at: i))
            guard node.id != 0, nodes[node.id] == nil else {
                throw CompilerFailure("duplicate or zero schema node ID")
            }
            nodes[node.id] = node
        }
        var files: [RequestedFile] = []
        let requested = root.pointerField(at: 1).list(of: .inlineComposite)
        var ids: Set<UInt64> = []
        for i in 0..<requested.count {
            let file = requested.structure(at: i)
            let id = file.data(at: 0, default: UInt64(0))
            guard ids.insert(id).inserted, nodes[id]?.kind == 0 else {
                throw CompilerFailure("requested file is missing, duplicated, or not a file node")
            }
            files.append(RequestedFile(id: id, filename: string(file.pointerField(at: 0).text())))
        }
        guard !files.isEmpty else { throw CompilerFailure("request has no requested files") }
        return SchemaRequest(nodes: nodes, files: files)
    }

    static func node(_ reader: borrowing StructReader) throws -> SchemaNode {
        guard reader.pointerField(at: 2).list(of: .inlineComposite).count == 0 else {
            throw CompilerFailure("annotations are outside readers-only v1")
        }
        let kind = reader.data(at: 6, default: UInt16(0))
        var nested: [(UInt64, String)] = []
        let children = reader.pointerField(at: 1).list(of: .inlineComposite)
        for i in 0..<children.count {
            let child = children.structure(at: i)
            nested.append((child.data(at: 0, default: UInt64(0)),
                           string(child.pointerField(at: 0).text())))
        }
        var fields: [SchemaField] = []
        if kind == 1 {
            let list = reader.pointerField(at: 3).list(of: .inlineComposite)
            for i in 0..<list.count { fields.append(try field(list.structure(at: i))) }
        }
        return SchemaNode(
            id: reader.data(at: 0, default: UInt64(0)),
            scope: reader.data(at: 2, default: UInt64(0)), kind: kind, nested: nested,
            generic: reader.data(at: 288, default: false),
            group: kind == 1 && reader.data(at: 224, default: false), fields: fields,
            discriminantCount: kind == 1 ? reader.data(at: 15, default: UInt16(0)) : 0,
            discriminantOffset: kind == 1 ? Int(reader.data(at: 8, default: UInt32(0))) : 0,
            dataWords: kind == 1 ? reader.data(at: 7, default: UInt16(0)) : 0,
            pointerCount: kind == 1 ? reader.data(at: 12, default: UInt16(0)) : 0)
    }

    static func field(_ reader: borrowing StructReader) throws -> SchemaField {
        guard reader.pointerField(at: 1).list(of: .inlineComposite).count == 0 else {
            throw CompilerFailure("field annotations are outside readers-only v1")
        }
        let name = string(reader.pointerField(at: 0).text())
        let discriminant = reader.data(at: 1, default: UInt16.max)
        let kind = reader.data(at: 4, default: UInt16(0))
        if kind == 1 {
            let id = reader.data(at: 2, default: UInt64(0))
            return SchemaField(name: name, offset: 0, type: .structure(id),
                               defaultExpression: "", discriminant: discriminant, groupID: id,
                               unsupportedDefault: false)
        }
        guard kind == 0 else { throw CompilerFailure("unknown field kind \(kind) for \(name)") }
        let type = try type(reader.pointerField(at: 2).structure(), depth: 0)
        let value = reader.pointerField(at: 3).structure()
        var unsupportedDefault = false
        let expression: String
        switch type {
        case .scalar(let scalar):
            guard value.data(at: 0, default: UInt16(0)) == scalar.rawValue else {
                throw CompilerFailure("default type mismatch for \(name)")
            }
            expression = scalarDefault(value, scalar)
        case .text:
            unsupportedDefault = value.pointerField(at: 0).text().count != 0
            expression = ""
        case .data:
            unsupportedDefault = value.pointerField(at: 0).data().count != 0
            expression = ""
        case .list(let element):
            let size = CapnpRuntime.ElementSize(rawValue: encodingCode(element))!
            unsupportedDefault = value.pointerField(at: 0).list(of: size).count != 0
            expression = ""
        default:
            unsupportedDefault = !value.pointerField(at: 0).isNull
            expression = ""
        }
        return SchemaField(name: name, offset: Int(reader.data(at: 1, default: UInt32(0))),
                           type: type, defaultExpression: expression, discriminant: discriminant,
                           groupID: nil, unsupportedDefault: unsupportedDefault)
    }

    static func type(_ reader: borrowing StructReader, depth: Int) throws -> FieldType {
        guard depth < 64 else { throw CompilerFailure("schema type nesting exceeds 64") }
        let kind = reader.data(at: 0, default: UInt16(0))
        if let scalar = Scalar(rawValue: kind) { return .scalar(scalar) }
        switch kind {
        case 12: return .text
        case 13: return .data
        case 14: return .list(try type(reader.pointerField(at: 0).structure(), depth: depth + 1))
        case 16: return .structure(reader.data(at: 1, default: UInt64(0)))
        default: return .unsupported(kind)
        }
    }

    static func encodingCode(_ type: FieldType) -> UInt8 {
        switch type {
        case .scalar(let scalar):
            return [0, 1, 2, 3, 4, 5, 2, 3, 4, 5, 4, 5][Int(scalar.rawValue)]
        case .structure: return 7
        default: return 6
        }
    }

    static func scalarDefault(_ reader: borrowing StructReader, _ scalar: Scalar) -> String {
        switch scalar {
        case .void: return "()"
        case .bool: return reader.data(at: 16, default: false) ? "true" : "false"
        case .int8: return "Int8(\(reader.data(at: 2, default: Int8(0))))"
        case .int16: return "Int16(\(reader.data(at: 1, default: Int16(0))))"
        case .int32: return "Int32(\(reader.data(at: 1, default: Int32(0))))"
        case .int64: return "Int64(\(reader.data(at: 1, default: Int64(0))))"
        case .uint8: return "UInt8(\(reader.data(at: 2, default: UInt8(0))))"
        case .uint16: return "UInt16(\(reader.data(at: 1, default: UInt16(0))))"
        case .uint32: return "UInt32(\(reader.data(at: 1, default: UInt32(0))))"
        case .uint64: return "UInt64(\(reader.data(at: 1, default: UInt64(0))))"
        case .float32:
            return "Float(bitPattern: \(reader.data(at: 1, default: UInt32(0))))"
        case .float64:
            return "Double(bitPattern: \(reader.data(at: 1, default: UInt64(0))))"
        }
    }
}
