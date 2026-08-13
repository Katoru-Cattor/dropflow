import AppKit
import Foundation
import Testing
@testable import DropFlowCore

/// # Why this file exists
///
/// An earlier throwaway harness assumed that overriding `HOME` redirects
/// `~/Library/Application Support`. It does not — `-[NSFileManager URLsForDirectory:]` resolves the
/// home directory through the password database — so the harness wrote straight into the real
/// support directory and destroyed the user's `shelf.json` unrecoverably.
///
/// `DROPFLOW_SUPPORT_DIR` is the only sanctioned redirect. **Every** test that constructs a
/// `ShelfStore` must obtain it from `withSupportSandbox`, never by calling `ShelfStore()` directly.
/// The guard below refuses to run if the directory it is about to use is not disposable.
/// Parent of every suite that redirects `DROPFLOW_SUPPORT_DIR`. The override is process-wide, and
/// `@MainActor` alone does not serialise anything — two main-actor tests interleave at every
/// `await`, so one would run inside the other's support directory. `.serialized` here applies to all
/// nested suites, which is what keeps them apart. **Any new suite that constructs a `ShelfStore`
/// must be nested in here**; `SupportSandbox.run` fails loudly if one is not.
@Suite(.serialized)
struct SupportDirectoryTests {}

@MainActor
enum SupportSandbox {
    /// The sandbox currently in scope, used only to detect overlap. Main-actor isolated, so reading
    /// and writing it needs no lock.
    private static var active: URL?

    /// The real support directory, computed exactly as `ShelfStore.appSupportURL` does when no
    /// override is present. Nothing in the test suite may ever write inside it.
    static var realSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DropFlow", isDirectory: true)
    }

    /// Runs `body` with `DROPFLOW_SUPPORT_DIR` pointed at a unique, empty, disposable directory,
    /// then removes it and restores the previous environment.
    ///
    /// Callers must be inside a `.serialized` suite: the override is process-wide, so two tests
    /// setting it concurrently would each see the other's directory.
    static func run<T>(
        _ label: String = #function,
        body: (Sandbox) async throws -> T
    ) async throws -> T {
        let slug = label.replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "-")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropflow-tests", isDirectory: true)
            .appendingPathComponent("\(slug)-\(UUID().uuidString)", isDirectory: true)

        // Two sandboxes in flight at once means one test is running against the other's directory,
        // and the env var one of them restores on exit is the other's. Fail loudly rather than
        // produce a confusing flake — or, worse, an unprotected window.
        if let active {
            fatalError("""
            a support sandbox at \(active.path) is still active. Two tests are overlapping, which \
            leaves DROPFLOW_SUPPORT_DIR ambiguous. Nest the suite inside SupportDirectoryTests so \
            its .serialized trait applies.
            """)
        }

        try assertDisposable(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        active = directory

        let previous = ProcessInfo.processInfo.environment["DROPFLOW_SUPPORT_DIR"]
        setenv("DROPFLOW_SUPPORT_DIR", directory.path, 1)

        // Read the override back through the same API ShelfStore uses. If it did not take, a store
        // created now would target the user's real shelf, so refuse to continue.
        guard ProcessInfo.processInfo.environment["DROPFLOW_SUPPORT_DIR"] == directory.path else {
            fatalError("DROPFLOW_SUPPORT_DIR did not take; refusing to run a test that could write to the real shelf")
        }

        // ShelfStore() reads the drag mode out of UserDefaults in its initialiser, so a previous
        // test leaving .advance behind would silently change the next test's starting mode.
        UserDefaults.standard.removeObject(forKey: "ShelfDragMode")

        defer {
            active = nil
            UserDefaults.standard.removeObject(forKey: "ShelfDragMode")
            if let previous {
                setenv("DROPFLOW_SUPPORT_DIR", previous, 1)
            } else {
                unsetenv("DROPFLOW_SUPPORT_DIR")
            }
            try? FileManager.default.removeItem(at: directory)
        }

        return try await body(Sandbox(directory: directory))
    }

    /// Refuses any directory that is not under the temp root, or that is at or inside the real
    /// support directory. Belt and braces: the path is constructed above, so this can only fire if
    /// someone edits that construction.
    private static func assertDisposable(_ directory: URL) throws {
        let path = directory.standardizedFileURL.path
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let real = realSupportDirectory.standardizedFileURL.path

        guard path.hasPrefix(tempRoot) else {
            fatalError("refusing to use non-disposable support directory: \(path)")
        }
        guard !path.hasPrefix(real), !real.hasPrefix(path) else {
            fatalError("refusing to use a support directory overlapping the real one: \(path)")
        }
    }

    struct Sandbox {
        let directory: URL

        var shelfJSON: URL { directory.appendingPathComponent("shelf.json") }
        var imagesDirectory: URL { directory.appendingPathComponent("Images", isDirectory: true) }

        /// A `ShelfStore` guaranteed to be pointed at this sandbox.
        @MainActor
        func makeStore() -> ShelfStore {
            precondition(
                ProcessInfo.processInfo.environment["DROPFLOW_SUPPORT_DIR"] == directory.path,
                "sandbox override was lost before the store was created"
            )
            return ShelfStore()
        }

        /// Creates a real file inside the sandbox and returns its URL. Drops need real files —
        /// `ShelfStore` resolves bookmarks and stats paths, so fictional URLs resolve to `.missing`.
        func makeFile(named name: String, contents: String = "x") throws -> URL {
            let files = directory.appendingPathComponent("files", isDirectory: true)
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            let url = files.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }

        func corruptSidecars() throws -> [String] {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            return names.filter { $0.hasPrefix("shelf.json.corrupt-") }.sorted()
        }

        func write(shelfJSON text: String) throws {
            try Data(text.utf8).write(to: shelfJSON)
        }
    }
}

/// A private pasteboard, so no test ever reads or clobbers the user's real clipboard.
/// `ShelfStore.copyValue` writes to `NSPasteboard.general` and therefore cannot be tested here —
/// see the note in ShelfStoreTests.
func makeScratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("dropflow-test-\(UUID().uuidString)"))
}
