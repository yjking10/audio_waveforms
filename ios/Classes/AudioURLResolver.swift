import Foundation

enum AudioURLResolver {
    static func makeAudioURL(from path: String) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }

        let url: URL?
        if path.hasPrefix("file://") {
            url = URL(string: path)
        } else {
            url = URL(fileURLWithPath: path.removingPercentEncoding ?? path)
        }

        guard let url = url else { return nil }
        return resolveSandboxURLIfNeeded(url)
    }

    private static func resolveSandboxURLIfNeeded(_ url: URL) -> URL {
        guard url.isFileURL else { return url }

        let fileManager = FileManager.default
        let path = url.path
        if fileManager.fileExists(atPath: path) {
            return url
        }

        return replacementURL(for: path, directoryName: "Documents", directory: .documentDirectory)
            ?? replacementURL(for: path, directoryName: "Library", directory: .libraryDirectory)
            ?? replacementTemporaryURL(for: path)
            ?? url
    }

    private static func replacementURL(
        for path: String,
        directoryName: String,
        directory: FileManager.SearchPathDirectory
    ) -> URL? {
        let marker = "/\(directoryName)/"
        guard let range = path.range(of: marker),
              let baseURL = FileManager.default.urls(for: directory, in: .userDomainMask).first else {
            return nil
        }

        let relativePath = String(path[range.upperBound...])
        let candidateURL = baseURL.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: candidateURL.path) ? candidateURL : nil
    }

    private static func replacementTemporaryURL(for path: String) -> URL? {
        guard let range = path.range(of: "/tmp/") else { return nil }

        let relativePath = String(path[range.upperBound...])
        let temporaryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let candidateURL = temporaryURL.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: candidateURL.path) ? candidateURL : nil
    }
}
