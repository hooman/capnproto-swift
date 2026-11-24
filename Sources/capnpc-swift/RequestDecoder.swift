import CapnpRuntime
import Foundation

// Bootstrap the compiler through CapnpRuntime without requiring a generated schema
// reader to build the generator itself. Offsets are transcribed from upstream
// capnp/schema.capnp.h Reader accessors: data offsets use the scalar's element width,
// pointer offsets count slots, and discriminants describe schema unions, not wire kinds.
enum RequestDecoder {
    static func decode(_ data: Data) throws -> SchemaRequest {
        let arena = Arena(
            framedBytes: data.bytes,
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

    static func string(_ reader: borrowing TextReader) -> String {
        String(copying: reader.utf8)
    }

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
        attachDocs(root.pointerField(at: 3).list(of: .inlineComposite), to: &nodes)
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

    // CodeGeneratorRequest.sourceInfo (pointer 3) is List(Node.SourceInfo): id is data word 0,
    // docComment pointer 0, and members pointer 1, a List(Member { docComment @0 }) in
    // Node.struct.fields order. Docs are cosmetic, so nothing here throws: entries for unknown
    // nodes and repeated IDs are skipped, a missing entry means no doc, and a member list whose
    // length differs from the struct's fields or the enum's enumerants drops that node's member
    // docs (the generator warns if it renders the node). An empty member list means no member
    // docs. Interface method members are not read.
    static func attachDocs(_ list: borrowing ListReader, to nodes: inout [UInt64: SchemaNode]) {
        var seen: Set<UInt64> = []
        for i in 0..<list.count {
            let info = list.structure(at: i)
            let id = info.data(at: 0, default: UInt64(0))
            guard seen.insert(id).inserted, var node = nodes[id] else { continue }
            node.doc = doc(info.pointerField(at: 0))
            let members = info.pointerField(at: 1).list(of: .inlineComposite)
            let expected = node.kind == 1 ? node.fields.count : node.enumerants.count
            if node.kind == 1 || node.kind == 2, members.count != 0 {
                if members.count == expected {
                    for j in 0..<members.count {
                        let text = doc(members.structure(at: j).pointerField(at: 0))
                        if node.kind == 1 {
                            node.fields[j].doc = text
                        } else {
                            node.enumerants[j].doc = text
                        }
                    }
                } else {
                    node.memberDocMismatch = (members.count, expected)
                }
            }
            nodes[id] = node
        }
    }

    // Read as bytes, not text(): text() validates UTF-8 and records a sticky arena error,
    // which would fail the whole request over a comment. Invalid UTF-8 becomes U+FFFD.
    static func doc(_ pointer: borrowing PointerReader) -> String? {
        let reader = pointer.data()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(reader.count)
        for i in 0..<reader.count { bytes.append(reader[i]) }
        if bytes.last == 0 { bytes.removeLast() }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    // Annotations (Node pointer 2, Field pointer 1) are never read: they carry no wire
    // meaning, and rejecting them failed any request that imported /capnp/c++.capnp (D-17).
    static func node(_ reader: borrowing StructReader) throws -> SchemaNode {
        let kind = reader.data(at: 6, default: UInt16(0))
        var nested: [(UInt64, String)] = []
        let children = reader.pointerField(at: 1).list(of: .inlineComposite)
        for i in 0..<children.count {
            let child = children.structure(at: i)
            nested.append(
                (
                    child.data(at: 0, default: UInt64(0)),
                    string(child.pointerField(at: 0).text())
                ))
        }
        var fields: [SchemaField] = []
        var enumerants: [SchemaEnumerant] = []
        var constant: SchemaConstant?
        if kind == 1 {
            let list = reader.pointerField(at: 3).list(of: .inlineComposite)
            for i in 0..<list.count { fields.append(try field(list.structure(at: i))) }
        } else if kind == 2 {
            // Node.enum.enumerants (pointer 3) is in ordinal order; Enumerant.name is pointer 0.
            let list = reader.pointerField(at: 3).list(of: .inlineComposite)
            for i in 0..<list.count {
                enumerants.append(
                    SchemaEnumerant(name: string(list.structure(at: i).pointerField(at: 0).text())))
            }
        } else if kind == 4 {
            // Node.const: type is pointer 3 and value pointer 4. Value's discriminant is data
            // UInt16 0; an enum value's ordinal is data UInt16 1.
            let type = try type(reader.pointerField(at: 3).structure(), depth: 0)
            let value = reader.pointerField(at: 4).structure()
            let valueKind = value.data(at: 0, default: UInt16(0))
            var expression = ""
            if case .scalar(let scalar) = type, valueKind == scalar.rawValue {
                expression = scalarDefault(value, scalar)
            }
            constant = SchemaConstant(
                type: type, valueKind: valueKind, expression: expression,
                ordinal: value.data(at: 1, default: UInt16(0)))
        }
        var node = SchemaNode(
            id: reader.data(at: 0, default: UInt64(0)),
            scope: reader.data(at: 2, default: UInt64(0)), kind: kind, nested: nested,
            generic: reader.data(at: 288, default: false),
            group: kind == 1 && reader.data(at: 224, default: false), fields: fields,
            discriminantCount: kind == 1 ? reader.data(at: 15, default: UInt16(0)) : 0,
            discriminantOffset: kind == 1 ? Int(reader.data(at: 8, default: UInt32(0))) : 0,
            dataWords: kind == 1 ? reader.data(at: 7, default: UInt16(0)) : 0,
            pointerCount: kind == 1 ? reader.data(at: 12, default: UInt16(0)) : 0)
        node.enumerants = enumerants
        node.constant = constant
        return node
    }

    static func field(_ reader: borrowing StructReader) throws -> SchemaField {
        let name = string(reader.pointerField(at: 0).text())
        let discriminant = reader.data(at: 1, default: UInt16.max)
        let kind = reader.data(at: 4, default: UInt16(0))
        if kind == 1 {
            let id = reader.data(at: 2, default: UInt64(0))
            return SchemaField(
                name: name, offset: 0, type: .structure(id),
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
            guard value.data(at: 0, default: UInt16(0)) == 12 else {
                throw CompilerFailure("default type mismatch for \(name)")
            }
            unsupportedDefault = value.pointerField(at: 0).text().count != 0
            expression = ""
        case .data:
            guard value.data(at: 0, default: UInt16(0)) == 13 else {
                throw CompilerFailure("default type mismatch for \(name)")
            }
            unsupportedDefault = value.pointerField(at: 0).data().count != 0
            expression = ""
        case .list(let element):
            guard value.data(at: 0, default: UInt16(0)) == 14 else {
                throw CompilerFailure("default type mismatch for \(name)")
            }
            // An unsupported element type has no trustworthy wire size here (an enum list is
            // two-byte, not pointer), so any non-null default is diagnosed unopened.
            if case .unsupported = element {
                unsupportedDefault = !value.pointerField(at: 0).isNull
            } else {
                let size = elementSize(element)
                unsupportedDefault = value.pointerField(at: 0).list(of: size).count != 0
            }
            expression = ""
        case .enumeration:
            // Value.enum (discriminant 15) holds the default ordinal at data UInt16 1.
            guard value.data(at: 0, default: UInt16(0)) == 15 else {
                throw CompilerFailure("default type mismatch for \(name)")
            }
            expression = "UInt16(\(value.data(at: 1, default: UInt16(0))))"
        case .structure:
            guard value.data(at: 0, default: UInt16(0)) == 16 else {
                throw CompilerFailure("default type mismatch for \(name)")
            }
            unsupportedDefault = !value.pointerField(at: 0).isNull
            expression = ""
        case .unsupported:
            unsupportedDefault = !value.pointerField(at: 0).isNull
            expression = ""
        }
        return SchemaField(
            name: name, offset: Int(reader.data(at: 1, default: UInt32(0))),
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
        case 15: return .enumeration(reader.data(at: 1, default: UInt64(0)))
        case 16: return .structure(reader.data(at: 1, default: UInt64(0)))
        default: return .unsupported(kind)
        }
    }

    static func elementSize(_ type: FieldType) -> CapnpRuntime.ElementSize {
        switch type {
        case .scalar(let scalar):
            switch scalar {
            case .void: return .void
            case .bool: return .bit
            case .int8, .uint8: return .byte
            case .int16, .uint16: return .twoBytes
            case .int32, .uint32, .float32: return .fourBytes
            case .int64, .uint64, .float64: return .eightBytes
            }
        case .structure: return .inlineComposite
        case .enumeration: return .twoBytes
        default: return .pointer
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
