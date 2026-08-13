import Foundation

enum ZipService {
    static func createZip(from urls: [URL]) async throws -> URL {
        let outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let outputURL = outputDirectory.appendingPathComponent("DropFlow-\(formatter.string(from: Date())).zip")
        let baseURL = commonParent(for: urls)
        let relPaths = urls.map { relativePath(from: baseURL, to: $0) }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = baseURL
            process.arguments = ["-r", outputURL.path] + relPaths
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: outputURL)
                } else {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func commonParent(for urls: [URL]) -> URL {
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

    private static func relativePath(from baseURL: URL, to url: URL) -> String {
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents
        let relativeComponents = targetComponents.dropFirst(baseComponents.count)
        return relativeComponents.joined(separator: "/")
    }
}
