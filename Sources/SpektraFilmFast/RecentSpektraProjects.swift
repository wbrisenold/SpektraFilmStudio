import Foundation

/// File-menu projects and cloud catalogs retain their original documents.
/// Only file URLs are tracked, never RAW data or credentials.
enum RecentSpektraProjects {
    private static let key = "SpektraFilmStudio.recentProjectURLs.v1"
    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .compactMap(URL.init(string:))
            .filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
            .prefix(12)
            .map { $0 }
    }

    static func record(_ url: URL) {
        let target = url.standardizedFileURL
        guard target.isFileURL else { return }
        var items = urls.filter { $0.standardizedFileURL != target }
        items.insert(target, at: 0)
        UserDefaults.standard.set(Array(items.prefix(12)).map(\.absoluteString), forKey: key)
    }
}
