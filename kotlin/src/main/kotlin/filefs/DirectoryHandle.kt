package filefs

class DirectoryHandle internal constructor(
    internal val entries: List<DirEntry>,
    private val path: String,
) : AutoCloseable {
    internal var index: Int = 0
    var isOpen: Boolean = true
        private set

    fun absolutePath(): String = path

    override fun close() {
        isOpen = false
    }
}
