import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let shelfStoreDidChange = Notification.Name("DropFlowShelfStoreDidChange")
}

@MainActor
final class ShelfStore {
    private(set) var items: [ShelfItem] = []
    private(set) var recentSnapshots: [ShelfSnapshot] = []
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var dragMode: ShelfDragMode = .simplify

    private let maxSnapshots = 10
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let saveQueue = DispatchQueue(label: "com.dropflow.shelfstore.save", qos: .utility)
    private var pendingSave = false
    private var resolvedURLCache: [UUID: URL] = [:]

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() {
        do {
            let data = try Data(contentsOf: persistenceURL)
            let persisted = try decoder.decode(ShelfPersistence.self, from: data)
            items = persisted.activeItems.map(resolveState(for:))
            recentSnapshots = persisted.recentSnapshots.map { snapshot in
                var snapshot = snapshot
                snapshot.items = snapshot.items.map(resolveState(for:))
                return snapshot
            }
            invalidateURLCache()
            postChange(saveAfter: false)
        } catch {
            items = []
            recentSnapshots = []
        }
    }

    func save() {
        let supportURL = appSupportURL
        let fileURL = persistenceURL
        let persistence = ShelfPersistence(activeItems: items, recentSnapshots: recentSnapshots)
        let encoder = self.encoder
        saveQueue.async {
            do {
                try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
                let data = try encoder.encode(persistence)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                NSLog("DropFlow persistence error: \(error.localizedDescription)")
            }
        }
    }

    private func scheduleSave() {
        guard !pendingSave else { return }
        pendingSave = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.pendingSave = false
            self.save()
        }
    }

    func addItems(from pasteboard: NSPasteboard) {
        var newItems = PasteboardReader.readItems(from: pasteboard, imageDirectory: imageDirectoryURL)
        guard !newItems.isEmpty else { return }
        if newItems.count > 1 {
            let groupID = UUID()
            newItems = newItems.map { item in
                var item = item
                item.dropGroupID = groupID
                return item
            }
        }
        items.append(contentsOf: newItems.map(resolveState(for:)))
        invalidateURLCache()
        postChange()
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        selectedIDs.remove(item.id)
        resolvedURLCache.removeValue(forKey: item.id)
        postChange()
    }

    func remove(_ itemsToRemove: [ShelfItem]) {
        let ids = Set(itemsToRemove.map(\.id))
        items.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
        for id in ids { resolvedURLCache.removeValue(forKey: id) }
        postChange()
    }

    func clearShelf() {
        captureRecentSnapshotIfNeeded()
        items = []
        selectedIDs.removeAll()
        resolvedURLCache.removeAll()
        postChange()
    }

    func restore(snapshot: ShelfSnapshot) {
        captureRecentSnapshotIfNeeded()
        items = snapshot.items.map(resolveState(for:))
        selectedIDs.removeAll()
        recentSnapshots.removeAll { $0.id == snapshot.id }
        var reopened = snapshot
        reopened.lastOpenedAt = Date()
        recentSnapshots.insert(reopened, at: 0)
        trimSnapshots()
        invalidateURLCache()
        postChange()
    }

    func toggleSelection(for item: ShelfItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
        postChange(saveAfter: false)
    }

    func selectOnly(_ item: ShelfItem) {
        selectedIDs = [item.id]
        postChange(saveAfter: false)
    }

    func selectOnly(_ items: [ShelfItem]) {
        selectedIDs = Set(items.map(\.id))
        postChange(saveAfter: false)
    }

    func setDragMode(_ mode: ShelfDragMode) {
        guard dragMode != mode else { return }
        dragMode = mode
        postChange(saveAfter: false)
    }

    func itemsForDrag(startingWith item: ShelfItem) -> [ShelfItem] {
        let resolvedItems = items.filter { $0.lastResolvedState != .missing }
        switch dragMode {
        case .simplify:
            return resolvedItems
        case .advance:
            let selectedItems = resolvedItems.filter { selectedIDs.contains($0.id) }
            if selectedItems.contains(where: { $0.id == item.id }) {
                return selectedItems
            }
            return [item].filter { $0.lastResolvedState != .missing }
        }
    }

    func itemsForDrag(startingWith group: ShelfDisplayGroup) -> [ShelfItem] {
        switch dragMode {
        case .simplify:
            return items.filter { $0.lastResolvedState != .missing }
        case .advance:
            return group.items.filter { $0.lastResolvedState != .missing }
        }
    }

    func copyValue(for item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let url = resolveURL(for: item) {
            if item.isFileBacked {
                pasteboard.writeObjects([url as NSURL])
            } else {
                pasteboard.setString(url.absoluteString, forType: .string)
            }
            return
        }

        if let text = item.inlineText {
            pasteboard.setString(text, forType: .string)
        }
    }

    func copyValues(for itemsToCopy: [ShelfItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let urls = itemsToCopy.compactMap(resolveURL(for:))
        let fileURLs = urls.filter(\.isFileURL)
        if fileURLs.count == itemsToCopy.count {
            pasteboard.writeObjects(fileURLs.map { $0 as NSURL })
            return
        }

        let values = itemsToCopy.compactMap { item -> String? in
            if let url = resolveURL(for: item) {
                return item.isFileBacked ? url.path : url.absoluteString
            }
            return item.inlineText
        }
        pasteboard.setString(values.joined(separator: "\n"), forType: .string)
    }

    func displayGroups() -> [ShelfDisplayGroup] {
        var groupBuckets: [UUID: [ShelfItem]] = [:]
        for item in items {
            guard let groupID = item.dropGroupID else { continue }
            groupBuckets[groupID, default: []].append(item)
        }

        var groups: [ShelfDisplayGroup] = []
        groups.reserveCapacity(items.count)
        var consumedGroupIDs = Set<UUID>()

        for item in items {
            guard let groupID = item.dropGroupID else {
                groups.append(ShelfDisplayGroup(id: item.id, items: [item]))
                continue
            }
            guard !consumedGroupIDs.contains(groupID) else { continue }
            let bucket = groupBuckets[groupID] ?? [item]
            groups.append(ShelfDisplayGroup(id: groupID, items: bucket))
            consumedGroupIDs.insert(groupID)
        }

        return groups
    }

    func open(_ item: ShelfItem) {
        if let url = resolveURL(for: item) {
            NSWorkspace.shared.open(url)
        } else if let text = item.inlineText, let url = URL(string: text), url.scheme != nil {
            NSWorkspace.shared.open(url)
        }
    }

    func reveal(_ item: ShelfItem) {
        guard let url = resolveURL(for: item), url.isFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func zipSelectedOrAll() {
        let selectedItems = items.filter { selectedIDs.contains($0.id) && $0.isFileBacked }
        let fileItems = selectedItems.isEmpty ? items.filter(\.isFileBacked) : selectedItems
        let urls = fileItems.compactMap(resolveURL(for:)).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            do {
                let zipURL = try await ZipService.createZip(from: urls)
                NSWorkspace.shared.activateFileViewerSelecting([zipURL])
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    func captureRecentSnapshotIfNeeded() {
        guard !items.isEmpty else { return }
        let title = snapshotTitle(for: items)
        let snapshot = ShelfSnapshot(title: title, items: items)
        recentSnapshots.removeAll { $0.items.map(\.id) == items.map(\.id) }
        recentSnapshots.insert(snapshot, at: 0)
        trimSnapshots()
    }

    func resolveURL(for item: ShelfItem) -> URL? {
        if let cached = resolvedURLCache[item.id] {
            return cached
        }
        let resolved: URL?
        if let bookmarkData = item.bookmarkData {
            var stale = false
            resolved = (try? URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)) ?? item.sourceURL
        } else {
            resolved = item.sourceURL
        }
        if let resolved {
            resolvedURLCache[item.id] = resolved
        }
        return resolved
    }

    private func invalidateURLCache() {
        resolvedURLCache.removeAll(keepingCapacity: true)
    }

    func refreshResolvedStates() {
        invalidateURLCache()
        items = items.map(resolveState(for:))
        postChange()
    }

    private var appSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DropFlow", isDirectory: true)
    }

    private var persistenceURL: URL {
        appSupportURL.appendingPathComponent("shelf.json")
    }

    private var imageDirectoryURL: URL {
        appSupportURL.appendingPathComponent("Images", isDirectory: true)
    }

    private func resolveState(for item: ShelfItem) -> ShelfItem {
        var item = item
        if item.kind == .text || item.inlineText != nil {
            item.lastResolvedState = .inline
            return item
        }
        guard let url = resolveURL(for: item) else {
            item.lastResolvedState = .missing
            return item
        }
        if url.isFileURL {
            item.lastResolvedState = FileManager.default.fileExists(atPath: url.path) ? .resolved : .missing
        } else {
            item.lastResolvedState = .resolved
        }
        return item
    }

    private func snapshotTitle(for items: [ShelfItem]) -> String {
        if items.count == 1 {
            return items[0].displayName
        }
        return "\(items.count) items"
    }

    private func trimSnapshots() {
        recentSnapshots = Array(recentSnapshots.prefix(maxSnapshots))
    }

    private func postChange(saveAfter: Bool = true) {
        if saveAfter {
            scheduleSave()
        }
        NotificationCenter.default.post(name: .shelfStoreDidChange, object: self)
    }
}
