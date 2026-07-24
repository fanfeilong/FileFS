import Foundation

enum OpenMode: UInt8 {
    case read = 0
    case write = 1
    case append = 2
    case readWrite = 3
    case writeRead = 4
    case appendRead = 5

    var canRead: Bool {
        switch self {
        case .read, .readWrite, .writeRead, .appendRead:
            return true
        case .write, .append:
            return false
        }
    }

    var canWrite: Bool {
        self != .read
    }
}

func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

func writeUInt32LE(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
    bytes[offset] = UInt8(value & 0xFF)
    bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
    bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
}

func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

func writeUInt16LE(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
    bytes[offset] = UInt8(value & 0xFF)
    bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
}

func fixedCString(_ bytes: ArraySlice<UInt8>) -> String {
    let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
    return String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self)
}

func fixedCString(_ bytes: [UInt8]) -> String {
    fixedCString(bytes[...])
}

func writeFixedName(_ name: String, into bytes: inout [UInt8], at offset: Int, size: Int) {
    for index in offset..<(offset + size) {
        bytes[index] = 0
    }
    let utf8 = Array(name.utf8.prefix(size))
    bytes.replaceSubrange(offset..<(offset + utf8.count), with: utf8)
}

func ensureUTF8NameFits(_ name: String, limit: Int) throws {
    if name.utf8.count > limit {
        throw FileFSError.nameTooLong(name)
    }
}
