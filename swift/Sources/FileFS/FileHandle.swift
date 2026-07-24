import Foundation

public final class FileHandle {
    let mode: OpenMode
    var dirBlockIndex: UInt32
    var dirRecordOffset: Int
    var fileStartBlockIndex: UInt32
    var fileStopBlockIndex: UInt32
    var fileOffset: UInt16
    var posBlockIndex: UInt32
    var posOffset: UInt16
    var pos: UInt64

    init(
        mode: OpenMode,
        dirBlockIndex: UInt32,
        dirRecordOffset: Int,
        fileStartBlockIndex: UInt32,
        fileStopBlockIndex: UInt32,
        fileOffset: UInt16,
        posBlockIndex: UInt32,
        posOffset: UInt16,
        pos: UInt64
    ) {
        self.mode = mode
        self.dirBlockIndex = dirBlockIndex
        self.dirRecordOffset = dirRecordOffset
        self.fileStartBlockIndex = fileStartBlockIndex
        self.fileStopBlockIndex = fileStopBlockIndex
        self.fileOffset = fileOffset
        self.posBlockIndex = posBlockIndex
        self.posOffset = posOffset
        self.pos = pos
    }
}
