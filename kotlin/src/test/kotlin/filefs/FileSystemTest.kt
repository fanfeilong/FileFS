package filefs

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path

private fun assertTrue(condition: Boolean, message: String) {
    if (!condition) {
        throw AssertionError(message)
    }
}

private fun assertFalse(condition: Boolean, message: String) {
    assertTrue(!condition, message)
}

private fun assertEquals(expected: Any?, actual: Any?, message: String) {
    if (expected != actual) {
        throw AssertionError("$message expected=<$expected> actual=<$actual>")
    }
}

private fun assertNotNull(value: Any?, message: String) {
    if (value == null) {
        throw AssertionError(message)
    }
}

private class ImageFixture(name: String) : AutoCloseable {
    val imagePath: Path = Files.createTempFile("filefs-kotlin-$name-", ".ffs").also {
        Files.deleteIfExists(it)
    }
    val fs = FileSystem()

    init {
        FileSystem.mkfs(imagePath)
        fs.mount(imagePath)
    }

    override fun close() {
        fs.umount()
        Files.deleteIfExists(imagePath)
        Files.deleteIfExists(Path.of(imagePath.toString() + "-j"))
    }
}

private fun mkfsMountAndGetcwd() {
    ImageFixture("lifecycle").use { fixture ->
        assertTrue(fixture.fs.isMounted, "filesystem should be mounted")
        assertEquals("/", fixture.fs.getcwd(), "cwd should be root")
    }
}

private fun mkdirAndChdir() {
    ImageFixture("mkdir").use { fixture ->
        fixture.fs.mkdir("docs")
        fixture.fs.chdir("docs")
        assertEquals("/docs/", fixture.fs.getcwd(), "cwd should change to docs")
    }
}

private fun openWriteReadRoundtrip() {
    ImageFixture("roundtrip").use { fixture ->
        fixture.fs.mkdir("docs")
        fixture.fs.chdir("docs")

        val out = fixture.fs.open("note.txt", "w")
        val payload = "hello filefs".toByteArray(StandardCharsets.UTF_8)
        assertEquals(payload.size, fixture.fs.write(out, payload), "write should persist payload")
        fixture.fs.close(out)

        val input = fixture.fs.open("note.txt", "r")
        assertTrue(fixture.fs.seek(input, 0L, SeekWhence.END), "seek to end should succeed")
        assertEquals(payload.size.toLong(), fixture.fs.tell(input), "tell should report payload length")
        fixture.fs.rewind(input)

        val buffer = ByteArray(64)
        val count = fixture.fs.read(input, buffer)
        fixture.fs.close(input)

        assertEquals("hello filefs", String(buffer, 0, count, StandardCharsets.UTF_8), "roundtrip should match")
    }
}

private fun copyRenameAndRemove() {
    ImageFixture("copy").use { fixture ->
        val out = fixture.fs.open("orig.txt", "w")
        val payload = "copy me".toByteArray(StandardCharsets.UTF_8)
        assertEquals(payload.size, fixture.fs.write(out, payload), "write should persist source file")
        fixture.fs.close(out)

        fixture.fs.copyFile("orig.txt", "copy.txt")
        fixture.fs.rename("copy.txt", "renamed.txt")
        assertTrue(fixture.fs.fileExists("renamed.txt"), "renamed file should exist")
        fixture.fs.removeFile("renamed.txt")
        assertFalse(fixture.fs.fileExists("renamed.txt"), "removed file should not exist")
    }
}

private fun openDirListsDocs() {
    ImageFixture("readdir").use { fixture ->
        fixture.fs.mkdir("docs")
        val dir = fixture.fs.openDir("/")
        assertNotNull(dir, "directory handle should exist")
        assertEquals("/", dir.absolutePath(), "absolute path should be root")

        var foundDocs = false
        while (true) {
            val entry = fixture.fs.readDir(dir) ?: break
            if (entry.name == "docs" && entry.type == FileType.DIR) {
                foundDocs = true
            }
        }
        fixture.fs.closeDir(dir)
        assertTrue(foundDocs, "docs directory should be listed")
    }
}

private fun beginCommitCreatesFile() {
    ImageFixture("txn").use { fixture ->
        assertTrue(fixture.fs.begin(), "begin should succeed")
        val out = fixture.fs.open("txn.txt", "w")
        val payload = byteArrayOf('x'.code.toByte())
        assertEquals(1, fixture.fs.write(out, payload), "transactional write should succeed")
        fixture.fs.close(out)
        assertTrue(fixture.fs.commit(), "commit should succeed")
        assertTrue(fixture.fs.fileExists("txn.txt"), "committed file should exist")
    }
}

fun main() {
    val tests = listOf(
        "mkfsMountAndGetcwd" to ::mkfsMountAndGetcwd,
        "mkdirAndChdir" to ::mkdirAndChdir,
        "openWriteReadRoundtrip" to ::openWriteReadRoundtrip,
        "copyRenameAndRemove" to ::copyRenameAndRemove,
        "openDirListsDocs" to ::openDirListsDocs,
        "beginCommitCreatesFile" to ::beginCommitCreatesFile,
    )

    for ((name, test) in tests) {
        test()
        println("PASS $name")
    }
    println("PASS ${tests.size} tests")
}
