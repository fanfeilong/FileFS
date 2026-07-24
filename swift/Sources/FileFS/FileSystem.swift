import Foundation

private let fileFSBlockSize = 512
private let fileFSRecordSize = 25
private let fileFSBlockHead = 12
private let fileFSBlockItemMaxCount = 20
private let fileFSBlockNameMaxSize = 14
private let fileFSBlockStartBlockIndexOffset = 27
private let fileFSBlockStopBlockIndexOffset = 31
private let fileFSBlockOffsetOffset = 35
private let fileFSMagic: [UInt8] = [0x78, 0x11, 0x45, 0x14]

private struct TransactionState {
    var state: UInt8 = 0
    var pwd: String = ""
    var pwdBlockIndex: UInt32 = 0
    var totalBlockSize: UInt32 = 0
    var unusedBlockHead: UInt32 = 0
    var newTotalBlockSize: UInt32 = 0
    var newUnusedBlockHead: UInt32 = 0
    var modifiedBlocks: [UInt32: [UInt8]] = [:]
}

private struct ResolvedName {
    let parentBlockIndex: UInt32
    let name: String
    let hadTrailingSlash: Bool
}

private struct ResolvedDirectory {
    let blockIndex: UInt32
    let absolutePath: String
}

private struct DirectoryEntryInfo {
    let containerBlockIndex: UInt32
    let recordOffset: Int
    let state: UInt8
    let name: String
    let startBlockIndex: UInt32
    let stopBlockIndex: UInt32
    let fileOffset: UInt16
    let rawRecord: [UInt8]

    var isFile: Bool {
        state & 0x01 == 1
    }
}

public final class FileSystem {
    public static let blockSize = fileFSBlockSize

    private var imagePath: String = ""
    private var hostFile: Foundation.FileHandle?
    private var journalPath: String = ""
    private var transaction = TransactionState()
    private var pwd: String = ""
    private var pwdBlockIndex: UInt32 = 0

    public init() {}

    public var isMounted: Bool {
        hostFile != nil
    }

    public static func mkfs(at path: String) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: path) {
            try manager.removeItem(atPath: path)
        }
        guard manager.createFile(atPath: path, contents: nil) else {
            throw FileFSError.ioError("Unable to create image at \(path)")
        }

        let url = URL(fileURLWithPath: path)
        let handle: Foundation.FileHandle
        do {
            handle = try Foundation.FileHandle(forUpdating: url)
        } catch {
            throw FileFSError.ioError("Unable to open image for writing: \(error)")
        }

        defer {
            try? handle.close()
        }

        var block0 = [UInt8](repeating: 0, count: fileFSBlockSize)
        block0.replaceSubrange(0..<4, with: fileFSMagic)
        writeUInt32LE(2, into: &block0, at: 4)

        var block1 = [UInt8](repeating: 0, count: fileFSBlockSize)
        var offset = fileFSBlockHead

        block1[offset] = 0
        offset += 1
        writeFixedName(".", into: &block1, at: offset, size: fileFSBlockNameMaxSize)
        offset += fileFSBlockNameMaxSize
        writeUInt32LE(1, into: &block1, at: offset)
        offset += 4
        writeUInt32LE(1, into: &block1, at: offset)
        offset += 4
        writeUInt16LE(UInt16(fileFSBlockHead + fileFSRecordSize + fileFSRecordSize), into: &block1, at: offset)
        offset += 2

        block1[offset] = 0
        offset += 1
        writeFixedName("..", into: &block1, at: offset, size: fileFSBlockNameMaxSize)

        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data(block0))
            try handle.write(contentsOf: Data(block1))
            try handle.synchronize()
        } catch {
            throw FileFSError.ioError("Unable to initialize image: \(error)")
        }

        let journalPath = path + "-j"
        if manager.fileExists(atPath: journalPath) {
            try? manager.removeItem(atPath: journalPath)
        }
    }

    public func mount(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        let handle: Foundation.FileHandle
        do {
            handle = try Foundation.FileHandle(forUpdating: url)
        } catch {
            throw FileFSError.ioError("Unable to mount \(path): \(error)")
        }

        let header: [UInt8]
        do {
            header = try readExact(from: handle, at: 0, count: fileFSBlockSize)
        } catch {
            try? handle.close()
            throw error
        }

        guard Array(header[0..<4]) == fileFSMagic else {
            try? handle.close()
            throw FileFSError.invalidFormat("Bad magic number")
        }

        let totalBlocks = readUInt32LE(header, at: 4)
        guard totalBlocks >= 2 else {
            try? handle.close()
            throw FileFSError.invalidFormat("Block count is too small")
        }

        let rootBlock: [UInt8]
        do {
            rootBlock = try readExact(from: handle, at: UInt64(fileFSBlockSize), count: fileFSBlockSize)
        } catch {
            try? handle.close()
            throw error
        }

        guard rootBlock[fileFSBlockHead] == 0 else {
            try? handle.close()
            throw FileFSError.invalidFormat("Root '.' entry has invalid state")
        }
        let rootDot = fixedCString(rootBlock[(fileFSBlockHead + 1)..<(fileFSBlockHead + 1 + fileFSBlockNameMaxSize)])
        guard rootDot == "." else {
            try? handle.close()
            throw FileFSError.invalidFormat("Root '.' entry is missing")
        }

        let dotDotOffset = fileFSBlockHead + fileFSRecordSize
        guard rootBlock[dotDotOffset] == 0 else {
            try? handle.close()
            throw FileFSError.invalidFormat("Root '..' entry has invalid state")
        }
        let rootDotDot = fixedCString(rootBlock[(dotDotOffset + 1)..<(dotDotOffset + 1 + fileFSBlockNameMaxSize)])
        guard rootDotDot == ".." else {
            try? handle.close()
            throw FileFSError.invalidFormat("Root '..' entry is missing")
        }

        umount()
        hostFile = handle
        imagePath = path
        journalPath = path + "-j"
        pwd = "/"
        pwdBlockIndex = 1
        transaction = TransactionState()
        try applyPendingJournalIfNeeded()
    }

    public func umount() {
        rollback()
        if let hostFile {
            try? hostFile.close()
        }
        hostFile = nil
        imagePath = ""
        if !journalPath.isEmpty {
            try? FileManager.default.removeItem(atPath: journalPath)
        }
        journalPath = ""
        pwd = ""
        pwdBlockIndex = 0
    }

    public func open(_ path: String, mode: String) throws -> FileHandle {
        try requireMounted()

        let openMode: OpenMode
        switch mode {
        case "r":
            openMode = .read
        case "w":
            openMode = .write
        case "a":
            openMode = .append
        case "r+":
            openMode = .readWrite
        case "w+":
            openMode = .writeRead
        case "a+":
            openMode = .appendRead
        default:
            throw FileFSError.invalidMode(mode)
        }

        let resolved = try resolveParentAndName(path)
        if resolved.name == "." || resolved.name == ".." {
            throw FileFSError.invalidPath(path)
        }

        switch openMode {
        case .read, .readWrite:
            guard let entry = try findEntry(inDirectory: resolved.parentBlockIndex, named: resolved.name) else {
                throw FileFSError.notFound(path)
            }
            guard entry.isFile else {
                throw FileFSError.notAFile(path)
            }
            return FileHandle(
                mode: openMode,
                dirBlockIndex: entry.containerBlockIndex,
                dirRecordOffset: entry.recordOffset,
                fileStartBlockIndex: entry.startBlockIndex,
                fileStopBlockIndex: entry.stopBlockIndex,
                fileOffset: entry.fileOffset,
                posBlockIndex: entry.startBlockIndex,
                posOffset: entry.startBlockIndex == 0 ? 0 : UInt16(fileFSBlockHead),
                pos: 0
            )
        case .write, .writeRead:
            return try withAutoTransaction {
                if let entry = try findEntry(inDirectory: resolved.parentBlockIndex, named: resolved.name) {
                    guard entry.isFile else {
                        throw FileFSError.notAFile(path)
                    }
                    try clearFileEntry(entry)
                    return FileHandle(
                        mode: openMode,
                        dirBlockIndex: entry.containerBlockIndex,
                        dirRecordOffset: entry.recordOffset,
                        fileStartBlockIndex: 0,
                        fileStopBlockIndex: 0,
                        fileOffset: 0,
                        posBlockIndex: 0,
                        posOffset: 0,
                        pos: 0
                    )
                }

                let created = try appendEntry(
                    toDirectory: resolved.parentBlockIndex,
                    state: 1,
                    name: resolved.name,
                    startBlockIndex: 0,
                    stopBlockIndex: 0,
                    fileOffset: 0
                )
                return FileHandle(
                    mode: openMode,
                    dirBlockIndex: created.containerBlockIndex,
                    dirRecordOffset: created.recordOffset,
                    fileStartBlockIndex: 0,
                    fileStopBlockIndex: 0,
                    fileOffset: 0,
                    posBlockIndex: 0,
                    posOffset: 0,
                    pos: 0
                )
            }
        case .append, .appendRead:
            return try withAutoTransaction {
                if let entry = try findEntry(inDirectory: resolved.parentBlockIndex, named: resolved.name) {
                    guard entry.isFile else {
                        throw FileFSError.notAFile(path)
                    }
                    return FileHandle(
                        mode: openMode,
                        dirBlockIndex: entry.containerBlockIndex,
                        dirRecordOffset: entry.recordOffset,
                        fileStartBlockIndex: entry.startBlockIndex,
                        fileStopBlockIndex: entry.stopBlockIndex,
                        fileOffset: entry.fileOffset,
                        posBlockIndex: entry.stopBlockIndex,
                        posOffset: entry.startBlockIndex == 0 ? 0 : entry.fileOffset,
                        pos: try fileLength(
                            startBlockIndex: entry.startBlockIndex,
                            stopBlockIndex: entry.stopBlockIndex,
                            fileOffset: entry.fileOffset
                        )
                    )
                }

                let created = try appendEntry(
                    toDirectory: resolved.parentBlockIndex,
                    state: 1,
                    name: resolved.name,
                    startBlockIndex: 0,
                    stopBlockIndex: 0,
                    fileOffset: 0
                )
                return FileHandle(
                    mode: openMode,
                    dirBlockIndex: created.containerBlockIndex,
                    dirRecordOffset: created.recordOffset,
                    fileStartBlockIndex: 0,
                    fileStopBlockIndex: 0,
                    fileOffset: 0,
                    posBlockIndex: 0,
                    posOffset: 0,
                    pos: 0
                )
            }
        }
    }

    public func read(_ file: FileHandle, into buffer: inout [UInt8]) throws -> Int {
        try requireMounted()
        guard file.mode.canRead else {
            throw FileFSError.invalidMode("File is not open for reading")
        }
        guard file.posBlockIndex != 0 else {
            return 0
        }
        if buffer.isEmpty {
            return 0
        }

        var copied = 0
        var blockIndex = file.posBlockIndex
        while copied < buffer.count {
            let block = try readBlock(blockIndex)
            let nextIndex = readUInt32LE(block, at: 4)

            if file.posOffset == fileFSBlockSize {
                file.posOffset = UInt16(fileFSBlockHead)
            }

            let available: Int
            if blockIndex == file.fileStopBlockIndex {
                available = Int(file.fileOffset) - Int(file.posOffset)
            } else {
                available = fileFSBlockSize - Int(file.posOffset)
            }
            if available <= 0 {
                return copied
            }

            let toCopy = min(available, buffer.count - copied)
            let start = Int(file.posOffset)
            let end = start + toCopy
            buffer.replaceSubrange(copied..<(copied + toCopy), with: block[start..<end])
            copied += toCopy
            file.posOffset += UInt16(toCopy)
            file.pos += UInt64(toCopy)

            if copied == buffer.count || blockIndex == file.fileStopBlockIndex {
                file.posBlockIndex = blockIndex
                return copied
            }

            if nextIndex == 0 {
                file.posBlockIndex = blockIndex
                return copied
            }
            blockIndex = nextIndex
            file.posBlockIndex = blockIndex
        }

        return copied
    }

    public func write(_ file: FileHandle, from buffer: [UInt8]) throws -> Int {
        try requireMounted()
        guard file.mode.canWrite else {
            throw FileFSError.invalidMode("File is not open for writing")
        }
        if buffer.isEmpty {
            return 0
        }

        return try withAutoTransaction {
            var written = 0

            if file.posBlockIndex == 0 {
                let newBlockIndex = try allocateBlock()
                let newBlock = [UInt8](repeating: 0, count: fileFSBlockSize)
                try writeBlock(newBlockIndex, newBlock)

                var dirBlock = try readBlock(file.dirBlockIndex)
                writeUInt32LE(newBlockIndex, into: &dirBlock, at: file.dirRecordOffset + 15)
                writeUInt32LE(newBlockIndex, into: &dirBlock, at: file.dirRecordOffset + 19)
                writeUInt16LE(UInt16(fileFSBlockHead), into: &dirBlock, at: file.dirRecordOffset + 23)
                try writeBlock(file.dirBlockIndex, dirBlock)

                file.fileStartBlockIndex = newBlockIndex
                file.fileStopBlockIndex = newBlockIndex
                file.fileOffset = 0
                file.posBlockIndex = newBlockIndex
                file.posOffset = UInt16(fileFSBlockHead)
                file.pos = 0
                _ = newBlock
            }

            var currentIndex = file.posBlockIndex
            var currentBlock = try readBlock(currentIndex)

            while written < buffer.count {
                if file.posOffset == fileFSBlockSize {
                    let nextIndex = readUInt32LE(currentBlock, at: 4)
                    if nextIndex == 0 {
                        let newBlockIndex = try allocateBlock()
                        var newBlock = [UInt8](repeating: 0, count: fileFSBlockSize)
                        writeUInt32LE(currentIndex, into: &newBlock, at: 8)
                        writeUInt32LE(newBlockIndex, into: &currentBlock, at: 4)
                        try writeBlock(currentIndex, currentBlock)

                        currentIndex = newBlockIndex
                        currentBlock = newBlock
                    } else {
                        currentIndex = nextIndex
                        currentBlock = try readBlock(currentIndex)
                    }
                    file.posBlockIndex = currentIndex
                    file.posOffset = UInt16(fileFSBlockHead)
                }

                let available = fileFSBlockSize - Int(file.posOffset)
                let count = min(available, buffer.count - written)
                let start = Int(file.posOffset)
                let end = start + count
                currentBlock.replaceSubrange(start..<end, with: buffer[written..<(written + count)])
                try writeBlock(currentIndex, currentBlock)

                written += count
                file.posOffset += UInt16(count)
                file.pos += UInt64(count)
                file.posBlockIndex = currentIndex

                let extendsEOF = currentIndex > file.fileStopBlockIndex
                    || (currentIndex == file.fileStopBlockIndex && file.posOffset > file.fileOffset)
                    || file.fileStartBlockIndex == 0

                if extendsEOF {
                    file.fileStartBlockIndex = file.fileStartBlockIndex == 0 ? currentIndex : file.fileStartBlockIndex
                    file.fileStopBlockIndex = currentIndex
                    file.fileOffset = file.posOffset

                    var dirBlock = try readBlock(file.dirBlockIndex)
                    writeUInt32LE(file.fileStartBlockIndex, into: &dirBlock, at: file.dirRecordOffset + 15)
                    writeUInt32LE(file.fileStopBlockIndex, into: &dirBlock, at: file.dirRecordOffset + 19)
                    writeUInt16LE(file.fileOffset, into: &dirBlock, at: file.dirRecordOffset + 23)
                    try writeBlock(file.dirBlockIndex, dirBlock)
                }
            }

            return written
        }
    }

    public func close(_ file: FileHandle) {
        _ = file
    }

    public func seek(_ file: FileHandle, offset: Int64, whence: SeekWhence) throws -> Bool {
        try requireMounted()
        guard file.posBlockIndex != 0 else {
            return false
        }

        let target: Int64
        switch whence {
        case .set:
            target = offset
        case .current:
            target = Int64(file.pos) + offset
        case .end:
            target = Int64(try fileLength(
                startBlockIndex: file.fileStartBlockIndex,
                stopBlockIndex: file.fileStopBlockIndex,
                fileOffset: file.fileOffset
            )) + offset
        }

        if target < 0 {
            return false
        }

        let length = try fileLength(
            startBlockIndex: file.fileStartBlockIndex,
            stopBlockIndex: file.fileStopBlockIndex,
            fileOffset: file.fileOffset
        )
        let bounded = UInt64(min(Int64(length), target))
        let positioned = try locatePosition(
            startBlockIndex: file.fileStartBlockIndex,
            stopBlockIndex: file.fileStopBlockIndex,
            fileOffset: file.fileOffset,
            position: bounded
        )
        file.posBlockIndex = positioned.blockIndex
        file.posOffset = positioned.blockOffset
        file.pos = bounded
        return true
    }

    public func tell(_ file: FileHandle) -> UInt64 {
        file.pos
    }

    public func rewind(_ file: FileHandle) {
        file.posBlockIndex = file.fileStartBlockIndex
        file.posOffset = file.fileStartBlockIndex == 0 ? 0 : UInt16(fileFSBlockHead)
        file.pos = 0
    }

    public func fileExists(_ path: String) -> Bool {
        (try? statType(path)) == 1
    }

    public func dirExists(_ path: String) -> Bool {
        (try? statType(path)) == 2
    }

    public func removeFile(_ path: String) throws {
        try requireMounted()
        let resolved = try resolveParentAndName(path)
        if resolved.hadTrailingSlash {
            throw FileFSError.invalidPath(path)
        }
        guard let entry = try findEntry(inDirectory: resolved.parentBlockIndex, named: resolved.name) else {
            throw FileFSError.notFound(path)
        }
        guard entry.isFile else {
            throw FileFSError.notAFile(path)
        }

        try withAutoTransaction {
            try freeFileChainIfPresent(startBlockIndex: entry.startBlockIndex, stopBlockIndex: entry.stopBlockIndex)
            try removeEntry(fromDirectory: resolved.parentBlockIndex, entry: entry)
        }
    }

    public func rename(from: String, to: String) throws {
        try requireMounted()
        let source = try resolveParentAndName(from)
        let destination = try resolveParentAndName(to)
        guard let entry = try findEntry(inDirectory: source.parentBlockIndex, named: source.name) else {
            throw FileFSError.notFound(from)
        }
        if try findEntry(inDirectory: destination.parentBlockIndex, named: destination.name) != nil {
            throw FileFSError.alreadyExists(to)
        }

        try withAutoTransaction {
            if source.parentBlockIndex == destination.parentBlockIndex {
                var block = try readBlock(entry.containerBlockIndex)
                writeFixedName(destination.name, into: &block, at: entry.recordOffset + 1, size: fileFSBlockNameMaxSize)
                try writeBlock(entry.containerBlockIndex, block)
                return
            }

            if !entry.isFile {
                var childDir = try readBlock(entry.startBlockIndex)
                writeUInt32LE(destination.parentBlockIndex, into: &childDir, at: fileFSBlockHead + fileFSRecordSize + 1 + fileFSBlockNameMaxSize)
                try writeBlock(entry.startBlockIndex, childDir)
            }

            var record = entry.rawRecord
            writeFixedName(destination.name, into: &record, at: 1, size: fileFSBlockNameMaxSize)
            _ = try appendRawEntry(toDirectory: destination.parentBlockIndex, record: record)
            try removeEntry(fromDirectory: source.parentBlockIndex, entry: entry)
        }
    }

    public func move(from: String, toDir: String) throws {
        try requireMounted()
        let source = try resolveParentAndName(from)
        guard let entry = try findEntry(inDirectory: source.parentBlockIndex, named: source.name) else {
            throw FileFSError.notFound(from)
        }
        let destination = try resolveDirectoryPath(toDir)
        if try findEntry(inDirectory: destination.blockIndex, named: source.name) != nil {
            throw FileFSError.alreadyExists(source.name)
        }

        try withAutoTransaction {
            if !entry.isFile {
                var childDir = try readBlock(entry.startBlockIndex)
                writeUInt32LE(destination.blockIndex, into: &childDir, at: fileFSBlockHead + fileFSRecordSize + 1 + fileFSBlockNameMaxSize)
                try writeBlock(entry.startBlockIndex, childDir)
            }
            _ = try appendRawEntry(toDirectory: destination.blockIndex, record: entry.rawRecord)
            try removeEntry(fromDirectory: source.parentBlockIndex, entry: entry)
        }
    }

    public func copyFile(from: String, to: String) throws {
        try requireMounted()
        let source = try resolveParentAndName(from)
        let destination = try resolveParentAndName(to)
        if destination.hadTrailingSlash {
            throw FileFSError.invalidPath(to)
        }
        guard let sourceEntry = try findEntry(inDirectory: source.parentBlockIndex, named: source.name) else {
            throw FileFSError.notFound(from)
        }
        guard sourceEntry.isFile else {
            throw FileFSError.notAFile(from)
        }
        if try findEntry(inDirectory: destination.parentBlockIndex, named: destination.name) != nil {
            throw FileFSError.alreadyExists(to)
        }

        try withAutoTransaction {
            var newStart: UInt32 = 0
            var newStop: UInt32 = 0
            let newOffset = sourceEntry.fileOffset

            if sourceEntry.startBlockIndex > 0 {
                var sourceIndex = sourceEntry.startBlockIndex
                var previousNewIndex: UInt32 = 0

                while true {
                    var copiedBlock = try readBlock(sourceIndex)
                    let sourceNext = readUInt32LE(copiedBlock, at: 4)
                    let newIndex = try allocateBlock()
                    writeUInt32LE(previousNewIndex, into: &copiedBlock, at: 8)

                    if newStart == 0 {
                        newStart = newIndex
                    }

                    if sourceIndex == sourceEntry.stopBlockIndex {
                        newStop = newIndex
                        try writeBlock(newIndex, copiedBlock)
                        break
                    }

                    let nextNewIndex = try allocateBlock()
                    writeUInt32LE(nextNewIndex, into: &copiedBlock, at: 4)
                    try writeBlock(newIndex, copiedBlock)

                    previousNewIndex = newIndex
                    sourceIndex = sourceNext
                }
            }

            _ = try appendEntry(
                toDirectory: destination.parentBlockIndex,
                state: 1,
                name: destination.name,
                startBlockIndex: newStart,
                stopBlockIndex: newStop,
                fileOffset: newOffset
            )
        }
    }

    public func chdir(_ path: String) throws {
        try requireMounted()
        let resolved = try resolveDirectoryPath(path)
        if transaction.state == 0 {
            pwd = resolved.absolutePath
            pwdBlockIndex = resolved.blockIndex
        } else {
            transaction.pwd = resolved.absolutePath
            transaction.pwdBlockIndex = resolved.blockIndex
        }
    }

    public func getcwd() -> String {
        transaction.state == 0 ? pwd : transaction.pwd
    }

    public func mkdir(_ path: String) throws {
        try requireMounted()
        let resolved = try resolveParentAndName(path)
        if resolved.name == "." || resolved.name == ".." {
            throw FileFSError.invalidPath(path)
        }
        if try findEntry(inDirectory: resolved.parentBlockIndex, named: resolved.name) != nil {
            throw FileFSError.alreadyExists(path)
        }

        try withAutoTransaction {
            let newDirectoryBlockIndex = try allocateBlock()
            var block = [UInt8](repeating: 0, count: fileFSBlockSize)
            var offset = fileFSBlockHead

            block[offset] = 0
            offset += 1
            writeFixedName(".", into: &block, at: offset, size: fileFSBlockNameMaxSize)
            offset += fileFSBlockNameMaxSize
            writeUInt32LE(newDirectoryBlockIndex, into: &block, at: offset)
            offset += 4
            writeUInt32LE(newDirectoryBlockIndex, into: &block, at: offset)
            offset += 4
            writeUInt16LE(UInt16(fileFSBlockHead + fileFSRecordSize + fileFSRecordSize), into: &block, at: offset)
            offset += 2

            block[offset] = 0
            offset += 1
            writeFixedName("..", into: &block, at: offset, size: fileFSBlockNameMaxSize)
            offset += fileFSBlockNameMaxSize
            writeUInt32LE(resolved.parentBlockIndex, into: &block, at: offset)

            try writeBlock(newDirectoryBlockIndex, block)
            _ = try appendEntry(
                toDirectory: resolved.parentBlockIndex,
                state: 0,
                name: resolved.name,
                startBlockIndex: newDirectoryBlockIndex,
                stopBlockIndex: 0,
                fileOffset: 0
            )
        }
    }

    public func rmdir(_ path: String) throws {
        try requireMounted()
        let resolved = try resolveParentAndName(path)
        guard let entry = try findEntry(inDirectory: resolved.parentBlockIndex, named: resolved.name) else {
            throw FileFSError.notFound(path)
        }
        guard !entry.isFile else {
            throw FileFSError.notADirectory(path)
        }

        let childBlock = try readBlock(entry.startBlockIndex)
        let childStart = readUInt32LE(childBlock, at: fileFSBlockStartBlockIndexOffset)
        let childStop = readUInt32LE(childBlock, at: fileFSBlockStopBlockIndexOffset)
        let childOffset = readUInt16LE(childBlock, at: fileFSBlockOffsetOffset)
        guard childStart == childStop, childOffset <= 62 else {
            throw FileFSError.directoryNotEmpty(path)
        }

        try withAutoTransaction {
            try removeBlock(entry.startBlockIndex)
            try removeEntry(fromDirectory: resolved.parentBlockIndex, entry: entry)
        }
    }

    public func openDir(_ path: String) throws -> DirectoryHandle {
        try requireMounted()
        let resolved = try resolveDirectoryPath(path)
        let block = try readBlock(resolved.blockIndex)
        return DirectoryHandle(
            blockIndex: resolved.blockIndex,
            block: block,
            searchIndex: 0,
            stopBlockIndex: readUInt32LE(block, at: fileFSBlockStopBlockIndexOffset),
            offset: readUInt16LE(block, at: fileFSBlockOffsetOffset)
        )
    }

    public func readDir(_ dir: DirectoryHandle) -> DirEntry? {
        guard hostFile != nil else {
            return nil
        }

        while true {
            if dir.searchIndex >= fileFSBlockItemMaxCount {
                let nextIndex = readUInt32LE(dir.block, at: 4)
                guard nextIndex != 0, let nextBlock = try? readBlock(nextIndex) else {
                    return nil
                }
                dir.block = nextBlock
                dir.blockIndex = nextIndex
                dir.searchIndex = 0
            }

            let recordOffset = fileFSBlockHead + dir.searchIndex * fileFSRecordSize
            if dir.blockIndex == dir.stopBlockIndex && recordOffset + 1 >= Int(dir.offset) {
                return nil
            }

            let state = dir.block[recordOffset]
            let name = fixedCString(dir.block[(recordOffset + 1)..<(recordOffset + 1 + fileFSBlockNameMaxSize)])
            let startBlockIndex = readUInt32LE(dir.block, at: recordOffset + 15)
            dir.searchIndex += 1

            var type: DirEntryType = state & 0x01 == 1 ? .file : .directory
            if name == "." && startBlockIndex == 1 {
                type = .root
            } else if name == ".." && startBlockIndex == 0 {
                type = .root
            }
            return DirEntry(type: type, name: name)
        }
    }

    public func closeDir(_ dir: DirectoryHandle) {
        _ = dir
    }

    public func begin() throws {
        try requireMounted()
        if transaction.state != 0 {
            rollback()
        }
        try beginTransaction(state: 2)
    }

    public func commit() throws {
        try requireMounted()
        try commitTransaction()
    }

    public func rollback() {
        if !journalPath.isEmpty {
            try? FileManager.default.removeItem(atPath: journalPath)
        }
        transaction = TransactionState()
    }

    private func requireMounted() throws {
        guard hostFile != nil else {
            throw FileFSError.notMounted
        }
    }

    private func currentDirectoryPath() -> String {
        transaction.state == 0 ? pwd : transaction.pwd
    }

    private func currentDirectoryBlockIndex() -> UInt32 {
        transaction.state == 0 ? pwdBlockIndex : transaction.pwdBlockIndex
    }

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private func resolveDirectoryPath(_ path: String) throws -> ResolvedDirectory {
        let absolute = path.hasPrefix("/")
        var blockIndex: UInt32 = absolute ? 1 : currentDirectoryBlockIndex()
        var absolutePath: String = absolute ? "/" : currentDirectoryPath()

        for component in pathComponents(path) {
            try ensureUTF8NameFits(component, limit: fileFSBlockNameMaxSize)
            guard let entry = try findEntry(inDirectory: blockIndex, named: component) else {
                throw FileFSError.notFound(path)
            }
            guard !entry.isFile else {
                throw FileFSError.notADirectory(path)
            }
            blockIndex = entry.startBlockIndex
            absolutePath = normalizeDirectoryPath(absolutePath, appending: component)
        }

        return ResolvedDirectory(blockIndex: blockIndex, absolutePath: absolutePath)
    }

    private func resolveParentAndName(_ path: String) throws -> ResolvedName {
        guard !path.isEmpty else {
            throw FileFSError.invalidPath(path)
        }
        let components = pathComponents(path)
        guard let name = components.last else {
            throw FileFSError.invalidPath(path)
        }
        try ensureUTF8NameFits(name, limit: fileFSBlockNameMaxSize)

        let absolute = path.hasPrefix("/")
        var parentIndex: UInt32 = absolute ? 1 : currentDirectoryBlockIndex()
        for component in components.dropLast() {
            try ensureUTF8NameFits(component, limit: fileFSBlockNameMaxSize)
            guard let entry = try findEntry(inDirectory: parentIndex, named: component) else {
                throw FileFSError.notFound(path)
            }
            guard !entry.isFile else {
                throw FileFSError.notADirectory(path)
            }
            parentIndex = entry.startBlockIndex
        }
        return ResolvedName(
            parentBlockIndex: parentIndex,
            name: name,
            hadTrailingSlash: path.count > 1 && path.hasSuffix("/")
        )
    }

    private func normalizeDirectoryPath(_ path: String, appending component: String) -> String {
        if component == "." {
            return path
        }
        if component == ".." {
            if path == "/" {
                return "/"
            }
            var trimmed = path
            if trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            while let lastSlash = trimmed.lastIndex(of: "/"), lastSlash != trimmed.startIndex {
                trimmed = String(trimmed[..<lastSlash])
                break
            }
            if trimmed.isEmpty {
                return "/"
            }
            if !trimmed.hasSuffix("/") {
                trimmed.append("/")
            }
            return trimmed == "" ? "/" : trimmed
        }
        if path == "/" {
            return "/\(component)/"
        }
        return "\(path)\(component)/"
    }

    private func statType(_ path: String) throws -> UInt8 {
        try requireMounted()
        if path == "/" {
            return 2
        }
        let components = pathComponents(path)
        if components.isEmpty {
            return 2
        }

        let absolute = path.hasPrefix("/")
        var blockIndex: UInt32 = absolute ? 1 : currentDirectoryBlockIndex()
        for component in components.dropLast() {
            guard let entry = try findEntry(inDirectory: blockIndex, named: component) else {
                return 0
            }
            guard !entry.isFile else {
                return 0
            }
            blockIndex = entry.startBlockIndex
        }

        guard let entry = try findEntry(inDirectory: blockIndex, named: components.last ?? "") else {
            return 0
        }
        return entry.isFile ? 1 : 2
    }

    private func fileLength(startBlockIndex: UInt32, stopBlockIndex: UInt32, fileOffset: UInt16) throws -> UInt64 {
        guard startBlockIndex != 0 else {
            return 0
        }

        var index = startBlockIndex
        var total: UInt64 = 0
        while true {
            if index == stopBlockIndex {
                total += UInt64(fileOffset - UInt16(fileFSBlockHead))
                return total
            }
            let block = try readBlock(index)
            total += UInt64(fileFSBlockSize - fileFSBlockHead)
            index = readUInt32LE(block, at: 4)
            if index == 0 {
                return total
            }
        }
    }

    private func locatePosition(
        startBlockIndex: UInt32,
        stopBlockIndex: UInt32,
        fileOffset: UInt16,
        position: UInt64
    ) throws -> (blockIndex: UInt32, blockOffset: UInt16) {
        guard startBlockIndex != 0 else {
            return (0, 0)
        }

        var remaining = position
        var blockIndex = startBlockIndex
        while true {
            let capacity: UInt64 = blockIndex == stopBlockIndex
                ? UInt64(fileOffset - UInt16(fileFSBlockHead))
                : UInt64(fileFSBlockSize - fileFSBlockHead)

            if remaining <= capacity {
                return (blockIndex, UInt16(fileFSBlockHead) + UInt16(remaining))
            }

            remaining -= capacity
            let block = try readBlock(blockIndex)
            let next = readUInt32LE(block, at: 4)
            if next == 0 {
                return (blockIndex, blockIndex == stopBlockIndex ? fileOffset : UInt16(fileFSBlockSize))
            }
            blockIndex = next
        }
    }

    private func makeRecord(
        state: UInt8,
        name: String,
        startBlockIndex: UInt32,
        stopBlockIndex: UInt32,
        fileOffset: UInt16
    ) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: fileFSRecordSize)
        record[0] = state
        writeFixedName(name, into: &record, at: 1, size: fileFSBlockNameMaxSize)
        writeUInt32LE(startBlockIndex, into: &record, at: 15)
        writeUInt32LE(stopBlockIndex, into: &record, at: 19)
        writeUInt16LE(fileOffset, into: &record, at: 23)
        return record
    }

    private func appendEntry(
        toDirectory directoryBlockIndex: UInt32,
        state: UInt8,
        name: String,
        startBlockIndex: UInt32,
        stopBlockIndex: UInt32,
        fileOffset: UInt16
    ) throws -> DirectoryEntryInfo {
        try appendRawEntry(
            toDirectory: directoryBlockIndex,
            record: makeRecord(
                state: state,
                name: name,
                startBlockIndex: startBlockIndex,
                stopBlockIndex: stopBlockIndex,
                fileOffset: fileOffset
            )
        )
    }

    private func appendRawEntry(
        toDirectory directoryBlockIndex: UInt32,
        record: [UInt8]
    ) throws -> DirectoryEntryInfo {
        var headBlock = try readBlock(directoryBlockIndex)
        let stopBlockIndex = readUInt32LE(headBlock, at: fileFSBlockStopBlockIndexOffset)
        let currentOffset = Int(readUInt16LE(headBlock, at: fileFSBlockOffsetOffset))

        if currentOffset < fileFSBlockSize {
            var stopBlock = stopBlockIndex == directoryBlockIndex ? headBlock : try readBlock(stopBlockIndex)
            stopBlock.replaceSubrange(currentOffset..<(currentOffset + fileFSRecordSize), with: record)
            let newOffset = UInt16(currentOffset + fileFSRecordSize)

            if stopBlockIndex == directoryBlockIndex {
                headBlock = stopBlock
            } else {
                try writeBlock(stopBlockIndex, stopBlock)
            }
            writeUInt16LE(newOffset, into: &headBlock, at: fileFSBlockOffsetOffset)
            try writeBlock(directoryBlockIndex, headBlock)

            return DirectoryEntryInfo(
                containerBlockIndex: stopBlockIndex,
                recordOffset: currentOffset,
                state: record[0],
                name: fixedCString(record[1..<(1 + fileFSBlockNameMaxSize)]),
                startBlockIndex: readUInt32LE(record, at: 15),
                stopBlockIndex: readUInt32LE(record, at: 19),
                fileOffset: readUInt16LE(record, at: 23),
                rawRecord: record
            )
        }

        let newBlockIndex = try allocateBlock()
        var newBlock = [UInt8](repeating: 0, count: fileFSBlockSize)
        writeUInt32LE(stopBlockIndex, into: &newBlock, at: 8)
        newBlock.replaceSubrange(fileFSBlockHead..<(fileFSBlockHead + fileFSRecordSize), with: record)
        try writeBlock(newBlockIndex, newBlock)

        if stopBlockIndex == directoryBlockIndex {
            writeUInt32LE(newBlockIndex, into: &headBlock, at: 4)
        } else {
            var oldStop = try readBlock(stopBlockIndex)
            writeUInt32LE(newBlockIndex, into: &oldStop, at: 4)
            try writeBlock(stopBlockIndex, oldStop)
        }

        writeUInt32LE(newBlockIndex, into: &headBlock, at: fileFSBlockStopBlockIndexOffset)
        writeUInt16LE(UInt16(fileFSBlockHead + fileFSRecordSize), into: &headBlock, at: fileFSBlockOffsetOffset)
        try writeBlock(directoryBlockIndex, headBlock)

        return DirectoryEntryInfo(
            containerBlockIndex: newBlockIndex,
            recordOffset: fileFSBlockHead,
            state: record[0],
            name: fixedCString(record[1..<(1 + fileFSBlockNameMaxSize)]),
            startBlockIndex: readUInt32LE(record, at: 15),
            stopBlockIndex: readUInt32LE(record, at: 19),
            fileOffset: readUInt16LE(record, at: 23),
            rawRecord: record
        )
    }

    private func clearFileEntry(_ entry: DirectoryEntryInfo) throws {
        try freeFileChainIfPresent(startBlockIndex: entry.startBlockIndex, stopBlockIndex: entry.stopBlockIndex)
        var block = try readBlock(entry.containerBlockIndex)
        writeUInt32LE(0, into: &block, at: entry.recordOffset + 15)
        writeUInt32LE(0, into: &block, at: entry.recordOffset + 19)
        writeUInt16LE(0, into: &block, at: entry.recordOffset + 23)
        try writeBlock(entry.containerBlockIndex, block)
    }

    private func freeFileChainIfPresent(startBlockIndex: UInt32, stopBlockIndex: UInt32) throws {
        guard startBlockIndex > 0 else {
            return
        }
        var stopBlock = try readBlock(stopBlockIndex)
        writeUInt32LE(transaction.newUnusedBlockHead, into: &stopBlock, at: 4)
        transaction.newUnusedBlockHead = startBlockIndex
        try writeBlock(stopBlockIndex, stopBlock)
    }

    private func removeEntry(fromDirectory directoryBlockIndex: UInt32, entry: DirectoryEntryInfo) throws {
        var headBlock = try readBlock(directoryBlockIndex)
        let stopBlockIndex = readUInt32LE(headBlock, at: fileFSBlockStopBlockIndexOffset)
        var offset = Int(readUInt16LE(headBlock, at: fileFSBlockOffsetOffset))
        var lastBlock = stopBlockIndex == directoryBlockIndex ? headBlock : try readBlock(stopBlockIndex)
        let lastRecordOffset = offset - fileFSRecordSize

        var targetBlock = entry.containerBlockIndex == directoryBlockIndex ? headBlock
            : (entry.containerBlockIndex == stopBlockIndex ? lastBlock : try readBlock(entry.containerBlockIndex))

        if entry.containerBlockIndex != stopBlockIndex || entry.recordOffset != lastRecordOffset {
            let movedRecord = Array(lastBlock[lastRecordOffset..<(lastRecordOffset + fileFSRecordSize)])
            targetBlock.replaceSubrange(entry.recordOffset..<(entry.recordOffset + fileFSRecordSize), with: movedRecord)
        }

        if entry.containerBlockIndex == directoryBlockIndex {
            headBlock = targetBlock
        } else if entry.containerBlockIndex == stopBlockIndex {
            lastBlock = targetBlock
        } else {
            try writeBlock(entry.containerBlockIndex, targetBlock)
        }

        if stopBlockIndex == directoryBlockIndex {
            lastBlock = headBlock
        }

        offset -= fileFSRecordSize
        writeUInt16LE(UInt16(offset), into: &headBlock, at: fileFSBlockOffsetOffset)
        if stopBlockIndex == directoryBlockIndex {
            lastBlock = headBlock
        }

        if offset < fileFSRecordSize {
            let previousBlockIndex = readUInt32LE(lastBlock, at: 8)
            try removeBlock(stopBlockIndex)
            guard previousBlockIndex > 0 else {
                throw FileFSError.transactionError("Directory block chain is corrupted")
            }

            var previousBlock = previousBlockIndex == directoryBlockIndex ? headBlock : try readBlock(previousBlockIndex)
            writeUInt32LE(0, into: &previousBlock, at: 4)
            if previousBlockIndex == directoryBlockIndex {
                headBlock = previousBlock
            } else {
                try writeBlock(previousBlockIndex, previousBlock)
            }

            writeUInt32LE(previousBlockIndex, into: &headBlock, at: fileFSBlockStopBlockIndexOffset)
            writeUInt16LE(UInt16(fileFSBlockSize), into: &headBlock, at: fileFSBlockOffsetOffset)
            try writeBlock(directoryBlockIndex, headBlock)
            return
        }

        if stopBlockIndex == directoryBlockIndex {
            try writeBlock(directoryBlockIndex, lastBlock)
        } else {
            try writeBlock(stopBlockIndex, lastBlock)
            try writeBlock(directoryBlockIndex, headBlock)
        }
    }

    private func findEntry(inDirectory directoryBlockIndex: UInt32, named name: String) throws -> DirectoryEntryInfo? {
        var blockIndex = directoryBlockIndex
        var block = try readBlock(blockIndex)
        let stopBlockIndex = readUInt32LE(block, at: fileFSBlockStopBlockIndexOffset)
        let stopOffset = Int(readUInt16LE(block, at: fileFSBlockOffsetOffset))

        while true {
            var recordOffset = fileFSBlockHead
            for _ in 0..<fileFSBlockItemMaxCount {
                if blockIndex == stopBlockIndex && recordOffset + 1 >= stopOffset {
                    return nil
                }
                let record = Array(block[recordOffset..<(recordOffset + fileFSRecordSize)])
                let entryName = fixedCString(record[1..<(1 + fileFSBlockNameMaxSize)])
                if entryName == name {
                    return DirectoryEntryInfo(
                        containerBlockIndex: blockIndex,
                        recordOffset: recordOffset,
                        state: record[0],
                        name: entryName,
                        startBlockIndex: readUInt32LE(record, at: 15),
                        stopBlockIndex: readUInt32LE(record, at: 19),
                        fileOffset: readUInt16LE(record, at: 23),
                        rawRecord: record
                    )
                }
                recordOffset += fileFSRecordSize
            }

            let nextBlockIndex = readUInt32LE(block, at: 4)
            if nextBlockIndex == 0 {
                return nil
            }
            blockIndex = nextBlockIndex
            block = try readBlock(blockIndex)
        }
    }

    private func beginTransaction(state: UInt8) throws {
        guard state != 0 else {
            throw FileFSError.transactionError("Invalid transaction state")
        }
        let block0 = try readExact(from: try mountedHostFile(), at: 0, count: 12)
        transaction.state = state
        transaction.pwd = pwd
        transaction.pwdBlockIndex = pwdBlockIndex
        transaction.totalBlockSize = readUInt32LE(block0, at: 4)
        transaction.unusedBlockHead = readUInt32LE(block0, at: 8)
        transaction.newTotalBlockSize = transaction.totalBlockSize
        transaction.newUnusedBlockHead = transaction.unusedBlockHead
        transaction.modifiedBlocks = [:]
    }

    private func withAutoTransaction<T>(_ body: () throws -> T) throws -> T {
        let shouldAutoCommit = transaction.state == 0
        if shouldAutoCommit {
            try beginTransaction(state: 1)
        }

        do {
            let result = try body()
            if shouldAutoCommit {
                try commitTransaction()
            }
            return result
        } catch {
            if shouldAutoCommit {
                rollback()
            }
            throw error
        }
    }

    private func commitTransaction() throws {
        if transaction.state == 0 {
            return
        }

        var records: [(UInt32, [UInt8])] = []
        if transaction.totalBlockSize != transaction.newTotalBlockSize || transaction.unusedBlockHead != transaction.newUnusedBlockHead {
            var block0 = [UInt8](repeating: 0, count: fileFSBlockSize)
            block0.replaceSubrange(0..<4, with: fileFSMagic)
            writeUInt32LE(transaction.newTotalBlockSize, into: &block0, at: 4)
            writeUInt32LE(transaction.newUnusedBlockHead, into: &block0, at: 8)
            records.append((0, block0))
        }

        for blockIndex in transaction.modifiedBlocks.keys.sorted() {
            if let block = transaction.modifiedBlocks[blockIndex] {
                records.append((blockIndex, block))
            }
        }

        let manager = FileManager.default
        if manager.fileExists(atPath: journalPath) {
            try? manager.removeItem(atPath: journalPath)
        }
        guard manager.createFile(atPath: journalPath, contents: nil) else {
            throw FileFSError.ioError("Unable to create journal at \(journalPath)")
        }
        let journalHandle = try Foundation.FileHandle(forUpdating: URL(fileURLWithPath: journalPath))
        defer {
            try? journalHandle.close()
        }

        do {
            try journalHandle.seek(toOffset: 0)
            try journalHandle.write(contentsOf: Data([0]))
            for (blockIndex, block) in records {
                var header = [UInt8](repeating: 0, count: 4)
                writeUInt32LE(blockIndex, into: &header, at: 0)
                try journalHandle.write(contentsOf: Data(header))
                try journalHandle.write(contentsOf: Data(block))
            }
            try journalHandle.seek(toOffset: 0)
            try journalHandle.write(contentsOf: Data([0xFF]))
            try journalHandle.synchronize()
        } catch {
            rollback()
            throw FileFSError.ioError("Unable to write journal: \(error)")
        }

        let host = try mountedHostFile()
        do {
            for (blockIndex, block) in records {
                try writeExact(to: host, at: UInt64(blockIndex) * UInt64(fileFSBlockSize), bytes: block)
            }
            try host.synchronize()
        } catch {
            rollback()
            throw FileFSError.ioError("Unable to apply journal: \(error)")
        }

        try? manager.removeItem(atPath: journalPath)
        pwd = transaction.pwd
        pwdBlockIndex = transaction.pwdBlockIndex
        transaction = TransactionState()
    }

    private func applyPendingJournalIfNeeded() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: journalPath) else {
            return
        }

        let journalHandle = try Foundation.FileHandle(forReadingFrom: URL(fileURLWithPath: journalPath))
        defer {
            try? journalHandle.close()
            try? manager.removeItem(atPath: journalPath)
        }

        let state = try readExact(from: journalHandle, at: 0, count: 1)
        guard state.first == 0xFF else {
            return
        }

        let host = try mountedHostFile()
        var offset: UInt64 = 1
        while true {
            let record: [UInt8]?
            do {
                record = try readExactOptional(from: journalHandle, at: offset, count: fileFSBlockSize + 4)
            } catch {
                break
            }
            guard let record else {
                break
            }
            let blockIndex = readUInt32LE(record, at: 0)
            let block = Array(record[4..<(4 + fileFSBlockSize)])
            try writeExact(to: host, at: UInt64(blockIndex) * UInt64(fileFSBlockSize), bytes: block)
            offset += UInt64(fileFSBlockSize + 4)
        }
        try host.synchronize()
    }

    private func allocateBlock() throws -> UInt32 {
        guard transaction.state != 0 else {
            throw FileFSError.transactionError("Writes require an active transaction")
        }

        if transaction.newUnusedBlockHead > 0 {
            let blockIndex = transaction.newUnusedBlockHead
            let block = try readBlock(blockIndex)
            transaction.newUnusedBlockHead = readUInt32LE(block, at: 4)
            return blockIndex
        }

        let blockIndex = transaction.newTotalBlockSize
        transaction.newTotalBlockSize += 1
        transaction.modifiedBlocks[blockIndex] = [UInt8](repeating: 0, count: fileFSBlockSize)
        return blockIndex
    }

    private func removeBlock(_ blockIndex: UInt32) throws {
        guard transaction.state != 0 else {
            throw FileFSError.transactionError("Writes require an active transaction")
        }
        var block = [UInt8](repeating: 0, count: fileFSBlockSize)
        writeUInt32LE(transaction.newUnusedBlockHead, into: &block, at: 4)
        transaction.newUnusedBlockHead = blockIndex
        transaction.modifiedBlocks[blockIndex] = block
    }

    private func readBlock(_ blockIndex: UInt32) throws -> [UInt8] {
        if transaction.state != 0, let staged = transaction.modifiedBlocks[blockIndex] {
            return staged
        }
        return try readExact(from: try mountedHostFile(), at: UInt64(blockIndex) * UInt64(fileFSBlockSize), count: fileFSBlockSize)
    }

    private func writeBlock(_ blockIndex: UInt32, _ block: [UInt8]) throws {
        guard transaction.state != 0 else {
            throw FileFSError.transactionError("Writes require an active transaction")
        }
        guard block.count == fileFSBlockSize else {
            throw FileFSError.transactionError("Invalid block size")
        }
        transaction.modifiedBlocks[blockIndex] = block
    }

    private func mountedHostFile() throws -> Foundation.FileHandle {
        guard let hostFile else {
            throw FileFSError.notMounted
        }
        return hostFile
    }

    private func readExact(from handle: Foundation.FileHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
        guard let data = try readExactOptional(from: handle, at: offset, count: count) else {
            throw FileFSError.ioError("Unexpected end of file")
        }
        return data
    }

    private func readExactOptional(from handle: Foundation.FileHandle, at offset: UInt64, count: Int) throws -> [UInt8]? {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count) else {
            return nil
        }
        guard data.count == count else {
            return nil
        }
        return Array(data)
    }

    private func writeExact(to handle: Foundation.FileHandle, at offset: UInt64, bytes: [UInt8]) throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data(bytes))
    }
}
