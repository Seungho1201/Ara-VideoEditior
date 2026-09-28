import Foundation

/// A value snapshot, independent of AppKit, live selection and later source edits.
/// Version 1 holds one clip and its linked partner; version 2 any number of clips (with their
/// partners), kept at their tracks and distances. One clip is still written as version 1, which
/// every Ara can paste.
public struct ClipClipboard: Codable, Equatable, Sendable {
    public var version = 1
    /// The most clips one copy takes.
    public static let maximumClips = 1000
    public let frameRate: FrameRate
    public let selectedID: UUID
    public let clips: [Clip]
    public let media: [MediaReference]

    public init(copying id: UUID, from project: Project) throws {
        _ = try project.validated()
        guard project.clips.contains(where: { $0.id == id }) else { throw EditError("Select a timeline clip to copy.") }
        frameRate = project.frameRate; selectedID = id; clips = project.group(for:id)
        let mediaIDs = Set(clips.filter { $0.kind != .text }.compactMap(\.mediaID))
        media = project.media.filter { mediaIDs.contains($0.id) }
    }
    /// Several clips (each with its linked partner). The earliest one is the anchor: it lands at
    /// the playhead and the rest keep their tracks and distances from it.
    public init(copying ids: [UUID], from project: Project) throws {
        _ = try project.validated()
        var chosen = Set<UUID>()
        for id in ids where project.clips.contains(where: { $0.id == id }) { chosen.formUnion(project.group(for:id).map(\.id)) }
        let clips = project.clips.filter { chosen.contains($0.id) }
        guard let anchor = clips.min(by: { ($0.start,$0.lane.isVideo ? 0 : 1,$0.lane.number) < ($1.start,$1.lane.isVideo ? 0 : 1,$1.lane.number) }) else {
            throw EditError("Select a timeline clip to copy.")
        }
        guard clips.count <= Self.maximumClips else { throw EditError("Copy at most \(Self.maximumClips) clips at once.") }
        frameRate = project.frameRate; selectedID = anchor.id; self.clips = clips
        version = project.group(for:anchor.id).count == clips.count ? 1 : 2
        let mediaIDs = Set(clips.filter { $0.kind != .text }.compactMap(\.mediaID))
        media = project.media.filter { mediaIDs.contains($0.id) }
    }

    public func validated() throws -> Self {
        guard (1...2).contains(version), (1...(version == 1 ? 2 : Self.maximumClips)).contains(clips.count),
              clips.contains(where: { $0.id == selectedID }) else {
            throw EditError("This clipboard does not contain supported Ara clips.")
        }
        var snapshot = Project(); snapshot.frameRate = frameRate; snapshot.clips = clips; snapshot.media = media
        // The copy may come from V3 or A5; the snapshot has whatever tracks its clips sit on.
        for clip in clips { try snapshot.ensureLane(clip.lane) }
        _ = try snapshot.validated()
        // Version 1 is exactly one group; version 2 any groups, each one whole.
        let ids = Set(clips.map(\.id))
        let whole = version == 1 ? snapshot.group(for:selectedID).count == clips.count
                                 : clips.allSatisfy { Set(snapshot.group(for:$0.id).map(\.id)).isSubset(of:ids) }
        guard whole, Set(media.map(\.id)) == Set(clips.filter { $0.kind != .text }.compactMap(\.mediaID)) else {
            throw EditError("The copied clip group is invalid.")
        }
        return self
    }

    /// The largest copy either side handles: a copy that could never be pasted is not made.
    public static let maximumBytes = 2_000_000
    public func encoded() throws -> Data {
        _ = try validated()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw EditError("Too much to copy at once. Copy fewer clips.") }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw EditError("The copied clip data is too large.") }
        return try JSONDecoder().decode(Self.self,from:data).validated()
    }
}

public extension Editing {
    /// Paste as one atomic edit, preserving source ranges and giving every copy fresh identities.
    static func paste(_ clipboard: ClipClipboard, at time: MediaTime, into project: inout Project) throws -> UUID {
        try pasteAll(clipboard,at:time,into:&project).anchor
    }
    /// As paste, returning every new clip too (the anchor's copy first).
    static func pasteAll(_ clipboard: ClipClipboard, at time: MediaTime, into project: inout Project) throws -> (anchor: UUID, clips: [UUID]) {
        let copied = try clipboard.validated()
        _ = try project.validated()
        guard copied.frameRate == project.frameRate else {
            throw EditError("Copied clips use \(copied.frameRate.label) fps. Paste into a project with the same frame rate.")
        }
        guard time.ticks >= 0, time.ticks < 7 * 86400 * MediaTime.scale else { throw EditError("Invalid paste position.") }
        let start = project.frameRate.quantize(time)
        let selected = copied.clips.first { $0.id == copied.selectedID }!
        var candidate = project
        var mediaIDs: [UUID:UUID] = [:]
        for source in copied.media {
            // Bookmark refreshes do not make a different source. A relinked media ID can,
            // so only reuse a reference whose actual source metadata still agrees.
            if let existing = candidate.media.first(where: {
                $0.path == source.path && $0.kind == source.kind && $0.duration == source.duration &&
                $0.width == source.width && $0.height == source.height && $0.frameRate == source.frameRate && $0.hasAudio == source.hasAudio
            }) { mediaIDs[source.id] = existing.id }
            else {
                var media = source
                if candidate.media.contains(where: { $0.id == media.id }) { media.id = UUID() }
                candidate.media.append(media); mediaIDs[source.id] = media.id
            }
        }
        var links: [UUID:UUID] = [:]
        var selectedCopy = UUID(), pasted: [UUID] = []
        for original in copied.clips {
            var clip = original; clip.id = UUID()
            if original.id == copied.selectedID { selectedCopy = clip.id } else { pasted.append(clip.id) }
            clip.start = start + (original.start-selected.start)
            if let id = original.mediaID { clip.mediaID = mediaIDs[id] }
            if let link = original.linkID {
                if links[link] == nil { links[link] = UUID() }
                clip.linkID = links[link]
            }
            // A clip copied from a track this timeline lacks brings the track along.
            try candidate.ensureLane(clip.lane)
            guard !project.clips.contains(where: { $0.lane == clip.lane && $0.start < clip.end && clip.start < $0.end }) else {
                throw EditError("Cannot paste: \(clip.lane.rawValue) is occupied here. Move the playhead to an empty range or the end of the timeline.")
            }
            candidate.clips.append(clip)
        }
        project = try candidate.validated()
        return (selectedCopy,[selectedCopy]+pasted)
    }
}
