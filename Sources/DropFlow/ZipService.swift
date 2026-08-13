import Foundation

enum ZipService {
    static func createZip(from urls: [URL]) throws -> URL {
        let outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let outputURL = outputDirectory.appendingPathComponent("DropFlow-\(formatter.string(from: Date())).zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        let baseURL = commonParent(for: urls)
        process.currentDirectoryURL = baseURL
        process.arguments = ["-r", outputURL.path] + urls.map { relativePath(from: baseURL, to: $0) }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }

        return outputURL
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
