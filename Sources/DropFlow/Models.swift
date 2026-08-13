import Foundation

enum ShelfItemKind: String, Codable, CaseIterable {
    case file
    case folder
    case url
    case text
    case image
    case unknown

    var label: String {
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

enum ShelfResolvedState: String, Codable {
    case resolved
    case missing
    case inline
}

enum ShelfDragMode: String {
    case simplify
    case advance

    var label: String {
        switch self {
        case .simplify: "Simplify"
        case .advance: "Advance"
        }
    }
}

struct ShelfItem: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: ShelfItemKind
    var displayName: String
    var sourceURLString: String?
    var bookmarkData: Data?
    var inlineText: String?
    var dropGroupID: UUID?
    var createdAt: Date
    var lastResolvedState: ShelfResolvedState

    init(
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

    var sourceURL: URL? {
        sourceURLString.flatMap(URL.init(string:))
    }

    var isFileBacked: Bool {
        switch kind {
        case .file, .folder, .image:
            return sourceURL?.isFileURL == true
        case .url, .text, .unknown:
            return false
        }
    }
}

struct ShelfSnapshot: Codable, Identifiable {
    var id: UUID
    var title: String
    var items: [ShelfItem]
    var createdAt: Date
    var lastOpenedAt: Date

    init(id: UUID = UUID(), title: String, items: [ShelfItem], createdAt: Date = Date(), lastOpenedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.items = items
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}

struct ShelfPersistence: Codable {
    var activeItems: [ShelfItem]
    var recentSnapshots: [ShelfSnapshot]
}

struct ShelfDisplayGroup: Identifiable {
    var id: UUID
    var items: [ShelfItem]

    var isStack: Bool {
        items.count > 1
    }
}
