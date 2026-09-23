import Foundation

/// A value snapshot, independent of AppKit, live selection and later source edits.
public struct ClipClipboard: Codable, Equatable, Sendable {
    public var version = 1
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

    public func validated() throws -> Self {
        guard version == 1, (1...2).contains(clips.count), clips.contains(where: { $0.id == selectedID }) else {
            throw EditError("This clipboard does not contain supported Ara clips.")
        }
        var snapshot = Project(); snapshot.frameRate = frameRate; snapshot.clips = clips; snapshot.media = media
        _ = try snapshot.validated()
        guard snapshot.group(for:selectedID).count == clips.count,
              Set(media.map(\.id)) == Set(clips.filter { $0.kind != .text }.compactMap(\.mediaID)) else {
            throw EditError("The copied clip group is invalid.")
        }
        return self
    }

    public func encoded() throws -> Data { _ = try validated(); return try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2_000_000 else { throw EditError("The copied clip data is too large.") }
        return try JSONDecoder().decode(Self.self,from:data).validated()
    }
}

public extension Editing {
    /// Paste as one atomic edit, preserving source ranges and giving every copy fresh identities.
    static func paste(_ clipboard: ClipClipboard, at time: MediaTime, into project: inout Project) throws -> UUID {
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
        var selectedCopy = UUID()
        for original in copied.clips {
            var clip = original; clip.id = UUID()
            if original.id == copied.selectedID { selectedCopy = clip.id }
            clip.start = start + (original.start-selected.start)
            if let id = original.mediaID { clip.mediaID = mediaIDs[id] }
            if let link = original.linkID {
                if links[link] == nil { links[link] = UUID() }
                clip.linkID = links[link]
            }
            guard !project.clips.contains(where: { $0.lane == clip.lane && $0.start < clip.end && clip.start < $0.end }) else {
                throw EditError("Cannot paste: \(clip.lane.rawValue) is occupied here. Move the playhead to an empty range or the end of the timeline.")
            }
            candidate.clips.append(clip)
        }
        project = try candidate.validated()
        return selectedCopy
    }
}
