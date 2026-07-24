package filefs.internal

import filefs.DirEntry
import filefs.FileType
import java.nio.charset.StandardCharsets
import java.util.IdentityHashMap
import kotlin.math.ceil

internal object FormatConstants {
    const val BLOCK_SIZE = 512
    const val BLOCK_ITEM_MAX_COUNT = 20
    const val BLOCK_HEAD = 12
    const val BLOCK_NAME_MAX_SIZE = 14
    const val ENTRY_SIZE = 25
    const val ROOT_BLOCKINDEX = 1
    const val DATA_PER_BLOCK = BLOCK_SIZE - BLOCK_HEAD

    val MAGIC: ByteArray = byteArrayOf(0x78, 0x11, 0x45, 0x14)
}

internal sealed class FsNode(open var name: String) {
    abstract var parent: DirNode?
}

internal class DirNode(
    override var name: String,
    override var parent: DirNode?,
) : FsNode(name) {
    val children: LinkedHashMap<String, FsNode> = LinkedHashMap()
}

internal class FileNode(
    override var name: String,
    override var parent: DirNode?,
    var data: ByteArray = ByteArray(0),
) : FsNode(name)

internal data class TreeCopy(
    val root: DirNode,
    val cwd: DirNode,
)

internal fun deepCopyTree(root: DirNode, cwd: DirNode): TreeCopy {
    val dirMap = IdentityHashMap<DirNode, DirNode>()

    fun copyDir(source: DirNode, parent: DirNode?): DirNode {
        val copy = DirNode(source.name, parent)
        dirMap[source] = copy
        for ((name, child) in source.children) {
            copy.children[name] = when (child) {
                is DirNode -> copyDir(child, copy)
                is FileNode -> FileNode(child.name, copy, child.data.copyOf())
            }
        }
        return copy
    }

    val rootCopy = copyDir(root, null)
    val cwdCopy = dirMap[cwd] ?: rootCopy
    return TreeCopy(rootCopy, cwdCopy)
}

internal fun buildAbsolutePath(dir: DirNode): String {
    if (dir.parent == null) {
        return "/"
    }

    val parts = ArrayDeque<String>()
    var current: DirNode? = dir
    while (current != null && current.parent != null) {
        parts.addFirst(current.name)
        current = current.parent
    }

    return buildString {
        append('/')
        while (parts.isNotEmpty()) {
            append(parts.removeFirst())
            append('/')
        }
    }
}

internal fun listDirectoryEntries(dir: DirNode): List<DirEntry> {
    val entries = ArrayList<DirEntry>(dir.children.size + 2)
    val dotType = if (dir.parent == null) FileType.ROOT else FileType.DIR
    val dotDotType = if (dir.parent == null) FileType.ROOT else FileType.DIR
    entries += DirEntry(dotType, ".")
    entries += DirEntry(dotDotType, "..")
    for (child in dir.children.values) {
        val type = when (child) {
            is DirNode -> FileType.DIR
            is FileNode -> FileType.FILE
        }
        entries += DirEntry(type, child.name)
    }
    return entries
}

internal data class SerializedImage(
    val blocks: List<ByteArray>,
)

internal fun serializeTree(root: DirNode): SerializedImage {
    val addresses = IdentityHashMap<FsNode, NodeAddress>()

    fun assign(node: FsNode, nextIndex: Int): Int {
        return when (node) {
            is DirNode -> {
                val entryCount = 2 + node.children.size
                val blockCount = ceil(entryCount / FormatConstants.BLOCK_ITEM_MAX_COUNT.toDouble()).toInt()
                val start = nextIndex
                val stop = start + blockCount - 1
                val remainder = entryCount % FormatConstants.BLOCK_ITEM_MAX_COUNT
                val offset = if (remainder == 0) {
                    FormatConstants.BLOCK_SIZE
                } else {
                    FormatConstants.BLOCK_HEAD + remainder * FormatConstants.ENTRY_SIZE
                }
                addresses[node] = NodeAddress(start, stop, offset, blockCount)
                var cursor = stop + 1
                for (child in node.children.values) {
                    cursor = assign(child, cursor)
                }
                cursor
            }

            is FileNode -> {
                if (node.data.isEmpty()) {
                    addresses[node] = NodeAddress(0, 0, 0, 0)
                    nextIndex
                } else {
                    val blockCount = ceil(node.data.size / FormatConstants.DATA_PER_BLOCK.toDouble()).toInt()
                    val start = nextIndex
                    val stop = start + blockCount - 1
                    val remainder = node.data.size % FormatConstants.DATA_PER_BLOCK
                    val offset = if (remainder == 0) {
                        FormatConstants.BLOCK_SIZE
                    } else {
                        FormatConstants.BLOCK_HEAD + remainder
                    }
                    addresses[node] = NodeAddress(start, stop, offset, blockCount)
                    stop + 1
                }
            }
        }
    }

    val totalBlocks = assign(root, FormatConstants.ROOT_BLOCKINDEX)
    val blocks = MutableList(totalBlocks) { ByteArray(FormatConstants.BLOCK_SIZE) }

    writeBytes(blocks[0], 0, FormatConstants.MAGIC)
    writeU32LE(blocks[0], 4, totalBlocks)
    writeU32LE(blocks[0], 8, 0)

    fun serializeFile(file: FileNode) {
        val address = addresses[file] ?: error("missing address for file")
        if (address.start == 0) {
            return
        }

        var sourceOffset = 0
        for (blockIndex in address.start..address.stop) {
            val block = blocks[blockIndex]
            val next = if (blockIndex < address.stop) blockIndex + 1 else 0
            val prev = if (blockIndex > address.start) blockIndex - 1 else 0
            writeU32LE(block, 4, next)
            writeU32LE(block, 8, prev)

            val endExclusive = minOf(sourceOffset + FormatConstants.DATA_PER_BLOCK, file.data.size)
            file.data.copyInto(
                destination = block,
                destinationOffset = FormatConstants.BLOCK_HEAD,
                startIndex = sourceOffset,
                endIndex = endExclusive,
            )
            sourceOffset = endExclusive
        }
    }

    fun serializeDir(dir: DirNode) {
        val address = addresses[dir] ?: error("missing address for directory")
        val entries = ArrayList<WireEntry>(dir.children.size + 2)
        entries += WireEntry(
            isFile = false,
            name = ".",
            start = address.start,
            stop = address.stop,
            offset = address.offset,
        )
        entries += WireEntry(
            isFile = false,
            name = "..",
            start = dir.parent?.let { addresses[it]?.start } ?: 0,
            stop = 0,
            offset = 0,
        )
        for (child in dir.children.values) {
            val childAddress = addresses[child] ?: error("missing address for child")
            entries += WireEntry(
                isFile = child is FileNode,
                name = child.name,
                start = childAddress.start,
                stop = childAddress.stop,
                offset = childAddress.offset,
            )
        }

        for (blockOffset in 0 until address.blockCount) {
            val blockIndex = address.start + blockOffset
            val block = blocks[blockIndex]
            val next = if (blockIndex < address.stop) blockIndex + 1 else 0
            val prev = if (blockIndex > address.start) blockIndex - 1 else 0
            writeU32LE(block, 4, next)
            writeU32LE(block, 8, prev)

            val from = blockOffset * FormatConstants.BLOCK_ITEM_MAX_COUNT
            val to = minOf(entries.size, from + FormatConstants.BLOCK_ITEM_MAX_COUNT)
            var position = FormatConstants.BLOCK_HEAD
            for (entry in entries.subList(from, to)) {
                block[position] = if (entry.isFile) 1 else 0
                position += 1
                writeFixedName(block, position, entry.name)
                position += FormatConstants.BLOCK_NAME_MAX_SIZE
                writeU32LE(block, position, entry.start)
                position += 4
                writeU32LE(block, position, entry.stop)
                position += 4
                writeU16LE(block, position, entry.offset)
                position += 2
            }
        }

        for (child in dir.children.values) {
            when (child) {
                is DirNode -> serializeDir(child)
                is FileNode -> serializeFile(child)
            }
        }
    }

    serializeDir(root)
    return SerializedImage(blocks)
}

internal fun parseTree(blocks: List<ByteArray>): DirNode {
    require(blocks.size >= 2) { "image must contain at least two blocks" }

    val visited = mutableSetOf<Int>()

    fun readBlock(index: Int): ByteArray {
        return blocks.getOrNull(index) ?: throw IllegalArgumentException("missing block $index")
    }

    fun parseFile(start: Int, stop: Int, offset: Int): ByteArray {
        if (start == 0 && stop == 0 && offset == 0) {
            return ByteArray(0)
        }
        require(start > 0 && stop >= start) { "invalid file block range" }
        require(offset in FormatConstants.BLOCK_HEAD..FormatConstants.BLOCK_SIZE) { "invalid file offset" }

        val out = ArrayList<Byte>()
        var current = start
        while (true) {
            val block = readBlock(current)
            val limit = if (current == stop) offset else FormatConstants.BLOCK_SIZE
            require(limit in FormatConstants.BLOCK_HEAD..FormatConstants.BLOCK_SIZE) { "invalid block limit" }
            for (i in FormatConstants.BLOCK_HEAD until limit) {
                out += block[i]
            }
            if (current == stop) {
                break
            }
            current = readU32LE(block, 4)
            require(current != 0) { "unterminated file block chain" }
        }
        return out.toByteArray()
    }

    fun parseDir(index: Int, name: String, parent: DirNode?): DirNode {
        require(visited.add(index)) { "directory cycle at block $index" }
        val firstBlock = readBlock(index)
        val dot = readEntry(firstBlock, FormatConstants.BLOCK_HEAD)
        require(!dot.isFile && dot.name == ".") { "invalid directory header at block $index" }

        val dir = DirNode(name, parent)
        val entries = ArrayList<WireEntry>()
        var current = index
        while (true) {
            val block = readBlock(current)
            val limit = if (current == dot.stop) dot.offset else FormatConstants.BLOCK_SIZE
            require(limit in FormatConstants.BLOCK_HEAD..FormatConstants.BLOCK_SIZE) { "invalid directory offset" }
            var position = FormatConstants.BLOCK_HEAD
            while (position + FormatConstants.ENTRY_SIZE <= limit) {
                entries += readEntry(block, position)
                position += FormatConstants.ENTRY_SIZE
            }
            if (current == dot.stop) {
                break
            }
            current = readU32LE(block, 4)
            require(current != 0) { "unterminated directory chain" }
        }

        require(entries.size >= 2) { "directory missing dot entries" }
        require(entries[1].name == "..") { "directory missing parent entry" }

        for (entry in entries.drop(2)) {
            require(entry.name.isNotEmpty()) { "empty child entry" }
            val child = if (entry.isFile) {
                FileNode(entry.name, dir, parseFile(entry.start, entry.stop, entry.offset))
            } else {
                parseDir(entry.start, entry.name, dir)
            }
            dir.children[child.name] = child
        }
        return dir
    }

    return parseDir(FormatConstants.ROOT_BLOCKINDEX, "", null)
}

internal fun readU32LE(bytes: ByteArray, offset: Int): Int {
    return (bytes[offset].toInt() and 0xFF) or
        ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
        ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
        ((bytes[offset + 3].toInt() and 0xFF) shl 24)
}

internal fun writeU32LE(bytes: ByteArray, offset: Int, value: Int) {
    bytes[offset] = (value and 0xFF).toByte()
    bytes[offset + 1] = ((value ushr 8) and 0xFF).toByte()
    bytes[offset + 2] = ((value ushr 16) and 0xFF).toByte()
    bytes[offset + 3] = ((value ushr 24) and 0xFF).toByte()
}

internal fun readU16LE(bytes: ByteArray, offset: Int): Int {
    return (bytes[offset].toInt() and 0xFF) or ((bytes[offset + 1].toInt() and 0xFF) shl 8)
}

internal fun writeU16LE(bytes: ByteArray, offset: Int, value: Int) {
    bytes[offset] = (value and 0xFF).toByte()
    bytes[offset + 1] = ((value ushr 8) and 0xFF).toByte()
}

internal fun writeBytes(destination: ByteArray, offset: Int, value: ByteArray) {
    value.copyInto(destination, offset)
}

internal fun readFixedName(bytes: ByteArray, offset: Int): String {
    var end = offset
    val stop = offset + FormatConstants.BLOCK_NAME_MAX_SIZE
    while (end < stop && bytes[end] != 0.toByte()) {
        end += 1
    }
    return bytes.copyOfRange(offset, end).toString(StandardCharsets.US_ASCII)
}

internal fun writeFixedName(bytes: ByteArray, offset: Int, name: String) {
    require(name.length <= FormatConstants.BLOCK_NAME_MAX_SIZE) { "name exceeds 14 bytes: $name" }
    repeat(FormatConstants.BLOCK_NAME_MAX_SIZE) { index ->
        bytes[offset + index] = 0
    }
    name.toByteArray(StandardCharsets.US_ASCII).copyInto(bytes, offset)
}

private fun readEntry(bytes: ByteArray, offset: Int): WireEntry {
    val isFile = (bytes[offset].toInt() and 0x01) == 1
    val name = readFixedName(bytes, offset + 1)
    val start = readU32LE(bytes, offset + 1 + FormatConstants.BLOCK_NAME_MAX_SIZE)
    val stop = readU32LE(bytes, offset + 1 + FormatConstants.BLOCK_NAME_MAX_SIZE + 4)
    val entryOffset = readU16LE(bytes, offset + 1 + FormatConstants.BLOCK_NAME_MAX_SIZE + 8)
    return WireEntry(isFile, name, start, stop, entryOffset)
}

private data class NodeAddress(
    val start: Int,
    val stop: Int,
    val offset: Int,
    val blockCount: Int,
)

private data class WireEntry(
    val isFile: Boolean,
    val name: String,
    val start: Int,
    val stop: Int,
    val offset: Int,
)
