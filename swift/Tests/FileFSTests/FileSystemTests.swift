import XCTest
@testable import FileFS

final class FileSystemTests: XCTestCase {
    func testMkfsMountAndCwd() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imagePath = tempDir.appendingPathComponent("test.ffs").path
        try FileSystem.mkfs(at: imagePath)

        let fs = FileSystem()
        try fs.mount(at: imagePath)
        defer { fs.umount() }

        XCTAssertTrue(fs.isMounted)
        XCTAssertEqual(fs.getcwd(), "/")
    }

    func testMkdirChdirWriteReadAndDirListing() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imagePath = tempDir.appendingPathComponent("test.ffs").path
        try FileSystem.mkfs(at: imagePath)

        let fs = FileSystem()
        try fs.mount(at: imagePath)
        defer { fs.umount() }

        try fs.mkdir("docs")
        try fs.chdir("docs")
        XCTAssertEqual(fs.getcwd(), "/docs/")

        let writer = try fs.open("note.txt", mode: "w")
        let payload = Array("hello filefs".utf8)
        XCTAssertEqual(try fs.write(writer, from: payload), payload.count)
        fs.close(writer)

        let reader = try fs.open("note.txt", mode: "r")
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = try fs.read(reader, into: &buffer)
        fs.close(reader)
        XCTAssertEqual(Array(buffer.prefix(count)), payload)

        try fs.chdir("/")
        let dir = try fs.openDir("/")
        var names = Set<String>()
        while let entry = fs.readDir(dir) {
            names.insert(entry.name)
        }
        fs.closeDir(dir)

        XCTAssertTrue(names.contains("docs"))
    }

    func testCopyRenameRemoveAndTransactionCommit() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let imagePath = tempDir.appendingPathComponent("test.ffs").path
        try FileSystem.mkfs(at: imagePath)

        let fs = FileSystem()
        try fs.mount(at: imagePath)
        defer { fs.umount() }

        try fs.mkdir("/docs")
        let writer = try fs.open("/docs/note.txt", mode: "w")
        XCTAssertEqual(try fs.write(writer, from: Array("copy me".utf8)), 7)
        fs.close(writer)

        try fs.copyFile(from: "/docs/note.txt", to: "/copy.txt")
        XCTAssertTrue(fs.fileExists("/copy.txt"))

        try fs.rename(from: "/copy.txt", to: "/renamed.txt")
        XCTAssertTrue(fs.fileExists("/renamed.txt"))
        XCTAssertFalse(fs.fileExists("/copy.txt"))

        try fs.removeFile("/renamed.txt")
        XCTAssertFalse(fs.fileExists("/renamed.txt"))

        try fs.begin()
        let txnWriter = try fs.open("/txn.txt", mode: "w")
        XCTAssertEqual(try fs.write(txnWriter, from: [0x78]), 1)
        fs.close(txnWriter)
        try fs.commit()

        XCTAssertTrue(fs.fileExists("/txn.txt"))

        fs.umount()
        try fs.mount(at: imagePath)
        XCTAssertTrue(fs.fileExists("/txn.txt"))
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
