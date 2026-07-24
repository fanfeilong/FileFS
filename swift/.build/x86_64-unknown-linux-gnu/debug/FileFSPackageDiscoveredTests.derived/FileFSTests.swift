import XCTest
@testable import FileFSTests

fileprivate extension FileSystemTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__FileSystemTests = [
        ("testCopyRenameRemoveAndTransactionCommit", testCopyRenameRemoveAndTransactionCommit),
        ("testMkdirChdirWriteReadAndDirListing", testMkdirChdirWriteReadAndDirListing),
        ("testMkfsMountAndCwd", testMkfsMountAndCwd)
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __FileFSTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(FileSystemTests.__allTests__FileSystemTests)
    ]
}