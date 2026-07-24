import Foundation

public enum SeekWhence: Sendable {
    case set
    case current
    case end
}

public enum DirEntryType: Int, Sendable {
    case file = 0
    case directory = 1
    case root = 2
}
