// ProtobufWriter.swift - Minimal protobuf wire format writer for Mihon backups.
//
// Encodes basic protobuf wire types (varint, 32-bit fixed, length-delimited).
// Standard proto3 convention: default/empty scalar values are omitted.

import Foundation

struct ProtobufWriter {
    var bytes = Data()

    init(capacity: Int = 1024) {
        bytes.reserveCapacity(capacity)
    }

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    private mutating func key(_ field: Int, _ wire: Int) {
        varint(UInt64(field << 3 | wire))
    }

    mutating func int(_ field: Int, _ value: Int64) {
        key(field, 0)
        varint(UInt64(bitPattern: value))
    }

    mutating func int(_ field: Int, _ value: Int) {
        int(field, Int64(value))
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        int(field, value ? 1 : 0)
    }

    mutating func float(_ field: Int, _ value: Float) {
        key(field, 5)
        var bits = value.bitPattern.littleEndian
        bytes.append(Data(bytes: &bits, count: 4))
    }

    mutating func string(_ field: Int, _ value: String) {
        guard !value.isEmpty else { return }
        message(field, Data(value.utf8))
    }

    mutating func message(_ field: Int, _ data: Data) {
        key(field, 2)
        varint(UInt64(data.count))
        bytes.append(data)
    }

    mutating func message(_ field: Int, _ build: (inout ProtobufWriter) throws -> Void) rethrows {
        var inner = ProtobufWriter()
        try build(&inner)
        message(field, inner.bytes)
    }
}
