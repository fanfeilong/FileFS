import Foundation

public struct DirEntry: Equatable, Sendable {
    public let type: DirEntryType
    public let name: String

    public init(type: DirEntryType, name: String) {
        self.type = type
        self.name = name
    }
}
