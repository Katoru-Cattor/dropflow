import AppKit
import Foundation
import Testing
@testable import DropFlowCore

/// The classification table: what a drop becomes. Ported from the `urlprobe` throwaway harness.
///
/// The bug these guard: `URL(string:)` happily parses `"mailto: send it to legal"` as a mailto URL,
/// so a scheme-only test turned ordinary prose into a percent-escaped link and lost the original
/// spacing **for good** — the text the user dropped was not recoverable from what was stored.
///
/// Every test uses a uniquely named private pasteboard. `NSPasteboard.general` is never touched, so
/// running the suite cannot disturb the user's clipboard.
@Suite
@MainActor
struct PasteboardClassificationTests {
    private func classify(string: String) -> [ShelfItem] {
        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        defer { pasteboard.releaseGlobally() }
        return PasteboardReader.readItems(from: pasteboard, imageDirectory: FileManager.default.temporaryDirectory)
    }

    // MARK: - Prose that merely looks URL-ish must stay text

    @Test("Prose whose first word is a URL scheme stays text, with its spacing intact", arguments: [
        "TODO: fix the parser",
        "TODO:fix the parser",
        "mailto: send it to legal",
        "http: is the old one",
        "Ftp: not a url",
        "https: was here",
        "note: buy milk",
        "warning: two spaces  here"
    ])
    func proseStaysText(_ prose: String) throws {
        let items = classify(string: prose)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.kind == .text, "\(prose.debugDescription) was classified as \(item.kind)")
        #expect(item.inlineText == prose, "the exact characters the user dropped must be what is stored")
        #expect(item.lastResolvedState == .inline)
        #expect(item.sourceURLString == nil)
    }

    // MARK: - Real URLs must still be recognised

    @Test("A bare URL in a string-only drop becomes a url row", arguments: [
        "https://example.com",
        "http://example.com/a?b=c",
        "mailto:a@b.com",
        "HTTPS://EXAMPLE.COM",
        "ftp://files.example.com/x.zip",
        "ftps://files.example.com/x.zip"
    ])
    func urlsAreRecognised(_ text: String) throws {
        let items = classify(string: text)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.kind == .url, "\(text) was classified as \(item.kind)")
        #expect(item.sourceURL != nil)
    }

    /// The scheme allowlist is deliberately narrow. A scheme outside it — even a syntactically valid
    /// one — stays text rather than becoming a row the user cannot read back.
    @Test("A scheme outside the allowlist stays text", arguments: [
        "javascript:alert(1)",
        "data:text/plain;base64,aGk=",
        "tel:+15551234",
        "custom-app://open"
    ])
    func unlistedSchemesStayText(_ text: String) throws {
        let items = classify(string: text)
        let item = try #require(items.first)
        #expect(item.kind == .text, "\(text) was classified as \(item.kind)")
        #expect(item.inlineText == text)
    }

    // MARK: - Nothing at all

    @Test("Whitespace-only input produces no row", arguments: ["", " ", "   \n\t ", "\n", "\t\t"])
    func whitespaceProducesNothing(_ blank: String) {
        #expect(classify(string: blank).isEmpty, "a blank drop must not create an empty row")
    }

    // MARK: - Files and folders

    @Test("A dropped file becomes a file row; a dropped directory becomes a folder row")
    func filesAndFolders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropflow-pbtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("report.csv")
        try Data("a,b\n".utf8).write(to: file)
        let folder = root.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL, folder as NSURL])
        defer { pasteboard.releaseGlobally() }

        let items = PasteboardReader.readItems(from: pasteboard, imageDirectory: root)
        #expect(items.count == 2)
        #expect(items.map(\.kind) == [.file, .folder])
        #expect(items.map(\.displayName) == ["report.csv", "Assets"])
        #expect(items.allSatisfy { $0.isFileBacked })
        #expect(items.allSatisfy { $0.bookmarkData != nil }, "a file row without a bookmark cannot survive the file moving")
    }

    /// A file URL must never be routed through the web-URL branch, whatever its name looks like.
    @Test("A file whose name resembles a URL is still a file")
    func fileNamedLikeURL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropflow-pbtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("https:__example.com.txt")
        try Data("x".utf8).write(to: file)

        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        defer { pasteboard.releaseGlobally() }

        let items = PasteboardReader.readItems(from: pasteboard, imageDirectory: root)
        let item = try #require(items.first)
        #expect(item.kind == .file)
        #expect(item.sourceURL?.isFileURL == true)
    }

    // MARK: - Images

    @Test("Pasted PNG data becomes an image row backed by a real file with a readable name")
    func pastedImageIsSavedToDisk() async throws {
        let imageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropflow-pbtest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: imageDirectory) }

        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try #require(rep.representation(using: .png, properties: [:]))

        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        defer { pasteboard.releaseGlobally() }

        let items = PasteboardReader.readItems(from: pasteboard, imageDirectory: imageDirectory)
        let item = try #require(items.first)
        #expect(item.kind == .image)
        // The filename is also the row title and the payload of every later drag out, so a UUID name
        // meant dragging a shelved screenshot to the Desktop landed "Image-9F3A2C41-…-….png".
        #expect(item.displayName.hasPrefix("Image-"))
        #expect(item.displayName.hasSuffix(".png"))
        #expect(!item.displayName.contains(item.id.uuidString))
        let url = try #require(item.sourceURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - De-duplication within one drop

    @Test("The same file listed twice in one drop yields one row")
    func dedupesWithinOneDrop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropflow-pbtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("dup.txt")
        try Data("x".utf8).write(to: file)

        let pasteboard = makeScratchPasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL, file as NSURL])
        defer { pasteboard.releaseGlobally() }

        #expect(PasteboardReader.readItems(from: pasteboard, imageDirectory: root).count == 1)
    }

    @Test("Long text is truncated for display but stored in full")
    func longTextKeepsFullPayload() throws {
        let long = String(repeating: "abcde ", count: 40)
        let item = try #require(classify(string: long).first)
        #expect(item.inlineText == long.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(item.displayName.count <= 48)
        #expect(item.displayName.hasSuffix("..."))
    }

    @Test("A multi-line drop keeps its newlines in the payload but not in the row title")
    func multilineText() throws {
        let item = try #require(classify(string: "first\nsecond").first)
        #expect(item.inlineText == "first\nsecond")
        #expect(!item.displayName.contains("\n"))
    }
}
