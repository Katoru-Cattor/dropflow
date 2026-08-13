import AppKit
import UniformTypeIdentifiers

enum PasteboardReader {
    static func readItems(from pasteboard: NSPasteboard, imageDirectory: URL) -> [ShelfItem] {
        var results: [ShelfItem] = []
        let items = pasteboard.pasteboardItems ?? []

        for item in items {
            if let fileItem = readFileURL(from: item) {
                results.append(fileItem)
                continue
            }

            if let urlItem = readWebURL(from: item) {
                results.append(urlItem)
                continue
            }

            if let imageItem = readImage(from: item, imageDirectory: imageDirectory) {
                results.append(imageItem)
                continue
            }

            if let textItem = readText(from: item) {
                results.append(textItem)
            }
        }

        if results.isEmpty, let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String] {
            results.append(contentsOf: strings.map(makeTextItem))
        }

        return uniqued(results)
    }

    private static func readFileURL(from item: NSPasteboardItem) -> ShelfItem? {
        guard let string = item.string(forType: .fileURL), let url = URL(string: string) else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .localizedNameKey])
        let isDirectory = values?.isDirectory == true
        let displayName = values?.localizedName ?? url.lastPathComponent
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return ShelfItem(
            kind: isDirectory ? .folder : .file,
            displayName: displayName.isEmpty ? url.path : displayName,
            sourceURL: url,
            bookmarkData: bookmark,
            lastResolvedState: .resolved
        )
    }

    private static func readWebURL(from item: NSPasteboardItem) -> ShelfItem? {
        let candidates = [
            item.string(forType: .URL),
            item.string(forType: NSPasteboard.PasteboardType("public.url")),
            item.string(forType: .string)
        ]

        guard let raw = candidates.compactMap({ $0 }).first,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme,
              !scheme.isEmpty,
              !url.isFileURL
        else { return nil }

        let title = item.string(forType: NSPasteboard.PasteboardType("public.url-name")) ?? url.absoluteString
        return ShelfItem(kind: .url, displayName: title, sourceURL: url, inlineText: url.absoluteString)
    }

    private static func readText(from item: NSPasteboardItem) -> ShelfItem? {
        guard let text = item.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return makeTextItem(text)
    }

    private static func readImage(from item: NSPasteboardItem, imageDirectory: URL) -> ShelfItem? {
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        guard let type = imageTypes.first(where: { item.data(forType: $0) != nil }),
              let data = item.data(forType: type),
              let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else { return nil }

        do {
            try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
            let url = imageDirectory.appendingPathComponent("Image-\(UUID().uuidString).png")
            try pngData.write(to: url, options: .atomic)
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return ShelfItem(kind: .image, displayName: url.lastPathComponent, sourceURL: url, bookmarkData: bookmark)
        } catch {
            return nil
        }
    }

    private static func makeTextItem(_ text: String) -> ShelfItem {
        let prefix = text.replacingOccurrences(of: "\n", with: " ")
        let displayName = prefix.count > 48 ? String(prefix.prefix(45)) + "..." : prefix
        return ShelfItem(kind: .text, displayName: displayName, inlineText: text, lastResolvedState: .inline)
    }

    private static func uniqued(_ items: [ShelfItem]) -> [ShelfItem] {
        var seen = Set<String>()
        return items.filter { item in
            let key = item.sourceURLString ?? item.inlineText ?? item.id.uuidString
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }
    }
}
