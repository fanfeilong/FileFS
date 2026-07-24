package filefs

import filefs.internal.FileNode

class FileHandle internal constructor(
    internal val node: FileNode,
    internal val mode: String,
    internal var position: Int,
) : AutoCloseable {
    var isOpen: Boolean = true
        private set

    override fun close() {
        isOpen = false
    }
}
