import Foundation

public enum FileFSError: Error, Equatable, LocalizedError {
    case notMounted
    case invalidPath(String)
    case invalidMode(String)
    case notFound(String)
    case alreadyExists(String)
    case notAFile(String)
    case notADirectory(String)
    case nameTooLong(String)
    case directoryNotEmpty(String)
    case invalidFormat(String)
    case ioError(String)
    case transactionError(String)

    public var errorDescription: String? {
        switch self {
        case .notMounted:
            return "FileFS image is not mounted."
        case let .invalidPath(path):
            return "Invalid path: \(path)"
        case let .invalidMode(mode):
            return "Invalid open mode: \(mode)"
        case let .notFound(path):
            return "Path not found: \(path)"
        case let .alreadyExists(path):
            return "Path already exists: \(path)"
        case let .notAFile(path):
            return "Path is not a file: \(path)"
        case let .notADirectory(path):
            return "Path is not a directory: \(path)"
        case let .nameTooLong(name):
            return "Name exceeds 14 bytes: \(name)"
        case let .directoryNotEmpty(path):
            return "Directory is not empty: \(path)"
        case let .invalidFormat(message):
            return "Invalid FileFS format: \(message)"
        case let .ioError(message):
            return "I/O error: \(message)"
        case let .transactionError(message):
            return "Transaction error: \(message)"
        }
    }
}
