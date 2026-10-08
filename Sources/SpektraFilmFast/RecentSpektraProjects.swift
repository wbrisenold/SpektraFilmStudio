import Foundation

/// File URLs only, never RAW data, cloud credentials, or document contents.
/// Changes notify the Home view, so an empty Recent section updates after saving.
enum RecentSpektraProjects {
    private static let key = "SpektraFilmStudio.recentProjectURLs.v1"
    static let changed = Notification.Name("SpektraFilmStudio.recentProjectsChanged")

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .compactMap(URL.init(string:))
            .filter(\.isFileURL)
            .prefix(12)
            .map { $0 }
    }

    static func record(_ url: URL) {
        guard !CommandLine.arguments.contains(where: { ["--picker-smoke-test", "--ux-smoke-test", "--self-test", "--studio-soak-test"].contains($0) }) else { return }
        let target = url.standardizedFileURL
        guard target.isFileURL else { return }
        var entries = urls.filter { $0.standardizedFileURL != target }
        entries.insert(target, at: 0)
        UserDefaults.standard.set(Array(entries.prefix(12)).map(\.absoluteString), forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
