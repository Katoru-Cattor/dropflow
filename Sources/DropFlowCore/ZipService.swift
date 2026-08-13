import Foundation

public enum ZipService {
    public static func createZip(from urls: [URL]) async throws -> URL {
        let outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let outputURL = outputDirectory.appendingPathComponent("DropFlow-\(formatter.string(from: Date())).zip")
        let baseURL = commonParent(for: urls)
        let relPaths = urls.map { relativePath(from: baseURL, to: $0) }
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropflow-zip-\(UUID().uuidString).log")
        try? Data().write(to: logURL)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = baseURL
            // "--" ends option parsing, so a member named "-x.csv" is treated as a file instead of
            // as zip's own -x exclude flag — that bug exited 0 with the file silently missing from
            // the archive. Verified on Info-ZIP 3.0: it must come *after* the archive name ("can't
            // use -- before archive name"), and it does not leak into the stored member names.
            process.arguments = Self.zipArguments(archivePath: outputURL.path, relativePaths: relPaths)
            // Both streams to one handle: zip reports most failures on *stdout* ("Nothing to do!",
            // "Could not create output file") and only some warnings on stderr, so capturing stderr
            // alone leaves the alert naming no reason. One handle means one shared file offset, so
            // the two streams interleave in order instead of overwriting each other. A file, not a
            // Pipe, because nothing drains the pipe until exit and a recursive add can fill it —
            // that would hang the continuation forever.
            let logHandle = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
            process.standardOutput = logHandle
            process.standardError = logHandle

            process.terminationHandler = { proc in
                let status = proc.terminationStatus
                let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: logURL)

                guard status != 0 else {
                    continuation.resume(returning: outputURL)
                    return
                }

                // Keep the tail: zip's reason lines come last, after one "adding:" line per file.
                let reason = log.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .suffix(4)
                    .joined(separator: "\n")
                NSLog("DropFlow zip failed with status \(status): \(reason)")
                continuation.resume(throwing: NSError(
                    domain: "DropFlow.ZipService",
                    code: Int(status),
                    userInfo: [
                        NSLocalizedDescriptionKey: "Creating the ZIP failed — /usr/bin/zip exited with status \(status).",
                        NSLocalizedRecoverySuggestionErrorKey: reason.isEmpty ? "zip reported no reason." : reason
                    ]
                ))
            }

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: logURL)
                continuation.resume(throwing: error)
            }
        }
    }

    /// The argv `createZip` hands to /usr/bin/zip, extracted only so a test can drive the real
    /// argument construction. A member whose name begins with "-" is why the "--" is here: without
    /// it zip parses "-x.csv" as its own exclude flag, exits **0**, and silently leaves the file out
    /// of the archive — a status-code assertion cannot see that, only the archive contents can.
    public static func zipArguments(archivePath: String, relativePaths: [String]) -> [String] {
        ["-r", archivePath, "--"] + relativePaths
    }

    public static func commonParent(for urls: [URL]) -> URL {
        let pathComponents = urls.map { $0.deletingLastPathComponent().standardizedFileURL.pathComponents }
        guard var common = pathComponents.first else {
            return FileManager.default.homeDirectoryForCurrentUser
        }

        for components in pathComponents.dropFirst() {
            var index = 0
            while index < min(common.count, components.count), common[index] == components[index] {
                index += 1
            }
            common = Array(common.prefix(index))
        }

        guard !common.isEmpty else { return URL(fileURLWithPath: "/") }
        return NSURL.fileURL(withPathComponents: common) ?? URL(fileURLWithPath: "/")
    }

    public static func relativePath(from baseURL: URL, to url: URL) -> String {
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents
        let relativeComponents = targetComponents.dropFirst(baseComponents.count)
        return relativeComponents.joined(separator: "/")
    }
}
