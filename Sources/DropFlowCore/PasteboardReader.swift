import AppKit

public enum PasteboardReader {
    /// Schemes accepted when a drop offers *only* plain text. Deliberately narrow: any wider and
    /// ordinary prose with a colon ("TODO: fix the parser") is stored as a mangled URL row, and the
    /// original spacing is gone for good.
    private static let plainTextURLSchemes: Set<String> = ["http", "https", "mailto", "ftp", "ftps"]

    public static func readItems(from pasteboard: NSPasteboard, imageDirectory: URL) -> [ShelfItem] {
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
            results.append(contentsOf: strings.compactMap { makeTextItem(trimming: $0) })
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
        // `.URL.rawValue` is literally "public.url", so there is only one declared-URL flavour to
        // read. The plain-string fallback below is deliberate — a link copied out of a terminal or a
        // plain-text editor carries no `.URL` flavour — which is why it is scheme-gated.
        let declared = item.string(forType: .URL)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = item.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let raw: String
        if let declared, !declared.isEmpty {
            raw = declared
        } else if let plain, isPlainTextURL(plain) {
            raw = plain
        } else {
            return nil
        }

        guard let url = URL(string: raw),
              let scheme = url.scheme,
              !scheme.isEmpty,
              !url.isFileURL
        else { return nil }

        let title = item.string(forType: NSPasteboard.PasteboardType("public.url-name")) ?? url.absoluteString
        return ShelfItem(kind: .url, displayName: title, sourceURL: url, inlineText: url.absoluteString)
    }

    private static func isPlainTextURL(_ text: String) -> Bool {
        // Whitespace check first: URL(string:) happily parses "mailto: send it to legal" as a
        // mailto URL, so a scheme test alone turns any sentence whose first word is a scheme into
        // a percent-escaped link and loses the original spacing for good. No real URL contains
        // unescaped whitespace, so requiring none of it costs nothing and closes the whole class.
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let scheme = URL(string: text)?.scheme?.lowercased()
        else { return false }
        return plainTextURLSchemes.contains(scheme)
    }

    private static func readText(from item: NSPasteboardItem) -> ShelfItem? {
        guard let raw = item.string(forType: .string) else { return nil }
        return makeTextItem(trimming: raw)
    }

    private static func readImage(from item: NSPasteboardItem, imageDirectory: URL) -> ShelfItem? {
        let pngData: Data
        if let raw = item.data(forType: .png) {
            pngData = raw
        } else if let tiff = item.data(forType: .tiff),
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let encoded = bitmap.representation(using: .png, properties: [:]) {
            pngData = encoded
        } else {
            return nil
        }

        do {
            try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
            let url = unusedImageURL(in: imageDirectory)
            try pngData.write(to: url, options: .atomic)
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return ShelfItem(kind: .image, displayName: url.lastPathComponent, sourceURL: url, bookmarkData: bookmark)
        } catch {
            return nil
        }
    }

    /// This filename is also the row title and the payload of every later drag out, so dragging a
    /// shelved screenshot to the Desktop used to land "Image-9F3A2C41-…-….png".
    private static func unusedImageURL(in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())
        var candidate = directory.appendingPathComponent("Image-\(stamp).png")
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("Image-\(stamp)-\(UUID().uuidString.prefix(4)).png")
        }
        return candidate
    }

    private static func makeTextItem(trimming raw: String) -> ShelfItem? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
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
