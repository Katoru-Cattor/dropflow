import Foundation
import Testing
@testable import DropFlowCore

/// `zip` parses a leading dash as one of its own options. A shelf containing `-x.csv` produced an
/// archive missing that file, and `zip` **exited 0** doing it — so a status-code assertion passes
/// while the user silently loses a file. Only an assertion on the archive's contents can see this.
///
/// These tests drive the real argv builder and the real `/usr/bin/zip`, but never
/// `ZipService.createZip`: that writes its output into the user's Downloads folder, and a test has
/// no business leaving files there. The Process configuration is the only line not covered.
@Suite
struct ZipArgumentTests {
    private struct Workspace {
        let sourceDirectory: URL
        let outputDirectory: URL

        func archive(_ name: String) -> URL { outputDirectory.appendingPathComponent(name) }
    }

    private func withWorkspace<T>(_ body: (Workspace) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropflow-ziptest-\(UUID().uuidString)", isDirectory: true)
        // The archive must live outside the tree being zipped, or `zip -r` tries to add it to itself.
        let source = root.appendingPathComponent("src", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        for directory in [source, output] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(Workspace(sourceDirectory: source, outputDirectory: output))
    }

    private func makeFiles(_ names: [String], in directory: URL) throws -> [URL] {
        try names.map { name in
            let url = directory.appendingPathComponent(name)
            try Data("contents of \(name)\n".utf8).write(to: url)
            return url
        }
    }

    /// Runs /usr/bin/zip exactly as ZipService does — same argv, same working directory.
    @discardableResult
    private func runZip(arguments: [String], workingDirectory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workingDirectory
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Member names inside an archive, via zipinfo's one-name-per-line mode.
    private func archiveMembers(_ archive: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// Builds the argv the way `createZip` does: common parent, relative paths, then `zipArguments`.
    private func productionArguments(for urls: [URL], archive: URL) -> (argv: [String], workingDirectory: URL) {
        let base = ZipService.commonParent(for: urls)
        let relativePaths = urls.map { ZipService.relativePath(from: base, to: $0) }
        return (ZipService.zipArguments(archivePath: archive.path, relativePaths: relativePaths), base)
    }

    // MARK: - The argv shape

    @Test("The archive name comes before the -- terminator")
    func terminatorFollowsArchiveName() {
        let argv = ZipService.zipArguments(archivePath: "/tmp/out.zip", relativePaths: ["-x.csv", "a.txt"])
        // Info-ZIP 3.0 rejects "--" before the archive name ("can't use -- before archive name"),
        // so the order here is load-bearing, not cosmetic.
        #expect(argv == ["-r", "/tmp/out.zip", "--", "-x.csv", "a.txt"])
        #expect(argv.firstIndex(of: "--") == 2)
    }

    @Test("Relative paths are computed against the common parent, not absolute")
    func relativePathsAreRelative() throws {
        try withWorkspace { workspace in
            let nested = workspace.sourceDirectory.appendingPathComponent("deep/deeper", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let urls = try makeFiles(["top.txt"], in: workspace.sourceDirectory)
                + makeFiles(["buried.txt"], in: nested)

            let built = productionArguments(for: urls, archive: workspace.archive("out.zip"))
            #expect(built.workingDirectory.standardizedFileURL.path == workspace.sourceDirectory.standardizedFileURL.path)
            #expect(Array(built.argv.dropFirst(3)) == ["top.txt", "deep/deeper/buried.txt"])
        }
    }

    // MARK: - The behaviour that argv shape exists for

    @Test("A file named -x.csv actually appears in the produced archive")
    func dashPrefixedFileIsArchived() throws {
        try withWorkspace { workspace in
            let urls = try makeFiles(["-x.csv", "normal.txt"], in: workspace.sourceDirectory)
            let archive = workspace.archive("out.zip")
            let built = productionArguments(for: urls, archive: archive)

            let status = try runZip(arguments: built.argv, workingDirectory: built.workingDirectory)
            #expect(status == 0)
            #expect(try archiveMembers(archive) == ["-x.csv", "normal.txt"])
        }
    }

    /// Proves the test above can actually fail. Without the `--`, zip reads `-x` as its exclude
    /// option, takes `.csv` as the pattern, still exits **0**, and quietly omits the file. If this
    /// control ever starts producing a complete archive, the assertion above has stopped meaning
    /// anything.
    @Test("Control: dropping the -- silently loses the file while still exiting 0")
    func withoutTerminatorTheFileIsSilentlyLost() throws {
        try withWorkspace { workspace in
            let urls = try makeFiles(["-x.csv", "normal.txt"], in: workspace.sourceDirectory)
            let archive = workspace.archive("control.zip")
            let base = ZipService.commonParent(for: urls)
            let relativePaths = urls.map { ZipService.relativePath(from: base, to: $0) }

            let unsafeArgv = ["-r", archive.path] + relativePaths
            let status = try runZip(arguments: unsafeArgv, workingDirectory: base)

            #expect(status == 0, "zip reports success — which is exactly why this needed a contents assertion")
            let members = try archiveMembers(archive)
            #expect(!members.contains("-x.csv"), "the control no longer reproduces the bug; the guard above is now vacuous")
            #expect(members == ["normal.txt"])
        }
    }

    @Test("Other option-looking names survive too", arguments: ["-r", "--help", "-", "-9.txt", "-x"])
    func otherDashNamesAreArchived(_ name: String) throws {
        try withWorkspace { workspace in
            let urls = try makeFiles([name, "keep.txt"], in: workspace.sourceDirectory)
            let archive = workspace.archive("out.zip")
            let built = productionArguments(for: urls, archive: archive)

            let status = try runZip(arguments: built.argv, workingDirectory: built.workingDirectory)
            #expect(status == 0)
            #expect(try archiveMembers(archive).contains(name), "\(name) was dropped from the archive")
        }
    }

    @Test("The -- does not leak into the stored member names")
    func terminatorIsNotStored() throws {
        try withWorkspace { workspace in
            let urls = try makeFiles(["a.txt"], in: workspace.sourceDirectory)
            let archive = workspace.archive("out.zip")
            let built = productionArguments(for: urls, archive: archive)
            try runZip(arguments: built.argv, workingDirectory: built.workingDirectory)

            let members = try archiveMembers(archive)
            #expect(members == ["a.txt"])
            #expect(!members.contains { $0.contains("--") })
        }
    }

    // MARK: - Path arithmetic

    @Test("Files from sibling folders share the parent directory as the archive root")
    func commonParentOfSiblings() throws {
        try withWorkspace { workspace in
            let left = workspace.sourceDirectory.appendingPathComponent("left", isDirectory: true)
            let right = workspace.sourceDirectory.appendingPathComponent("right", isDirectory: true)
            for directory in [left, right] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let urls = try makeFiles(["a.txt"], in: left) + makeFiles(["b.txt"], in: right)

            let base = ZipService.commonParent(for: urls)
            #expect(base.standardizedFileURL.path == workspace.sourceDirectory.standardizedFileURL.path)
            #expect(urls.map { ZipService.relativePath(from: base, to: $0) } == ["left/a.txt", "right/b.txt"])
        }
    }

    @Test("A single file's common parent is its own directory")
    func commonParentOfOne() throws {
        try withWorkspace { workspace in
            let urls = try makeFiles(["only.txt"], in: workspace.sourceDirectory)
            let base = ZipService.commonParent(for: urls)
            #expect(base.standardizedFileURL.path == workspace.sourceDirectory.standardizedFileURL.path)
            #expect(ZipService.relativePath(from: base, to: urls[0]) == "only.txt")
        }
    }
}
