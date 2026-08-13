import AppKit

extension Notification.Name {
    static let shelfStoreDidChange = Notification.Name("DropFlowShelfStoreDidChange")
}

@MainActor
final class ShelfStore {
    private(set) var items: [ShelfItem] = []
    private(set) var recentSnapshots: [ShelfSnapshot] = []
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var dragMode: ShelfDragMode = .simplify

    private static let dragModeDefaultsKey = "ShelfDragMode"

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
        dragMode = ShelfDragMode(rawValue: UserDefaults.standard.string(forKey: Self.dragModeDefaultsKey) ?? "") ?? .simplify
    }

    func load() {
        do {
            let data = try Data(contentsOf: persistenceURL)
            let persisted = try decoder.decode(ShelfPersistence.self, from: data)
            items = persisted.activeItems.map(resolveState(for:))
            // Snapshot items are deliberately NOT resolved here: this runs as the first statement of
            // applicationDidFinishLaunching, before anything is on screen, and resolving up to 10
            // snapshots' bookmarks blocks the main thread. Nothing needs it — the menu reads only
            // .title/.id and restore(snapshot:) resolves then.
            recentSnapshots = persisted.recentSnapshots
            invalidateURLCache()
            sweepOrphanedImages()
            postChange(saveAfter: false)
        } catch {
            // A load failure must never reach the point where the next save overwrites the file: this
            // is the only copy of the shelf plus all 10 snapshots. Move it aside instead, so a schema
            // change in a shipped update is recoverable from disk rather than silently fatal. Note
            // there is no postChange() here — nothing schedules a save from this path.
            let missing = (error as? CocoaError)?.code == .fileReadNoSuchFile
                || !FileManager.default.fileExists(atPath: persistenceURL.path)
            if !missing {
                let aside = persistenceURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
                NSLog("DropFlow could not read shelf.json (\(error)); preserving it at \(aside.lastPathComponent)")
                try? FileManager.default.moveItem(at: persistenceURL, to: aside)
            }
            items = []
            recentSnapshots = []
        }
    }

    /// Nothing else in the app ever deletes from Images/, so every pasted screenshot stays forever.
    /// Safe only after a successful load: on a failed load `items` is empty and this would delete every
    /// image the user still has. Backing files are intentionally not deleted by remove()/clearShelf() —
    /// those items live on in recentSnapshots and Restore has to keep working.
    private func sweepOrphanedImages() {
        // ponytail: `live` is a launch-time snapshot, so a drop landing mid-sweep could lose its image.
        // The window is the few milliseconds before any UI exists. Upgrade: skip files newer than launch.
        let live = Set((items + recentSnapshots.flatMap(\.items)).compactMap(\.sourceURL).map(\.lastPathComponent))
        let directory = imageDirectoryURL
        saveQueue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where !live.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
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

    /// Enqueues a save and waits for it to land. Use at quit: `save()` alone returns before the
    /// write happens, so the process can exit first — two 0-byte atomic-write sidecars in the
    /// support directory are writes that started this way and never finished.
    func saveNow() {
        save()
        saveQueue.sync {}
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
        // PasteboardReader de-dupes only within one drop, so dropping the same file again tomorrow
        // added a second identical row. Same key it uses.
        let existingKeys = Set(items.map(dedupeKey(for:)))
        newItems = newItems.filter { !existingKeys.contains(dedupeKey(for: $0)) }
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

    private func dedupeKey(for item: ShelfItem) -> String {
        item.sourceURLString ?? item.inlineText ?? item.id.uuidString
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
        // Kept out of shelf.json on purpose: a new non-optional field in ShelfPersistence would make
        // synthesized Codable throw keyNotFound on every existing user's file (defaults are ignored).
        UserDefaults.standard.set(mode.rawValue, forKey: Self.dragModeDefaultsKey)
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
        var fileURL: URL?
        var text: String?
        if let url = resolveURL(for: item) {
            if item.isFileBacked {
                fileURL = url
            } else {
                text = url.absoluteString
            }
        } else {
            text = item.inlineText
        }

        // Compute the payload first, clear last: clearing up front wiped whatever the user had copied
        // before whenever the item resolved to nothing, and then wrote nothing in its place.
        guard fileURL != nil || text != nil else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let fileURL {
            pasteboard.writeObjects([fileURL as NSURL])
        }
        if let text {
            pasteboard.setString(text, forType: .string)
        }
    }

    func copyValues(for itemsToCopy: [ShelfItem]) {
        var fileURLs: [NSURL] = []
        var texts: [String] = []
        for item in itemsToCopy {
            if let url = resolveURL(for: item) {
                if url.isFileURL {
                    fileURLs.append(url as NSURL)
                } else {
                    texts.append(url.absoluteString)
                }
            } else if let text = item.inlineText {
                texts.append(text)
            }
        }

        // A mixed selection used to collapse to one representation, so pasting into Finder lost the files
        // or pasting into an editor lost the text. Write both flavours onto the one pasteboard; setString
        // after writeObjects replaces the string flavour NSURL declares, which is what we want here.
        guard !fileURLs.isEmpty || !texts.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !fileURLs.isEmpty {
            pasteboard.writeObjects(fileURLs)
        }
        if !texts.isEmpty {
            pasteboard.setString(texts.joined(separator: "\n"), forType: .string)
        }
    }

    /// Breaks a multi-file drop back into ordinary rows: `displayGroups()` then emits them individually and
    /// every existing per-item behaviour applies unchanged.
    func ungroup(_ group: ShelfDisplayGroup) {
        let ids = Set(group.items.map(\.id))
        guard items.contains(where: { ids.contains($0.id) && $0.dropGroupID != nil }) else { return }
        items = items.map { item in
            guard ids.contains(item.id) else { return item }
            var item = item
            item.dropGroupID = nil
            return item
        }
        postChange()
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
            // The memo lives for the whole process, so a file moved or deleted after it was cached kept
            // resolving to a path that no longer exists. Re-resolve from the bookmark in that case.
            if !cached.isFileURL || FileManager.default.fileExists(atPath: cached.path) {
                return cached
            }
            resolvedURLCache.removeValue(forKey: item.id)
        }
        let resolved: URL?
        if let bookmarkData = item.bookmarkData {
            var stale = false
            resolved = resolveBookmark(bookmarkData, stale: &stale) ?? item.sourceURL
        } else {
            resolved = item.sourceURL
        }
        if let resolved {
            resolvedURLCache[item.id] = resolved
        }
        return resolved
    }

    private func resolveBookmark(_ data: Data, stale: inout Bool) -> URL? {
        // .withoutMounting: with an empty option set macOS tries to remount an unplugged volume rather
        // than failing fast, which turns a cold launch into a multi-second freeze.
        try? URL(resolvingBookmarkData: data, options: [.withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func invalidateURLCache() {
        resolvedURLCache.removeAll(keepingCapacity: true)
    }

    func refreshResolvedStates() {
        invalidateURLCache()
        items = items.map { resolveState(for: followMovedFile($0)) }
        postChange()
    }

    /// A stale bookmark still resolves — to the file's new location — so copy that location back onto the
    /// item. Without this the persisted path and name never follow a file the user moved and the row keeps
    /// showing the old name. Deliberately not done inside `resolveURL`: that runs during
    /// `items = persisted.activeItems.map(...)` in `load()`, where a write to `items` would be discarded
    /// by the assignment that follows.
    private func followMovedFile(_ item: ShelfItem) -> ShelfItem {
        guard let bookmarkData = item.bookmarkData else { return item }
        var stale = false
        guard let url = resolveBookmark(bookmarkData, stale: &stale), stale else { return item }
        var item = item
        item.sourceURLString = url.absoluteString
        if let name = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName, !name.isEmpty {
            item.displayName = name
        }
        if let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            item.bookmarkData = refreshed
        }
        return item
    }

    private var appSupportURL: URL {
        // DROPFLOW_SUPPORT_DIR exists so a test harness can point persistence somewhere disposable.
        // Setting HOME is NOT enough: -[NSFileManager URLsForDirectory:] resolves the home directory
        // through the password database, so a harness that only overrides HOME writes straight into
        // the real ~/Library/Application Support/DropFlow and destroys the user's shelf.
        if let override = ProcessInfo.processInfo.environment["DROPFLOW_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
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
