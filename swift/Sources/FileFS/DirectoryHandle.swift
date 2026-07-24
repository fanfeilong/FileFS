import Foundation

public final class DirectoryHandle {
    var blockIndex: UInt32
    var block: [UInt8]
    var searchIndex: Int
    var stopBlockIndex: UInt32
    var offset: UInt16

    init(
        blockIndex: UInt32,
        block: [UInt8],
        searchIndex: Int,
        stopBlockIndex: UInt32,
        offset: UInt16
    ) {
        self.blockIndex = blockIndex
        self.block = block
        self.searchIndex = searchIndex
        self.stopBlockIndex = stopBlockIndex
        self.offset = offset
    }
}
