import Foundation

public enum ShelfItemKind: String, Codable, Sendable {
    case file
    case folder
    case url
    case text
    case image
    case unknown

    public var label: String {
        switch self {
        case .file: "File"
        case .folder: "Folder"
        case .url: "URL"
        case .text: "Text"
        case .image: "Image"
        case .unknown: "Item"
        }
    }
}

public enum ShelfResolvedState: String, Codable, Sendable {
    case resolved
    case missing
    case inline
}

public enum ShelfDragMode: String, Sendable {
    case simplify
    case advance

    public var label: String {
        switch self {
        case .simplify: "Simplify"
        case .advance: "Advance"
        }
    }
}

public struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: ShelfItemKind
    public var displayName: String
    public var sourceURLString: String?
    public var bookmarkData: Data?
    public var inlineText: String?
    public var dropGroupID: UUID?
    public var createdAt: Date
    public var lastResolvedState: ShelfResolvedState

    public init(
        id: UUID = UUID(),
        kind: ShelfItemKind,
        displayName: String,
        sourceURL: URL? = nil,
        bookmarkData: Data? = nil,
        inlineText: String? = nil,
        dropGroupID: UUID? = nil,
        createdAt: Date = Date(),
        lastResolvedState: ShelfResolvedState = .resolved
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.sourceURLString = sourceURL?.absoluteString
        self.bookmarkData = bookmarkData
        self.inlineText = inlineText
        self.dropGroupID = dropGroupID
        self.createdAt = createdAt
        self.lastResolvedState = lastResolvedState
    }

    public var sourceURL: URL? {
        sourceURLString.flatMap(URL.init(string:))
    }

    public var isFileBacked: Bool {
        switch kind {
        case .file, .folder, .image:
            return sourceURL?.isFileURL == true
        case .url, .text, .unknown:
            return false
        }
    }
}

public struct ShelfSnapshot: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var items: [ShelfItem]
    public var createdAt: Date
    public var lastOpenedAt: Date

    public init(id: UUID = UUID(), title: String, items: [ShelfItem], createdAt: Date = Date(), lastOpenedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.items = items
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}

public struct ShelfPersistence: Codable, Sendable {
    public var activeItems: [ShelfItem]
    public var recentSnapshots: [ShelfSnapshot]
}

public struct ShelfDisplayGroup: Identifiable, Sendable {
    public var id: UUID
    public var items: [ShelfItem]

    public var isStack: Bool {
        items.count > 1
    }
}
