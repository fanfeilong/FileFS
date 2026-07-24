package filefs

import filefs.internal.DirNode
import filefs.internal.FileNode
import filefs.internal.FormatConstants
import filefs.internal.SerializedImage
import filefs.internal.TreeCopy
import filefs.internal.buildAbsolutePath
import filefs.internal.deepCopyTree
import filefs.internal.listDirectoryEntries
import filefs.internal.parseTree
import filefs.internal.readFixedName
import filefs.internal.readU32LE
import filefs.internal.serializeTree
import filefs.internal.writeBytes
import filefs.internal.writeFixedName
import filefs.internal.writeU16LE
import filefs.internal.writeU32LE
import java.io.EOFException
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.Path

class FileSystem : AutoCloseable {
    companion object {
        fun mkfs(path: Path) {
            try {
                path.toAbsolutePath().parent?.let(Files::createDirectories)
                RandomAccessFile(path.toFile(), "rw").use { file ->
                    file.setLength(0L)
                    val image = serializeTree(DirNode(name = "", parent = null))
                    writeImage(file, image)
                }
                Files.deleteIfExists(journalPathFor(path))
            } catch (e: IOException) {
                throw FileFsException("mkfs failed for $path", e)
            }
        }

        private fun writeImage(file: RandomAccessFile, image: SerializedImage) {
            file.setLength(image.blocks.size.toLong() * FormatConstants.BLOCK_SIZE)
            for ((index, block) in image.blocks.withIndex()) {
                file.seek(index.toLong() * FormatConstants.BLOCK_SIZE)
                file.write(block)
            }
            file.fd.sync()
        }

        private fun journalPathFor(imagePath: Path): Path = Path.of(imagePath.toString() + "-j")
    }

    private var imagePath: Path? = null
    private var journalPath: Path? = null
    private var file: RandomAccessFile? = null

    private var committedRoot: DirNode? = null
    private var committedCwd: DirNode? = null
    private var committedCwdPath: String = ""

    private var transaction: TransactionState? = null

    private val fileHandles = LinkedHashSet<FileHandle>()
    private val dirHandles = LinkedHashSet<DirectoryHandle>()

    val isMounted: Boolean
        get() = file != null

    fun mount(path: Path) {
        try {
            val newFile = RandomAccessFile(path.toFile(), "rw")
            try {
                validateHeader(newFile)
                validateRoot(newFile)
                umount()
                file = newFile
                imagePath = path
                journalPath = journalPathFor(path)
                applyJournal()
                val root = readTreeFromDisk()
                committedRoot = root
                committedCwd = root
                committedCwdPath = "/"
                transaction = null
            } catch (e: IOException) {
                newFile.close()
                throw e
            } catch (e: IllegalArgumentException) {
                newFile.close()
                throw IOException(e.message, e)
            }
        } catch (e: IOException) {
            throw FileFsException("mount failed for $path", e)
        }
    }

    fun umount() {
        closeAllHandles()
        try {
            file?.close()
        } catch (_: IOException) {
        }
        file = null
        imagePath = null
        transaction = null
        committedRoot = null
        committedCwd = null
        committedCwdPath = ""
        journalPath?.let {
            try {
                Files.deleteIfExists(it)
            } catch (_: IOException) {
            }
        }
        journalPath = null
    }

    fun open(path: String, mode: String): FileHandle {
        requireMounted()
        val leaf = resolveLeaf(path)
        val parent = leaf.parent
        val existing = parent.children[leaf.name]

        val node = when (mode) {
            "r", "r+" -> existing as? FileNode ?: throw FileFsException("open failed: $path")
            "w", "w+" -> {
                val fileNode = when (existing) {
                    null -> FileNode(leaf.name, parent)
                    is FileNode -> existing
                    else -> throw FileFsException("open failed: $path")
                }
                fileNode.data = ByteArray(0)
                parent.children[leaf.name] = fileNode
                persistIfAuto()
                fileNode
            }

            "a", "a+" -> {
                val fileNode = when (existing) {
                    null -> FileNode(leaf.name, parent)
                    is FileNode -> existing
                    else -> throw FileFsException("open failed: $path")
                }
                parent.children[leaf.name] = fileNode
                persistIfAuto()
                fileNode
            }

            else -> throw FileFsException("unsupported mode: $mode")
        }

        val position = if (mode.startsWith("a")) node.data.size else 0
        return FileHandle(node, mode, position).also { fileHandles += it }
    }

    fun read(file: FileHandle, buffer: ByteArray, offset: Int = 0, length: Int = buffer.size - offset): Int {
        requireMounted()
        if (!file.isOpen || offset < 0 || length <= 0 || offset + length > buffer.size) {
            return 0
        }
        if (file.mode == "w" || file.mode == "a") {
            return 0
        }

        val remaining = file.node.data.size - file.position
        if (remaining <= 0) {
            return 0
        }

        val count = minOf(length, remaining)
        file.node.data.copyInto(buffer, offset, file.position, file.position + count)
        file.position += count
        return count
    }

    fun write(file: FileHandle, buffer: ByteArray, offset: Int = 0, length: Int = buffer.size - offset): Int {
        requireMounted()
        if (!file.isOpen || offset < 0 || length <= 0 || offset + length > buffer.size) {
            return 0
        }
        if (file.mode == "r") {
            return 0
        }

        val endPosition = file.position + length
        val current = file.node.data
        val newSize = maxOf(current.size, endPosition)
        val updated = ByteArray(newSize)
        current.copyInto(updated)
        buffer.copyInto(updated, file.position, offset, offset + length)
        file.node.data = updated
        file.position = endPosition
        persistIfAuto()
        return length
    }

    fun close(file: FileHandle) {
        file.close()
    }

    fun seek(file: FileHandle, offset: Long, whence: SeekWhence): Boolean {
        requireMounted()
        if (!file.isOpen) {
            return false
        }

        val size = file.node.data.size.toLong()
        val target = when (whence) {
            SeekWhence.SET -> offset
            SeekWhence.CUR -> file.position.toLong() + offset
            SeekWhence.END -> size + offset
        }

        file.position = target.coerceIn(0L, size).toInt()
        return true
    }

    fun tell(file: FileHandle): Long {
        requireMounted()
        return if (file.isOpen) file.position.toLong() else 0L
    }

    fun rewind(file: FileHandle) {
        seek(file, 0L, SeekWhence.SET)
    }

    fun fileExists(path: String): Boolean = resolveNodeOrNull(path) is FileNode

    fun dirExists(path: String): Boolean = resolveNodeOrNull(path) is DirNode

    fun removeFile(path: String) {
        val leaf = resolveLeaf(path)
        when (val node = leaf.parent.children[leaf.name]) {
            is FileNode -> {
                leaf.parent.children.remove(leaf.name)
                persistIfAuto()
            }

            else -> throw FileFsException("removeFile failed path=$path")
        }
    }

    fun rename(from: String, to: String) {
        moveOrRename(from, to)
    }

    fun move(from: String, toDir: String) {
        val sourceLeaf = resolveLeaf(from)
        val sourceNode = sourceLeaf.parent.children[sourceLeaf.name] ?: throw FileFsException("move failed: $from")
        val targetDir = resolveNodeOrNull(toDir) as? DirNode ?: throw FileFsException("move failed: $toDir")
        moveNode(sourceNode, targetDir, sourceNode.name)
    }

    fun copyFile(from: String, to: String) {
        val source = resolveNodeOrNull(from) as? FileNode ?: throw FileFsException("copyFile failed from=$from")
        val leaf = resolveLeaf(to)
        if (leaf.parent.children.containsKey(leaf.name)) {
            throw FileFsException("copyFile failed to=$to")
        }
        leaf.parent.children[leaf.name] = FileNode(leaf.name, leaf.parent, source.data.copyOf())
        persistIfAuto()
    }

    fun chdir(path: String) {
        val dir = resolveNodeOrNull(path) as? DirNode ?: throw FileFsException("chdir failed: $path")
        if (transaction == null) {
            committedCwd = dir
            committedCwdPath = buildAbsolutePath(dir)
        } else {
            transaction?.cwd = dir
            transaction?.cwdPath = buildAbsolutePath(dir)
        }
    }

    fun getcwd(): String = transaction?.cwdPath ?: committedCwdPath

    fun mkdir(path: String) {
        val leaf = resolveLeaf(path)
        if (leaf.parent.children.containsKey(leaf.name)) {
            throw FileFsException("mkdir failed path=$path")
        }
        leaf.parent.children[leaf.name] = DirNode(leaf.name, leaf.parent)
        persistIfAuto()
    }

    fun rmdir(path: String) {
        val leaf = resolveLeaf(path)
        val dir = leaf.parent.children[leaf.name] as? DirNode ?: throw FileFsException("rmdir failed path=$path")
        if (dir.children.isNotEmpty()) {
            throw FileFsException("rmdir failed path=$path")
        }
        if (dir.parent == null || isSameOrAncestor(dir, currentCwd())) {
            throw FileFsException("rmdir failed path=$path")
        }
        leaf.parent.children.remove(leaf.name)
        persistIfAuto()
    }

    fun openDir(path: String): DirectoryHandle {
        requireMounted()
        val dir = resolveNodeOrNull(path) as? DirNode ?: throw FileFsException("openDir failed: $path")
        return DirectoryHandle(
            entries = listDirectoryEntries(dir),
            path = buildAbsolutePath(dir),
        ).also { dirHandles += it }
    }

    fun readDir(dir: DirectoryHandle): DirEntry? {
        requireMounted()
        if (!dir.isOpen || dir.index >= dir.entries.size) {
            return null
        }
        return dir.entries[dir.index++]
    }

    fun closeDir(dir: DirectoryHandle) {
        dir.close()
    }

    fun begin(): Boolean {
        if (!isMounted) {
            return false
        }
        rollback()
        val root = committedRoot ?: return false
        val cwd = committedCwd ?: root
        val copy: TreeCopy = deepCopyTree(root, cwd)
        transaction = TransactionState(
            root = copy.root,
            cwd = copy.cwd,
            cwdPath = buildAbsolutePath(copy.cwd),
        )
        return true
    }

    fun commit(): Boolean {
        if (!isMounted) {
            return true
        }
        val tx = transaction ?: return true
        return try {
            persistTree(tx.root)
            committedRoot = tx.root
            committedCwd = tx.cwd
            committedCwdPath = tx.cwdPath
            transaction = null
            true
        } catch (_: IOException) {
            false
        }
    }

    fun rollback() {
        if (!isMounted) {
            return
        }
        closeAllHandles()
        transaction = null
        journalPath?.let {
            try {
                Files.deleteIfExists(it)
            } catch (_: IOException) {
            }
        }
    }

    override fun close() = umount()

    private fun moveOrRename(from: String, to: String) {
        val sourceLeaf = resolveLeaf(from)
        val sourceNode = sourceLeaf.parent.children[sourceLeaf.name] ?: throw FileFsException("rename failed from=$from")
        val destinationLeaf = resolveLeaf(to)
        moveNode(sourceNode, destinationLeaf.parent, destinationLeaf.name)
    }

    private fun moveNode(node: filefs.internal.FsNode, newParent: DirNode, newName: String) {
        validateLeafName(newName)
        if (newParent.children.containsKey(newName)) {
            throw FileFsException("target already exists: $newName")
        }
        val oldParent = node.parent ?: throw FileFsException("cannot move root directory")
        if (node is DirNode && isSameOrAncestor(node, newParent)) {
            throw FileFsException("cannot move directory into itself")
        }
        oldParent.children.remove(node.name)
        node.name = newName
        node.parent = newParent
        newParent.children[newName] = node
        refreshWorkingDirectoryPath()
        persistIfAuto()
    }

    private fun isSameOrAncestor(candidate: DirNode, dir: DirNode): Boolean {
        var current: DirNode? = dir
        while (current != null) {
            if (current === candidate) {
                return true
            }
            current = current.parent
        }
        return false
    }

    private fun refreshWorkingDirectoryPath() {
        if (transaction == null) {
            committedCwd?.let { committedCwdPath = buildAbsolutePath(it) }
        } else {
            transaction?.cwd?.let { transaction?.cwdPath = buildAbsolutePath(it) }
        }
    }

    private fun persistIfAuto() {
        if (transaction == null) {
            try {
                persistTree(requireNotNull(committedRoot))
            } catch (e: IOException) {
                throw FileFsException("persist failed", e)
            }
        } else {
            refreshWorkingDirectoryPath()
        }
    }

    @Throws(IOException::class)
    private fun persistTree(root: DirNode) {
        val image = serializeTree(root)
        writeJournal(image)
        applyJournal(expectedBlocks = image.blocks.size)
    }

    @Throws(IOException::class)
    private fun writeJournal(image: SerializedImage) {
        val target = journalPath ?: throw IOException("journal path unavailable")
        RandomAccessFile(target.toFile(), "rw").use { journal ->
            journal.setLength(0L)
            journal.write(0)
            val indexBytes = ByteArray(4)
            for ((index, block) in image.blocks.withIndex()) {
                writeU32LE(indexBytes, 0, index)
                journal.write(indexBytes)
                journal.write(block)
            }
            journal.seek(0L)
            journal.write(0xFF)
            journal.fd.sync()
        }
    }

    @Throws(IOException::class)
    private fun applyJournal(expectedBlocks: Int? = null) {
        val target = journalPath ?: return
        if (!Files.exists(target)) {
            return
        }

        val currentFile = file ?: throw IOException("filesystem is not mounted")
        var maxIndex = -1
        try {
            RandomAccessFile(target.toFile(), "r").use { journal ->
                if (journal.read() != 0xFF) {
                    return
                }
                val indexBlock = ByteArray(4 + FormatConstants.BLOCK_SIZE)
                while (readExact(journal, indexBlock)) {
                    val index = readU32LE(indexBlock, 0)
                    currentFile.seek(index.toLong() * FormatConstants.BLOCK_SIZE)
                    currentFile.write(indexBlock, 4, FormatConstants.BLOCK_SIZE)
                    if (index > maxIndex) {
                        maxIndex = index
                    }
                }
                val blockCount = expectedBlocks ?: (maxIndex + 1)
                if (blockCount >= 0) {
                    currentFile.setLength(blockCount.toLong() * FormatConstants.BLOCK_SIZE)
                }
                currentFile.fd.sync()
            }
        } finally {
            Files.deleteIfExists(target)
        }
    }

    @Throws(IOException::class)
    private fun readTreeFromDisk(): DirNode {
        val currentFile = file ?: throw IOException("filesystem is not mounted")
        currentFile.seek(0L)
        val block0 = ByteArray(FormatConstants.BLOCK_SIZE)
        currentFile.readFully(block0)
        val totalBlocks = readU32LE(block0, 4)
        require(totalBlocks >= 2) { "invalid block count" }
        val blocks = MutableList(totalBlocks) { ByteArray(FormatConstants.BLOCK_SIZE) }
        blocks[0] = block0
        for (index in 1 until totalBlocks) {
            val block = ByteArray(FormatConstants.BLOCK_SIZE)
            currentFile.readFully(block)
            blocks[index] = block
        }
        return parseTree(blocks)
    }

    @Throws(IOException::class)
    private fun validateHeader(file: RandomAccessFile) {
        val block0 = ByteArray(FormatConstants.BLOCK_SIZE)
        file.seek(0L)
        file.readFully(block0)
        require(block0.copyOfRange(0, FormatConstants.MAGIC.size).contentEquals(FormatConstants.MAGIC)) {
            "invalid FileFS magic"
        }
        require(readU32LE(block0, 4) >= 2) { "invalid FileFS block count" }
    }

    @Throws(IOException::class)
    private fun validateRoot(file: RandomAccessFile) {
        val block1 = ByteArray(FormatConstants.BLOCK_SIZE)
        file.seek(FormatConstants.BLOCK_SIZE.toLong())
        file.readFully(block1)
        require(block1[FormatConstants.BLOCK_HEAD] == 0.toByte()) { "invalid root directory" }
        require(readFixedName(block1, FormatConstants.BLOCK_HEAD + 1) == ".") { "invalid root directory" }
        val dotDotOffset = FormatConstants.BLOCK_HEAD + FormatConstants.ENTRY_SIZE
        require(block1[dotDotOffset] == 0.toByte()) { "invalid root parent entry" }
        require(readFixedName(block1, dotDotOffset + 1) == "..") { "invalid root parent entry" }
    }

    private fun resolveNodeOrNull(path: String): filefs.internal.FsNode? {
        requireMounted()
        if (path.isEmpty()) {
            return null
        }

        val parsed = parsePath(path)
        var current = if (parsed.absolute) currentRoot() else currentCwd()
        if (parsed.parts.isEmpty()) {
            return current
        }

        for ((index, part) in parsed.parts.withIndex()) {
            when (part) {
                "." -> Unit
                ".." -> current = current.parent ?: current
                else -> {
                    val child = current.children[part] ?: return null
                    if (index < parsed.parts.lastIndex) {
                        current = child as? DirNode ?: return null
                    } else {
                        return child
                    }
                }
            }
        }
        return current
    }

    private fun resolveLeaf(path: String): ResolvedLeaf {
        requireMounted()
        val parsed = parsePath(path)
        if (parsed.parts.isEmpty()) {
            throw FileFsException("invalid path: $path")
        }

        val leafName = parsed.parts.last()
        validateLeafName(leafName)

        var current = if (parsed.absolute) currentRoot() else currentCwd()
        for (part in parsed.parts.dropLast(1)) {
            current = when (part) {
                "." -> current
                ".." -> current.parent ?: current
                else -> current.children[part] as? DirNode ?: throw FileFsException("path not found: $path")
            }
        }

        return ResolvedLeaf(current, leafName)
    }

    private fun validateLeafName(name: String) {
        if (name == "." || name == ".." || name.isEmpty()) {
            throw FileFsException("invalid leaf name: $name")
        }
        if (!name.all { it.code in 0x20..0x7E }) {
            throw FileFsException("name must be ASCII: $name")
        }
        if (name.length > FormatConstants.BLOCK_NAME_MAX_SIZE) {
            throw FileFsException("name exceeds 14 bytes: $name")
        }
    }

    private fun currentRoot(): DirNode = transaction?.root ?: requireNotNull(committedRoot)

    private fun currentCwd(): DirNode = transaction?.cwd ?: requireNotNull(committedCwd)

    private fun requireMounted() {
        if (!isMounted) {
            throw FileFsException("filesystem is not mounted")
        }
    }

    private fun closeAllHandles() {
        for (handle in fileHandles) {
            handle.close()
        }
        for (handle in dirHandles) {
            handle.close()
        }
        fileHandles.clear()
        dirHandles.clear()
    }

    private fun parsePath(path: String): ParsedPath {
        if (path.isEmpty()) {
            throw FileFsException("path is required")
        }
        val absolute = path.startsWith('/')
        val parts = path.split('/').filter { it.isNotEmpty() }
        return ParsedPath(absolute, parts)
    }

    private fun readExact(file: RandomAccessFile, buffer: ByteArray): Boolean {
        return try {
            file.readFully(buffer)
            true
        } catch (_: EOFException) {
            false
        }
    }

    private data class ParsedPath(
        val absolute: Boolean,
        val parts: List<String>,
    )

    private data class ResolvedLeaf(
        val parent: DirNode,
        val name: String,
    )

    private data class TransactionState(
        var root: DirNode,
        var cwd: DirNode,
        var cwdPath: String,
    )
}
