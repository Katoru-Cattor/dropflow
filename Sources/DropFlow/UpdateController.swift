import AppKit

// Update *notifier* for DropFlow — deliberately not a self-installer.
//
// Trust model: the release JSON is fetched over HTTPS from GitHub and the .dmg URL is
// handed to the browser. DropFlow never downloads, verifies, mounts or replaces itself,
// so a compromised release cannot get code running inside an app that already has
// Accessibility trust and a login item. Whoever installs the update sees the .dmg in
// Finder, drags DropFlow to /Applications, and can check the SHA-256 that
// scripts/release.sh prints in the release notes (shown verbatim in the alert below).
// A Developer ID signature plus notarization is the upgrade path that would make a
// hands-off installer defensible; ad-hoc signing is not.

struct GitHubRelease {
    let version: String
    let notes: String
    let dmgURL: URL?
    let htmlURL: URL?
}

enum UpdateError: LocalizedError {
    case noReleases
    case rateLimited
    case http(Int)
    case malformedResponse

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
        }
    }
}

@MainActor
final class UpdateController {
    nonisolated static let owner = "Katoru-Cattor"
    nonisolated static let repo = "dropflow"

    nonisolated static let autoCheckKey = "UpdateAutoCheck"
    private static let lastCheckKey = "UpdateLastBackgroundCheck"
    private static let skippedVersionKey = "UpdateSkippedVersion"
    private static let backgroundInterval: TimeInterval = 60 * 60 * 24

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var releasesPageURL: URL? {
        URL(string: "https://github.com/\(owner)/\(repo)/releases")
    }

    /// Defaults to on, like every non-App-Store Mac updater. Toggled from the status menu.
    nonisolated static var isAutoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    private var isRunning = false

    // MARK: - Entry points

    /// Menu-driven check. Always reports the outcome, including "you are up to date".
    func checkForUpdates() {
        guard !isRunning else { return }
        Task { await runCheck(userInitiated: true) }
    }

    /// Launch-time check. Silent unless a newer version exists, and at most once a day.
    func checkInBackgroundIfDue() {
        guard !isRunning, Self.isAutoCheckEnabled else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard last == 0 || now - last >= Self.backgroundInterval else { return }
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

        // Stamped only on success: a failed check used to burn the whole 24 h window.
        if !userInitiated {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
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
        case .download:
            // No .dmg on the release ⇒ send them to the release page rather than nowhere.
            NSWorkspace.shared.open(release.dmgURL ?? release.htmlURL ?? Self.releasesPageURL!)
        case .releaseNotes:
            NSWorkspace.shared.open(release.htmlURL ?? Self.releasesPageURL!)
        case .skip:
            UserDefaults.standard.set(release.version, forKey: Self.skippedVersionKey)
        case .later:
            break
        }
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

        // Resource timeout as well as the request's inactivity timeout: a response that
        // trickles forever never trips the latter, and a hung fetch would leave isRunning
        // true for the rest of the session, killing "Check for Updates…".
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
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
            htmlURL: (json["html_url"] as? String).flatMap(URL.init(string:))
        )
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

    // MARK: - UI

    private enum UpdateChoice { case download, releaseNotes, skip, later }

    private func presentUpdateAvailable(_ release: GitHubRelease, userInitiated: Bool) -> UpdateChoice {
        let alert = NSAlert()
        alert.messageText = "DropFlow \(release.version) is available"
        alert.informativeText = "You are running \(Self.currentVersion). The .dmg downloads in your "
            + "browser — open it and drag DropFlow to /Applications to finish."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: userInitiated ? "Later" : "Skip This Version")
        if !release.notes.isEmpty {
            alert.accessoryView = Self.notesView(release.notes)
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .download
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
        alert.messageText = "Update check failed"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Releases Page")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { openReleasesPage() }
    }
}
