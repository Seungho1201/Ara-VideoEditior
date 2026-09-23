import Foundation

/// The projects the user has opened or saved, most recent first.
///
/// Kept by the app rather than read from NSDocumentController: Ara is not an NSDocument app,
/// and its noteNewRecentDocumentURL calls are never persisted by the system, so the recent
/// documents list comes back empty on every launch.
public struct ProjectHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var path: String
        public var lastOpened: Date
        /// Follows the file if the user moves or renames it in Finder.
        public var bookmark: Data?
        public var id: String { path }
        public init(path: String, lastOpened: Date, bookmark: Data? = nil) {
            self.path = path; self.lastOpened = lastOpened; self.bookmark = bookmark
        }
    }
    public private(set) var entries: [Entry] = []
    public static let limit = 60

    public init(entries: [Entry] = []) {
        var seen = Set<String>()
        self.entries = entries.filter { seen.insert(Self.normalized($0.path)).inserted }.prefix(Self.limit).map { $0 }
    }
    /// One spelling per file, so the same project opened via a symlink or a trailing
    /// "./" never shows up twice.
    public static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    public mutating func record(_ path: String, at date: Date, bookmark: Data? = nil) {
        let path = Self.normalized(path)
        let previous = entries.first { $0.path == path }
        entries.removeAll { $0.path == path }
        entries.insert(Entry(path: path, lastOpened: date, bookmark: bookmark ?? previous?.bookmark), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }
    /// Adds project files found on disk without disturbing ones already listed, then keeps the
    /// whole list newest first so a folder of old projects does not bury recent work.
    public mutating func add(discovered: [(path: String, date: Date)]) {
        for item in discovered {
            let path = Self.normalized(item.path)
            guard !entries.contains(where: { $0.path == path }) else { continue }
            entries.append(Entry(path: path, lastOpened: item.date))
        }
        entries.sort { $0.lastOpened > $1.lastOpened }
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }
    /// Attaches a bookmark made later, off the main actor, without touching the order.
    public mutating func setBookmark(_ bookmark: Data, for path: String) {
        let path = Self.normalized(path)
        if let index = entries.firstIndex(where: { $0.path == path }) { entries[index].bookmark = bookmark }
    }
    public mutating func remove(_ path: String) {
        let path = Self.normalized(path)
        entries.removeAll { $0.path == path }
    }
    /// A file found at a new location through its bookmark keeps its place in the order.
    public mutating func relocate(_ oldPath: String, to newPath: String, bookmark: Data?) {
        let oldPath = Self.normalized(oldPath), newPath = Self.normalized(newPath)
        guard oldPath != newPath, entries.contains(where: { $0.path == oldPath }) else { return }
        entries.removeAll { $0.path == newPath }
        guard let index = entries.firstIndex(where: { $0.path == oldPath }) else { return }
        entries[index].path = newPath
        if let bookmark { entries[index].bookmark = bookmark }
    }
}

/// What the start screen shows for one project, read from the document without opening it.
public struct ProjectSummary: Equatable, Sendable {
    public let name: String
    public let frameRate: FrameRate
    /// Clips as the user sees them: linked source audio counts with its video.
    public let clipCount: Int
    public let mediaCount: Int
    public let duration: MediaTime
    /// A video or still to show as the card's poster, earliest on the picture lanes first.
    public let posterMediaPath: String?

    public init(_ project: Project) {
        name = project.name
        frameRate = project.frameRate
        clipCount = project.clips.filter { $0.kind != .audio || $0.linkID == nil }.count
        mediaCount = project.media.count
        duration = project.duration
        let visual = project.clips
            .filter { ($0.kind == .video || $0.kind == .image) && $0.lane.isVideo }
            .sorted { ($0.start, $0.lane == .v1 ? 0 : 1) < ($1.start, $1.lane == .v1 ? 0 : 1) }
        let firstUsed = visual.first.flatMap { project.media(for: $0) }
        posterMediaPath = (firstUsed ?? project.media.first { $0.kind == .video || $0.kind == .image })?.path
    }
}
