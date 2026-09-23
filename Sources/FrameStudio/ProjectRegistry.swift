import SwiftUI
import AppKit
import FrameCore
import FrameMedia

/// The start screen's project list: persisted in the app's defaults, with each card's summary
/// and poster read off the main actor so a slow or missing file never stalls the window.
@MainActor final class ProjectRegistry: ObservableObject {
    enum Status {
        case loading
        case ready(ProjectSummary, modified: Date?)
        case missing
        case unreadable(String)
    }
    @Published private(set) var history: ProjectHistory
    @Published private(set) var status: [String: Status] = [:]
    @Published private(set) var posters: [String: NSImage] = [:]
    private let defaults: UserDefaults
    private static let key = "AraProjectHistory.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ProjectHistory.self, from: $0) } ?? ProjectHistory()
    }

    func record(_ url: URL) {
        history.record(url.path, at: Date())
        persist()
        status[ProjectHistory.normalized(url.path)] = nil
        // Making a bookmark can wait on file-system and permission services, and record() is
        // reached from the Open Documents Apple event, so it never happens on the main actor.
        // A plain (not security-scoped) bookmark is enough to follow a moved file in this unsandboxed app.
        let path = url.path
        Task { [weak self] in
            let bookmark = await Task.detached(priority: .utility) {
                try? URL(fileURLWithPath: path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }.value
            guard let self, let bookmark else { return }
            self.history.setBookmark(bookmark, for: path); self.persist()
        }
    }
    /// Adds every project found in the given files and folders (folders are searched a few levels
    /// deep). Returns how many new projects were added.
    @discardableResult func add(from urls: [URL]) async -> Int {
        let found = await Task.detached(priority: .userInitiated) { Self.findProjects(in: urls) }.value
        let before = Set(history.entries.map(\.path))
        history.add(discovered: found.map { (path: $0.path, date: $0.date) })
        persist(); refresh()
        return history.entries.filter { !before.contains($0.path) }.count
    }
    private struct Found: Sendable { let path: String; let date: Date }
    private nonisolated static func findProjects(in urls: [URL]) -> [Found] {
        let files = FileManager.default
        var found: [Found] = []
        func consider(_ url: URL) {
            guard url.pathExtension.lowercased() == "framestudio",
                  let date = (try? files.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return }
            found.append(Found(path: url.path, date: date))
        }
        for url in urls {
            var isFolder: ObjCBool = false
            guard files.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            guard isFolder.boolValue else { consider(url); continue }
            guard let walker = files.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let item as URL in walker {
                // Bounded so pointing at a home folder cannot stall on a huge tree.
                if walker.level > 4 { walker.skipDescendants(); continue }
                consider(item)
                if found.count >= ProjectHistory.limit * 4 { return found }
            }
        }
        return found
    }
    func remove(_ path: String) {
        history.remove(path); status[path] = nil; posters[path] = nil; persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.key) }
    }

    private var refreshTask: Task<Void, Never>?
    /// Re-reads every card, one file at a time at utility priority: a long list must not occupy
    /// the concurrency pool that preview rebuilds, imports and exports run on. Existing cards
    /// keep showing until their fresh result lands.
    func refresh() {
        refreshTask?.cancel()
        let entries = history.entries
        for entry in entries where status[entry.path] == nil { status[entry.path] = .loading }
        refreshTask = Task { [weak self] in
            for entry in entries {
                if Task.isCancelled { return }
                let result = await Task.detached(priority: .utility) { Self.read(entry) }.value
                if Task.isCancelled { return }
                self?.apply(result)
            }
        }
    }

    private struct LoadResult: Sendable {
        enum Outcome: Sendable { case ready(ProjectSummary, Date?, Data?), missing, unreadable(String) }
        let path: String
        let relocatedTo: String?
        let bookmark: Data?
        let outcome: Outcome
    }

    private func apply(_ result: LoadResult) {
        var path = result.path
        if let moved = result.relocatedTo {
            history.relocate(path, to: moved, bookmark: result.bookmark); persist()
            status[path] = nil; posters[path] = nil
            path = ProjectHistory.normalized(moved)
        }
        guard history.entries.contains(where: { $0.path == path }) else { return }
        switch result.outcome {
        case let .ready(summary, modified, poster):
            status[path] = .ready(summary, modified: modified)
            if let poster, let image = NSImage(data: poster) { posters[path] = image } else { posters[path] = nil }
        case .missing: status[path] = .missing; posters[path] = nil
        case let .unreadable(message): status[path] = .unreadable(message); posters[path] = nil
        }
    }

    private nonisolated static func read(_ entry: ProjectHistory.Entry) -> LoadResult {
        let files = FileManager.default
        var url = URL(fileURLWithPath: entry.path)
        var relocated: String?, fresh: Data?
        if !files.fileExists(atPath: url.path) {
            guard let bookmark = entry.bookmark else { return LoadResult(path: entry.path, relocatedTo: nil, bookmark: nil, outcome: .missing) }
            var stale = false
            guard let found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
                  files.fileExists(atPath: found.path) else {
                return LoadResult(path: entry.path, relocatedTo: nil, bookmark: nil, outcome: .missing)
            }
            url = found; relocated = found.path
            fresh = try? found.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        do {
            let project = try ProjectFile.decode(Data(contentsOf: url))
            let summary = ProjectSummary(project)
            let modified = (try? files.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return LoadResult(path: entry.path, relocatedTo: relocated, bookmark: fresh,
                              outcome: .ready(summary, modified, poster(for: summary)))
        } catch {
            return LoadResult(path: entry.path, relocatedTo: relocated, bookmark: fresh, outcome: .unreadable(error.localizedDescription))
        }
    }

    /// Reuses the library's cached thumbnail rather than decoding video. The cache is keyed by the
    /// source's path, size and mtime, so a source that moved or changed simply has no poster.
    private nonisolated static func poster(for summary: ProjectSummary) -> Data? {
        guard let path = summary.posterMediaPath, FileManager.default.fileExists(atPath: path) else { return nil }
        let key = MediaPaths.key(for: URL(fileURLWithPath: path))
        return try? Data(contentsOf: MediaPaths.cache.appendingPathComponent(key + ".jpg"))
    }
}
