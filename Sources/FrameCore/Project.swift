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
    /// PostScript name of the title's font (a face, not a family: "GmarketSansBold").
    public var fontName = ClipStyle.defaultFontName
    /// Font size relative to a 1080-pixel short edge, scales proportionally for 4K.
    public var fontSize: Double = 72
    public var red: Double = 1
    public var green: Double = 1
    public var blue: Double = 1
    /// Title outline, drawn outside the letters (it never eats into them), in points at a
    /// 1080-pixel short edge like fontSize. 0 is no outline.
    public var outlineWidth: Double = 0
    public var outlineRed: Double = 0
    public var outlineGreen: Double = 0
    public var outlineBlue: Double = 0
    /// Title drop shadow, cast once by the letters and their outline together. 0 opacity is none.
    /// Distance and blur are points at a 1080-pixel short edge; the angle is the direction the
    /// shadow falls, clockwise from the right as seen on screen (45° is down and to the right).
    public var shadowOpacity: Double = 0
    public var shadowDistance: Double = 6
    public var shadowAngle: Double = 45
    public var shadowBlur: Double = 8
    public var shadowRed: Double = 0
    public var shadowGreen: Double = 0
    public var shadowBlue: Double = 0
    /// The clip's alignment point (anchor), from its centre, as a share of its width and height
    /// (right and down positive; ±0.5 is an edge, and it may lie outside the clip, up to ±10).
    /// Rotation and pinch turn and scale about it,
    /// and moving lines it up with other clips' anchors. It changes no pixel of the picture.
    public var anchorX: Double = 0
    public var anchorY: Double = 0
    public var hasAnchor: Bool { anchorX != 0 || anchorY != 0 }
    /// How far outside the clip the alignment point may go, in clip widths and heights.
    public static let anchorReach = 10.0
    public static let defaultFontName = "HelveticaNeue-Bold"
    public var hasOutline: Bool { outlineWidth > 0 }
    public var hasShadow: Bool { shadowOpacity > 0 }
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case x, y, scale, rotation, opacity, brightness, contrast, saturation, volume, muted, text, fontName, fontSize, red, green, blue
        case outlineWidth, outlineRed, outlineGreen, outlineBlue
        case shadowOpacity, shadowDistance, shadowAngle, shadowBlur, shadowRed, shadowGreen, shadowBlue
        case anchorX, anchorY
    }
    /// Documents from before fonts could be chosen have no font name: they keep the font they
    /// were made with.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        x = try c.decode(Double.self,forKey:.x); y = try c.decode(Double.self,forKey:.y)
        scale = try c.decode(Double.self,forKey:.scale); rotation = try c.decode(Double.self,forKey:.rotation)
        opacity = try c.decode(Double.self,forKey:.opacity); brightness = try c.decode(Double.self,forKey:.brightness)
        contrast = try c.decode(Double.self,forKey:.contrast); saturation = try c.decode(Double.self,forKey:.saturation)
        volume = try c.decode(Double.self,forKey:.volume); muted = try c.decode(Bool.self,forKey:.muted)
        text = try c.decode(String.self,forKey:.text)
        fontName = try c.decodeIfPresent(String.self,forKey:.fontName) ?? Self.defaultFontName
        fontSize = try c.decode(Double.self,forKey:.fontSize)
        red = try c.decode(Double.self,forKey:.red); green = try c.decode(Double.self,forKey:.green); blue = try c.decode(Double.self,forKey:.blue)
        // Documents from before outlines and shadows: titles without either.
        func optional(_ key: CodingKeys, _ fallback: Double) throws -> Double { try c.decodeIfPresent(Double.self,forKey:key) ?? fallback }
        outlineWidth = try optional(.outlineWidth,0)
        outlineRed = try optional(.outlineRed,0); outlineGreen = try optional(.outlineGreen,0); outlineBlue = try optional(.outlineBlue,0)
        shadowOpacity = try optional(.shadowOpacity,0); shadowDistance = try optional(.shadowDistance,6)
        shadowAngle = try optional(.shadowAngle,45); shadowBlur = try optional(.shadowBlur,8)
        shadowRed = try optional(.shadowRed,0); shadowGreen = try optional(.shadowGreen,0); shadowBlue = try optional(.shadowBlue,0)
        // Documents from before anchors: the centre.
        anchorX = try optional(.anchorX,0); anchorY = try optional(.anchorY,0)
    }
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
    /// The source length a retimed clip was given, when whole frames at its speed use a little
    /// less (150 frames at 4x last 37 frames and use 148). The next speed change starts from it,
    /// so going back to 1x gives the same frames back, also after a frame rate change. Edits that
    /// change the source range clear it; older versions ignore it.
    public var retimedSourceLength: MediaTime?
    /// The favourite clip this one was put in from: the timeline marks it with a star. Older
    /// versions ignore it.
    public var favoriteID: UUID?
    public var end: MediaTime { start + duration }
    /// How much of the source this clip consumes. Equal to `duration` at 1x.
    public var sourceLength: MediaTime { speed == 1 ? duration : duration.scaled(by: speed) }
    /// Whether `length` still describes the source this clip was given (`retimedSourceLength`): no
    /// less than it uses, and no more than whole frames at its speed leave out, through a change of
    /// frame rate since (under a frame of the slowest rate for each).
    public func wasGiven(_ length: MediaTime) -> Bool {
        length >= sourceLength && length - sourceLength <= FrameRate.longestFrame.scaled(by: 2 * speed)
    }
    /// 0.1x–10x: presets up to 5x, and any value typed in between.
    public static let speedRange: ClosedRange<Double> = 0.1...10
    public init(mediaID: UUID? = nil, name: String, kind: MediaKind, lane: Lane, start: MediaTime,
                sourceStart: MediaTime = .zero, duration: MediaTime, speed: Double = 1, linkID: UUID? = nil) {
        self.mediaID = mediaID; self.name = name; self.kind = kind; self.lane = lane; self.start = start
        self.sourceStart = sourceStart; self.duration = duration; self.speed = speed; self.linkID = linkID
    }
    private enum CodingKeys: String, CodingKey { case id, mediaID, name, kind, lane, start, sourceStart, duration, speed, linkID, style, retimedSourceLength, favoriteID }
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
        retimedSourceLength = try c.decodeIfPresent(MediaTime.self, forKey: .retimedSourceLength)
        favoriteID = try c.decodeIfPresent(UUID.self, forKey: .favoriteID)
    }
}

public struct Project: Codable, Hashable, Sendable {
    public var version = 2
    public var id = UUID()
    public var name = "Untitled"
    public var frameRate = FrameRate(30)
    public var aspectRatio = VideoAspectRatio.landscape
    /// Output preset's short edge; preview rendering can remain at 1080 for responsiveness.
    public var outputResolution = 1080
    public var media: [MediaReference] = []
    public var clips: [Clip] = []
    /// How many video and audio tracks the timeline has. Documents from before adjustable tracks
    /// carry neither and get the original two of each.
    public var videoTrackCount = 2
    public var audioTrackCount = 2
    /// Transitions on clip edges (see Transition). Older documents have none.
    public var transitions: [Transition] = []
    public static let trackCounts = 2...8
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, id, name, frameRate, aspectRatio, outputResolution, media, clips, videoTrackCount, audioTrackCount, transitions }
    /// Hand-written so the track counts can be absent: synthesized decoding ignores defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        version = try c.decode(Int.self,forKey:.version)
        guard (1...2).contains(version) else { throw EditError("This project version is not supported (\(version)).") }
        // Version 1 was always 16:9. Upgrade in memory; saving uses version 2 so older apps
        // cannot silently open a portrait project as landscape.
        aspectRatio = version == 1 ? .landscape : try c.decode(VideoAspectRatio.self,forKey:.aspectRatio)
        version = 2
        id = try c.decode(UUID.self,forKey:.id)
        name = try c.decode(String.self,forKey:.name)
        frameRate = try c.decode(FrameRate.self,forKey:.frameRate)
        outputResolution = try c.decodeIfPresent(Int.self,forKey:.outputResolution) ?? 1080
        media = try c.decode([MediaReference].self,forKey:.media)
        clips = try c.decode([Clip].self,forKey:.clips)
        videoTrackCount = try c.decodeIfPresent(Int.self,forKey:.videoTrackCount) ?? 2
        audioTrackCount = try c.decodeIfPresent(Int.self,forKey:.audioTrackCount) ?? 2
        transitions = try c.decodeIfPresent([Transition].self,forKey:.transitions) ?? []
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
    /// The clips of every group in `ids` (each clip with its linked partner), in one pass: asking
    /// `group(for:)` once per clip searches the whole timeline for each of them.
    public func groupIDs(for ids: Set<UUID>) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        var links = Set<UUID>()
        for clip in clips where ids.contains(clip.id) { if let link = clip.linkID { links.insert(link) } }
        return Set(clips.lazy.filter { ids.contains($0.id) || $0.linkID.map(links.contains) == true }.map(\.id))
    }
    /// A video or audio clip may end less than one frame (at its speed) after its source does:
    /// rounding its cuts to a new frame rate can take them there (a trim never does, see
    /// `Editing.trim`). Its last frame is held and its sound is silent for that remainder.
    public func fitsSource(_ clip: Clip, of asset: MediaReference) -> Bool {
        clip.sourceStart + clip.sourceLength < asset.duration + frameRate.frame.scaled(by: clip.speed)
    }
    public func validated() throws -> Project {
        guard version == 2 else { throw EditError("This project version is not supported (\(version)).") }
        guard FrameRate.supported.contains(frameRate) else { throw EditError("Unsupported project frame rate.") }
        guard OutputQuality.resolutions.contains(outputResolution) else { throw EditError("Choose an output quality from HD to 4K.") }
        guard Set(media.map(\.id)).count == media.count, Set(clips.map(\.id)).count == clips.count else { throw EditError("Duplicate identifiers in project.") }
        guard Self.trackCounts.contains(videoTrackCount), Self.trackCounts.contains(audioTrackCount) else { throw EditError("Invalid track count.") }
        for media in media {
            guard media.duration.ticks >= 0, media.duration.seconds < 7 * 86400,
                  media.width >= 0, media.height >= 0, media.frameRate.isFinite else { throw EditError("Invalid media metadata.") }
        }
        // Looked up once per clip: searching the list for each one made validation quadratic.
        let assets = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
        for clip in clips {
            // Bound every decoded operand before adding times; malformed JSON must never trap on overflow.
            let limit = Int64(7 * 86400) * MediaTime.scale
            guard (0..<limit).contains(clip.start.ticks), (0..<limit).contains(clip.sourceStart.ticks),
                  (frameRate.frame.ticks..<limit).contains(clip.duration.ticks),
                  clip.end.seconds < 7 * 86400, clip.retimedSourceLength.map({ (0..<limit).contains($0.ticks) }) ?? true,
                  clip.lane.isVideo == (clip.kind != .audio), hasLane(clip.lane) else { throw EditError("Invalid clip timing or track.") }
            // Bound speed before any multiplication: sourceLength feeds Int64 arithmetic below.
            guard clip.speed.isFinite, Clip.speedRange.contains(clip.speed) else { throw EditError("Clip speed must be between 0.1x and 10x.") }
            guard clip.kind == .video || clip.kind == .audio || clip.speed == 1 else { throw EditError("Only video and audio clips can be retimed.") }
            guard clip.start == frameRate.quantize(clip.start), clip.duration == frameRate.quantize(clip.duration) else { throw EditError("Clip timing is off the project frame grid.") }
            if clip.kind != .text {
                guard let asset = clip.mediaID.flatMap({ assets[$0] }), asset.kind == clip.kind || (clip.kind == .audio && asset.hasAudio) else { throw EditError("Clip references invalid media.") }
                if clip.kind == .audio || clip.kind == .video {
                    guard (0..<limit).contains(clip.sourceLength.ticks), fitsSource(clip, of: asset) else { throw EditError("Clip exceeds its source duration.") }
                }
            }
            let s = clip.style
            guard [s.x,s.y,s.scale,s.rotation,s.opacity,s.brightness,s.contrast,s.saturation,s.volume,s.fontSize,s.red,s.green,s.blue].allSatisfy(\.isFinite),
                  (0.05...4).contains(s.scale), (0...1).contains(s.opacity), (0...4).contains(s.volume),
                  (-1...1).contains(s.brightness), (0...3).contains(s.contrast), (0...3).contains(s.saturation),
                  (8...300).contains(s.fontSize), s.text.count <= 2000,
                  !s.fontName.isEmpty, s.fontName.count <= 255, !s.fontName.contains(where: \.isNewline) else { throw EditError("Invalid clip properties.") }
            guard (-2...2).contains(s.x), (-2...2).contains(s.y), (-360...360).contains(s.rotation),
                  [s.red,s.green,s.blue].allSatisfy({ (0...1).contains($0) }) else { throw EditError("Invalid transform or text color.") }
            let effects = [s.outlineWidth,s.outlineRed,s.outlineGreen,s.outlineBlue,s.shadowOpacity,s.shadowDistance,s.shadowAngle,s.shadowBlur,s.shadowRed,s.shadowGreen,s.shadowBlue]
            guard effects.allSatisfy(\.isFinite), (0...20).contains(s.outlineWidth), (0...1).contains(s.shadowOpacity),
                  (0...40).contains(s.shadowDistance), (-180...180).contains(s.shadowAngle), (0...40).contains(s.shadowBlur),
                  [s.outlineRed,s.outlineGreen,s.outlineBlue,s.shadowRed,s.shadowGreen,s.shadowBlue].allSatisfy({ (0...1).contains($0) }) else {
                throw EditError("Invalid title outline or shadow.")
            }
            guard s.anchorX.isFinite, s.anchorY.isFinite, (-ClipStyle.anchorReach...ClipStyle.anchorReach).contains(s.anchorX), (-ClipStyle.anchorReach...ClipStyle.anchorReach).contains(s.anchorY) else {
                throw EditError("Invalid alignment point.")
            }
        }
        let lanes = Dictionary(grouping: clips, by: \.lane)
        for lane in videoLanes+audioLanes {
            let sorted = (lanes[lane] ?? []).sorted { $0.start < $1.start }
            for pair in zip(sorted, sorted.dropFirst()) where pair.0.end > pair.1.start { throw EditError("Clips overlap on \(lane.rawValue). Use another track.") }
        }
        // Grouped once: filtering every clip for each link made validation quadratic in linked pairs.
        for group in Dictionary(grouping: clips.filter { $0.linkID != nil }, by: { $0.linkID! }).values {
            guard group.count == 2, let v = group.first(where: { $0.kind == .video }), let a = group.first(where: { $0.kind == .audio }),
                  v.mediaID == a.mediaID, v.start == a.start, v.duration == a.duration, v.sourceStart == a.sourceStart,
                  v.speed == a.speed, v.lane.paired == a.lane else { throw EditError("Linked video and audio are out of sync.") }
        }
        // Transitions follow their clips: any left dangling by an edit are dropped or shortened
        // (a clip holds at most two, so the count is bounded afterwards).
        let reconciled = reconcilingTransitions()
        guard reconciled.transitions.count <= clips.count*2 else { throw EditError("Invalid transitions.") }
        return reconciled
    }
}

public struct EditError: LocalizedError, Sendable {
    public let message: String
    /// In the app's language (its Localizable.strings), the values put into it included.
    public init(_ message: String.LocalizationValue) { self.message = String(localized: message) }
    /// Text that is final as it is: a message put together from parts that are localized already.
    public init(verbatim message: String) { self.message = message }
    /// A string made elsewhere (`String(localized:)` at the call site) is used as it is. A literal
    /// still goes through the table: this is disfavoured, as SwiftUI's `Text` does it.
    @_disfavoredOverload public init<S: StringProtocol>(_ message: S) { self.message = String(message) }
    public var errorDescription: String? { message }
}

public enum ProjectFile {
    public static func encode(_ project: Project) throws -> Data {
        let project = try project.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }
    public static func decode(_ data: Data) throws -> Project {
        guard data.count < 50_000_000 else { throw EditError("Project file is too large.") }
        return try JSONDecoder().decode(Project.self, from: data).validated()
    }
}
