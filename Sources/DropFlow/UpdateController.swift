import AppKit
import CryptoKit

// In-app updater for DropFlow.
//
// Trust model: the release is fetched over HTTPS from GitHub, and the .dmg is only
// installed if its SHA-256 matches the hash published in the release notes by
// scripts/release.sh. That combination detects corrupted or truncated downloads and
// asset swaps that do not also rewrite the release body. It is NOT a substitute for a
// Developer ID signature: DropFlow is ad-hoc signed, so there is no stable code-signing
// identity to pin. Notarizing with a Developer ID is the real upgrade path.

struct GitHubRelease {
    let version: String
    let notes: String
    let dmgURL: URL?
    let htmlURL: URL?
    let sha256: String?
}

enum UpdateError: LocalizedError {
    case noReleases
    case rateLimited
    case http(Int)
    case malformedResponse
    case noDMGAsset
    case checksumMissing
    case checksumMismatch(expected: String, actual: String)
    case notAnAppBundle
    case destinationNotWritable(String)
    case toolFailed(String, Int32)
    case noAppInDMG

    var errorDescription: String? {
        switch self {
        case .noReleases:
            return "No releases have been published yet."
        case .rateLimited:
            return "GitHub rate limit reached. Try again later."
        case .http(let code):
            return "GitHub returned HTTP \(code)."
        case .malformedResponse:
            return "Could not read the release information from GitHub."
        case .noDMGAsset:
            return "That release has no .dmg attached."
        case .checksumMissing:
            return "The release notes publish no SHA-256 hash, so this download cannot be verified. Install it manually instead."
        case .checksumMismatch(let expected, let actual):
            return "Download failed verification.\n\nExpected SHA-256:\n\(expected)\n\nGot:\n\(actual)\n\nThe file was discarded and nothing was installed."
        case .notAnAppBundle:
            return "DropFlow is running from a build directory, not from DropFlow.app, so it cannot replace itself. Download the .dmg instead."
        case .destinationNotWritable(let path):
            return "No permission to write to \(path). Install the .dmg manually."
        case .toolFailed(let tool, let status):
            return "\(tool) failed with exit code \(status)."
        case .noAppInDMG:
            return "The downloaded disk image contains no DropFlow.app."
        }
    }
}

@MainActor
final class UpdateController {
    nonisolated static let owner = "Katoru-Cattor"
    nonisolated static let repo = "dropflow"

    private static let lastCheckKey = "UpdateLastBackgroundCheck"
    private static let skippedVersionKey = "UpdateSkippedVersion"
    private static let backgroundInterval: TimeInterval = 60 * 60 * 24

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var releasesPageURL: URL? {
        URL(string: "https://github.com/\(owner)/\(repo)/releases")
    }

    private var isRunning = false
    private var progressWindow: NSWindow?

    // MARK: - Entry points

    /// Menu-driven check. Always reports the outcome, including "you are up to date".
    func checkForUpdates() {
        guard !isRunning else { return }
        Task { await runCheck(userInitiated: true) }
    }

    /// Launch-time check. Silent unless a newer version exists, and at most once a day.
    func checkInBackgroundIfDue() {
        guard !isRunning else { return }
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard last == 0 || now - last >= Self.backgroundInterval else { return }
        defaults.set(now, forKey: Self.lastCheckKey)
        Task { await runCheck(userInitiated: false) }
    }

    func openReleasesPage() {
        if let url = Self.releasesPageURL {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Flow

    private func runCheck(userInitiated: Bool) async {
        isRunning = true
        defer { isRunning = false }

        let release: GitHubRelease
        do {
            release = try await Self.fetchLatestRelease()
        } catch {
            if userInitiated { presentError(error) }
            return
        }

        guard Self.isNewer(release.version, than: Self.currentVersion) else {
            if userInitiated {
                presentInfo(title: "DropFlow is up to date",
                            message: "You are running version \(Self.currentVersion).")
            }
            return
        }

        if !userInitiated,
           UserDefaults.standard.string(forKey: Self.skippedVersionKey) == release.version {
            return
        }

        switch presentUpdateAvailable(release, userInitiated: userInitiated) {
        case .install:
            await install(release)
        case .releaseNotes:
            NSWorkspace.shared.open(release.htmlURL ?? Self.releasesPageURL!)
        case .skip:
            UserDefaults.standard.set(release.version, forKey: Self.skippedVersionKey)
        case .later:
            break
        }
    }

    private func install(_ release: GitHubRelease) async {
        guard let dmgURL = release.dmgURL else {
            presentError(UpdateError.noDMGAsset)
            return
        }
        guard let expected = release.sha256 else {
            presentError(UpdateError.checksumMissing)
            NSWorkspace.shared.open(dmgURL)
            return
        }

        let destination = Bundle.main.bundleURL
        guard destination.pathExtension == "app" else {
            presentError(UpdateError.notAnAppBundle)
            NSWorkspace.shared.open(dmgURL)
            return
        }
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            presentError(UpdateError.destinationNotWritable(parent.path))
            NSWorkspace.shared.open(dmgURL)
            return
        }

        showProgress("Downloading DropFlow \(release.version)…")
        var mountPoint: URL?
        var downloaded: URL?
        do {
            let file = try await Self.download(dmgURL)
            downloaded = file

            setProgressMessage("Verifying download…")
            let actual = try Self.sha256(ofFileAt: file)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw UpdateError.checksumMismatch(expected: expected.lowercased(), actual: actual)
            }

            setProgressMessage("Installing…")
            let mount = try await Self.attach(dmg: file)
            mountPoint = mount
            let newApp = try Self.findApp(in: mount)

            // Stage inside the destination's own directory so the final swap is a rename
            // on one volume rather than a cross-volume copy.
            let staged = parent.appendingPathComponent(".DropFlow-update-\(UUID().uuidString).app")
            try FileManager.default.copyItem(at: newApp, to: staged)
            defer { try? FileManager.default.removeItem(at: staged) }

            // The copy inherits com.apple.quarantine from the .dmg. Its SHA-256 has just
            // been matched against the published hash, so clear it — otherwise Gatekeeper
            // blocks this ad-hoc signed build and the user has to right-click → Open.
            _ = try? await Self.runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
            try await Self.verifyCodeSignature(of: staged)

            _ = try? FileManager.default.replaceItemAt(destination, withItemAt: staged)
            try? await Self.detach(mount)
            mountPoint = nil
            try? FileManager.default.removeItem(at: file)
            downloaded = nil

            hideProgress()
            relaunch(at: destination, version: release.version)
        } catch {
            if let mount = mountPoint { try? await Self.detach(mount) }
            if let file = downloaded { try? FileManager.default.removeItem(at: file) }
            hideProgress()
            presentError(error)
        }
    }

    private func relaunch(at appURL: URL, version: String) {
        let alert = NSAlert()
        alert.messageText = "DropFlow \(version) installed"
        alert.informativeText = "DropFlow needs to restart to finish updating. Anything on the shelf is saved first."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() != .alertFirstButtonReturn { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", appURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - GitHub

    nonisolated static func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("DropFlow", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.malformedResponse }
        switch http.statusCode {
        case 200:
            break
        case 404:
            throw UpdateError.noReleases
        case 403, 429:
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                throw UpdateError.rateLimited
            }
            throw UpdateError.http(http.statusCode)
        default:
            throw UpdateError.http(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.malformedResponse
        }
        return try parseRelease(json)
    }

    nonisolated static func parseRelease(_ json: [String: Any]) throws -> GitHubRelease {
        guard let tag = json["tag_name"] as? String else { throw UpdateError.malformedResponse }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = json["body"] as? String ?? ""
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
        return GitHubRelease(
            version: version,
            notes: notes,
            dmgURL: (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:)),
            htmlURL: (json["html_url"] as? String).flatMap(URL.init(string:)),
            sha256: parseSHA256(from: notes)
        )
    }

    /// Pulls the 64-hex digest out of the release body written by scripts/release.sh.
    nonisolated static func parseSHA256(from notes: String) -> String? {
        let pattern = "(?:SHA-?256[^0-9a-fA-F]{0,20})([0-9a-fA-F]{64})"
        if let match = notes.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            let text = String(notes[match])
            if let digest = text.range(of: "[0-9a-fA-F]{64}", options: .regularExpression) {
                return String(text[digest]).lowercased()
            }
        }
        return nil
    }

    /// Numeric, component-wise. "0.10.0" beats "0.9.0"; equal versions are not newer.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Download / verify / mount

    nonisolated static func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("DropFlow", forHTTPHeaderField: "User-Agent")
        // ponytail: no byte-level progress — the .dmg is a couple of MB, so the panel is
        // indeterminate. Switch to URLSessionDownloadDelegate if the asset ever gets big.
        let (temp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: temp)
            throw UpdateError.http(http.statusCode)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropFlow-update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    nonisolated static func sha256(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func attach(dmg: URL) async throws -> URL {
        let output = try await runTool("/usr/bin/hdiutil",
                                      ["attach", dmg.path, "-nobrowse", "-readonly", "-plist"])
        guard let plist = try PropertyListSerialization.propertyList(
                from: output, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw UpdateError.malformedResponse
        }
        for entity in entities {
            if let point = entity["mount-point"] as? String, !point.isEmpty {
                return URL(fileURLWithPath: point)
            }
        }
        throw UpdateError.malformedResponse
    }

    nonisolated static func detach(_ mountPoint: URL) async throws {
        _ = try await runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
    }

    nonisolated static func findApp(in mountPoint: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: mountPoint, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.noAppInDMG
        }
        return app
    }

    nonisolated static func verifyCodeSignature(of app: URL) async throws {
        // Ad-hoc signatures carry no identity, so this only proves the bundle's own
        // contents match its seal — i.e. it was not modified after being signed.
        _ = try await runTool("/usr/bin/codesign", ["--verify", "--strict", app.path])
    }

    /// Runs a tool, capturing stdout via a temp file so a large output cannot deadlock a pipe.
    nonisolated static func runTool(_ path: String, _ arguments: [String]) async throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropflow-tool-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                try? handle.close()
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                try? handle.close()
                continuation.resume(throwing: error)
            }
        }
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        guard status == 0 else {
            throw UpdateError.toolFailed((path as NSString).lastPathComponent, status)
        }
        return data
    }

    // MARK: - UI

    private enum UpdateChoice { case install, releaseNotes, skip, later }

    private func presentUpdateAvailable(_ release: GitHubRelease, userInitiated: Bool) -> UpdateChoice {
        let alert = NSAlert()
        alert.messageText = "DropFlow \(release.version) is available"
        alert.informativeText = "You are running \(Self.currentVersion)."
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: userInitiated ? "Later" : "Skip This Version")
        if !release.notes.isEmpty {
            alert.accessoryView = Self.notesView(release.notes)
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .install
        case .alertSecondButtonReturn: return .releaseNotes
        default: return userInitiated ? .later : .skip
        }
    }

    private static func notesView(_ notes: String) -> NSView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))
        textView.string = notes
        textView.isEditable = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    private func presentInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update failed"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showProgress(_ message: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 96),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "DropFlow Update"
        window.isReleasedWhenClosed = false
        window.level = .floating

        let label = NSTextField(labelWithString: message)
        label.frame = NSRect(x: 20, y: 56, width: 280, height: 20)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 30, width: 280, height: 16))
        bar.isIndeterminate = true
        bar.style = .bar
        bar.startAnimation(nil)

        window.contentView?.addSubview(label)
        window.contentView?.addSubview(bar)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        progressWindow = window
    }

    private func setProgressMessage(_ message: String) {
        guard let field = progressWindow?.contentView?.subviews
            .compactMap({ $0 as? NSTextField }).first else { return }
        field.stringValue = message
    }

    private func hideProgress() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
    }
}
