import Foundation

public enum MediaKind: String, Codable, Sendable { case video, audio, image, text }
/// A timeline track: V1, V2, … (video; a higher number draws above a lower one) or A1, A2, …
/// (audio). Stored by name ("V3"), exactly as the four fixed tracks of earlier documents were,
/// so those open unchanged.
public struct Lane: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case video = "V", audio = "A" }
    public let kind: Kind
    public let number: Int
    public init(_ kind: Kind, _ number: Int) { self.kind = kind; self.number = number }
    public init?(rawValue: String) {
        guard let first = rawValue.first, let kind = Kind(rawValue:String(first)),
              let number = Int(rawValue.dropFirst()), (1...99).contains(number) else { return nil }
        self.init(kind,number)
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer(), name = try container.decode(String.self)
        guard let lane = Lane(rawValue:name) else { throw DecodingError.dataCorruptedError(in:container,debugDescription:"Unknown track \(name).") }
        self = lane
    }
    public func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public var rawValue: String { kind.rawValue+String(number) }
    public var id: String { rawValue }
    public var isVideo: Bool { kind == .video }
    /// Linked audio lives on the audio track with its video's number, and the other way round.
    public var paired: Lane { Lane(isVideo ? .audio : .video,number) }
    public static let v1 = Lane(.video,1), v2 = Lane(.video,2), a1 = Lane(.audio,1), a2 = Lane(.audio,2)
}

/// A selected empty range on one lane. Not part of the document: selection only.
public struct TimelineGap: Hashable, Sendable {
    public let lane: Lane
    public let start: MediaTime
    public let end: MediaTime
    public var duration: MediaTime { end - start }
    public init(lane: Lane, start: MediaTime, end: MediaTime) { self.lane = lane; self.start = start; self.end = end }
}

public struct MediaReference: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var path: String
    public var bookmark: Data?
    public var kind: MediaKind
    public var duration: MediaTime
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var hasAudio: Bool
    public init(name: String, path: String, bookmark: Data? = nil, kind: MediaKind, duration: MediaTime,
                width: Int = 0, height: Int = 0, frameRate: Double = 0, hasAudio: Bool = false) {
        self.name = name; self.path = path; self.bookmark = bookmark; self.kind = kind
        self.duration = duration; self.width = width; self.height = height
        self.frameRate = frameRate; self.hasAudio = hasAudio
    }
}

public struct ClipStyle: Codable, Hashable, Sendable {
    public var x: Double = 0
    public var y: Double = 0
    public var scale: Double = 1
    public var rotation: Double = 0
    public var opacity: Double = 1
    public var brightness: Double = 0
    public var contrast: Double = 1
    public var saturation: Double = 1
    public var volume: Double = 1
    public var muted = false
    public var text = "Your story starts here"
    /// Font size in a 1080-line canvas, scales proportionally for 4K.
    public var fontSize: Double = 72
    public var red: Double = 1
    public var green: Double = 1
    public var blue: Double = 1
    public init() {}
}

public struct Clip: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var mediaID: UUID?
    public var name: String
    public var kind: MediaKind
    public var lane: Lane
    public var start: MediaTime
    public var sourceStart: MediaTime
    /// Timeline length. With `speed` applied this is NOT the amount of source consumed.
    public var duration: MediaTime
    /// Timeline seconds per source second: 2 plays twice as fast and eats twice the source.
    public var speed: Double = 1
    public var linkID: UUID?
    public var style = ClipStyle()
    public var end: MediaTime { start + duration }
    /// How much of the source this clip consumes. Equal to `duration` at 1x.
    public var sourceLength: MediaTime { speed == 1 ? duration : duration.scaled(by: speed) }
    public static let speedRange: ClosedRange<Double> = 0.25...4
    public init(mediaID: UUID? = nil, name: String, kind: MediaKind, lane: Lane, start: MediaTime,
                sourceStart: MediaTime = .zero, duration: MediaTime, speed: Double = 1, linkID: UUID? = nil) {
        self.mediaID = mediaID; self.name = name; self.kind = kind; self.lane = lane; self.start = start
        self.sourceStart = sourceStart; self.duration = duration; self.speed = speed; self.linkID = linkID
    }
    private enum CodingKeys: String, CodingKey { case id, mediaID, name, kind, lane, start, sourceStart, duration, speed, linkID, style }
    /// Hand-written so documents saved before per-clip speed still load: Swift's synthesized
    /// decoder ignores stored-property defaults and would reject every older file.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        mediaID = try c.decodeIfPresent(UUID.self, forKey: .mediaID)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(MediaKind.self, forKey: .kind)
        lane = try c.decode(Lane.self, forKey: .lane)
        start = try c.decode(MediaTime.self, forKey: .start)
        sourceStart = try c.decode(MediaTime.self, forKey: .sourceStart)
        duration = try c.decode(MediaTime.self, forKey: .duration)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        linkID = try c.decodeIfPresent(UUID.self, forKey: .linkID)
        style = try c.decode(ClipStyle.self, forKey: .style)
    }
}

public struct Project: Codable, Hashable, Sendable {
    public var version = 1
    public var id = UUID()
    public var name = "Untitled"
    public var frameRate = FrameRate(30)
    public var media: [MediaReference] = []
    public var clips: [Clip] = []
    /// How many video and audio tracks the timeline has. Documents from before adjustable tracks
    /// carry neither and get the original two of each.
    public var videoTrackCount = 2
    public var audioTrackCount = 2
    public static let trackCounts = 2...8
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, id, name, frameRate, media, clips, videoTrackCount, audioTrackCount }
    /// Hand-written so the track counts can be absent: synthesized decoding ignores defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        version = try c.decode(Int.self,forKey:.version)
        id = try c.decode(UUID.self,forKey:.id)
        name = try c.decode(String.self,forKey:.name)
        frameRate = try c.decode(FrameRate.self,forKey:.frameRate)
        media = try c.decode([MediaReference].self,forKey:.media)
        clips = try c.decode([Clip].self,forKey:.clips)
        videoTrackCount = try c.decodeIfPresent(Int.self,forKey:.videoTrackCount) ?? 2
        audioTrackCount = try c.decodeIfPresent(Int.self,forKey:.audioTrackCount) ?? 2
    }
    public var videoLanes: [Lane] { (0..<max(0,videoTrackCount)).map { Lane(.video,$0+1) } }
    public var audioLanes: [Lane] { (0..<max(0,audioTrackCount)).map { Lane(.audio,$0+1) } }
    /// Top to bottom as the timeline shows them: the highest video track first, then A1 down.
    public var displayLanes: [Lane] { videoLanes.reversed()+audioLanes }
    public func hasLane(_ lane: Lane) -> Bool { lane.number >= 1 && lane.number <= (lane.isVideo ? videoTrackCount : audioTrackCount) }
    /// Adds tracks up to `lane` if it does not exist yet, as when linked audio follows its video
    /// to V3 and there is no A3. Refuses past the track limit.
    public mutating func ensureLane(_ lane: Lane) throws {
        guard !hasLane(lane) else { return }
        guard lane.number <= Self.trackCounts.upperBound else { throw EditError("A timeline has at most \(Self.trackCounts.upperBound) video and \(Self.trackCounts.upperBound) audio tracks.") }
        if lane.isVideo { videoTrackCount = lane.number } else { audioTrackCount = lane.number }
    }
    public var duration: MediaTime { clips.map(\.end).max() ?? .zero }
    public func media(for clip: Clip) -> MediaReference? { media.first { $0.id == clip.mediaID } }
    public func group(for id: UUID) -> [Clip] {
        guard let clip = clips.first(where: { $0.id == id }) else { return [] }
        guard let link = clip.linkID else { return [clip] }
        return clips.filter { $0.linkID == link }
    }
    public func validated() throws -> Project {
        guard version == 1 else { throw EditError("This project version is not supported (\(version)).") }
        guard FrameRate.supported.contains(frameRate) else { throw EditError("Unsupported project frame rate.") }
        guard Set(media.map(\.id)).count == media.count, Set(clips.map(\.id)).count == clips.count else { throw EditError("Duplicate identifiers in project.") }
        guard Self.trackCounts.contains(videoTrackCount), Self.trackCounts.contains(audioTrackCount) else { throw EditError("Invalid track count.") }
        for media in media {
            guard media.duration.ticks >= 0, media.duration.seconds < 7 * 86400,
                  media.width >= 0, media.height >= 0, media.frameRate.isFinite else { throw EditError("Invalid media metadata.") }
        }
        for clip in clips {
            // Bound every decoded operand before adding times; malformed JSON must never trap on overflow.
            let limit = Int64(7 * 86400) * MediaTime.scale
            guard (0..<limit).contains(clip.start.ticks), (0..<limit).contains(clip.sourceStart.ticks),
                  (frameRate.frame.ticks..<limit).contains(clip.duration.ticks),
                  clip.end.seconds < 7 * 86400,
                  clip.lane.isVideo == (clip.kind != .audio), hasLane(clip.lane) else { throw EditError("Invalid clip timing or track.") }
            // Bound speed before any multiplication: sourceLength feeds Int64 arithmetic below.
            guard clip.speed.isFinite, Clip.speedRange.contains(clip.speed) else { throw EditError("Clip speed must be between 25% and 400%.") }
            guard clip.kind == .video || clip.kind == .audio || clip.speed == 1 else { throw EditError("Only video and audio clips can be retimed.") }
            guard clip.start == frameRate.quantize(clip.start), clip.duration == frameRate.quantize(clip.duration) else { throw EditError("Clip timing is off the project frame grid.") }
            if clip.kind != .text {
                guard let asset = media(for: clip), asset.kind == clip.kind || (clip.kind == .audio && asset.hasAudio) else { throw EditError("Clip references invalid media.") }
                if clip.kind == .audio || clip.kind == .video {
                    guard (0..<limit).contains(clip.sourceLength.ticks),
                          clip.sourceStart + clip.sourceLength <= asset.duration else { throw EditError("Clip exceeds its source duration.") }
                }
            }
            let s = clip.style
            guard [s.x,s.y,s.scale,s.rotation,s.opacity,s.brightness,s.contrast,s.saturation,s.volume,s.fontSize,s.red,s.green,s.blue].allSatisfy(\.isFinite),
                  (0.05...4).contains(s.scale), (0...1).contains(s.opacity), (0...4).contains(s.volume),
                  (-1...1).contains(s.brightness), (0...3).contains(s.contrast), (0...3).contains(s.saturation),
                  (8...300).contains(s.fontSize), s.text.count <= 2000 else { throw EditError("Invalid clip properties.") }
            guard (-2...2).contains(s.x), (-2...2).contains(s.y), (-360...360).contains(s.rotation),
                  [s.red,s.green,s.blue].allSatisfy({ (0...1).contains($0) }) else { throw EditError("Invalid transform or text color.") }
        }
        for lane in videoLanes+audioLanes {
            let sorted = clips.filter { $0.lane == lane }.sorted { $0.start < $1.start }
            for pair in zip(sorted, sorted.dropFirst()) where pair.0.end > pair.1.start { throw EditError("Clips overlap on \(lane.rawValue). Use another track.") }
        }
        for link in Set(clips.compactMap(\.linkID)) {
            let group = clips.filter { $0.linkID == link }
            guard group.count == 2, let v = group.first(where: { $0.kind == .video }), let a = group.first(where: { $0.kind == .audio }),
                  v.mediaID == a.mediaID, v.start == a.start, v.duration == a.duration, v.sourceStart == a.sourceStart,
                  v.speed == a.speed, v.lane.paired == a.lane else { throw EditError("Linked video and audio are out of sync.") }
        }
        return self
    }
}

public struct EditError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ProjectFile {
    public static func encode(_ project: Project) throws -> Data {
        _ = try project.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }
    public static func decode(_ data: Data) throws -> Project {
        guard data.count < 50_000_000 else { throw EditError("Project file is too large.") }
        return try JSONDecoder().decode(Project.self, from: data).validated()
    }
}
