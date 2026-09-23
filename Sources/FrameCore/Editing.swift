import Foundation

public enum Editing {
    public static func add(mediaID: UUID, lane: Lane, at time: MediaTime, to project: inout Project) throws -> UUID {
        guard let media = project.media.first(where: { $0.id == mediaID }) else { throw EditError("Media was not found.") }
        guard media.kind == .audio ? !lane.isVideo : lane.isVideo else { throw EditError("Drop video and images on a video track (V), and audio on an audio track (A).") }
        let duration = media.kind == .image ? project.frameRate.quantize(MediaTime(seconds: 5)) : project.frameRate.floor(media.duration)
        guard duration >= project.frameRate.frame else { throw EditError("Media is shorter than one project frame.") }
        let start = max(.zero, project.frameRate.quantize(time))
        let link = media.kind == .video && media.hasAudio ? UUID() : nil
        let clip = Clip(mediaID: media.id, name: media.name, kind: media.kind, lane: lane, start: start, duration: duration, linkID: link)
        var candidate = project
        guard candidate.hasLane(lane) else { throw EditError("\(lane.rawValue) does not exist. Add a track first.") }
        candidate.clips.append(clip)
        if let link {
            try candidate.ensureLane(lane.paired)
            candidate.clips.append(Clip(mediaID: media.id, name: media.name, kind: .audio, lane: lane.paired, start: start, duration: duration, linkID: link))
        }
        project = try candidate.validated()
        return clip.id
    }
    /// A new empty track above the top video track, or below the bottom audio track.
    @discardableResult public static func addTrack(_ kind: Lane.Kind, to project: inout Project) throws -> Lane {
        var candidate = project
        let lane = Lane(kind,(kind == .video ? candidate.videoTrackCount : candidate.audioTrackCount)+1)
        try candidate.ensureLane(lane)
        project = try candidate.validated()
        return lane
    }
    /// A three-second title at `time`, on the track just above every video clip it overlaps, so it
    /// is never drawn underneath one. V2 at the lowest (V1 is the picture). When that track does
    /// not exist yet it is added, up to the track limit.
    /// Removes an empty added track (V3/A3 and up). The tracks above it move down one number, and a
    /// linked partner moves with its clip so each pair keeps one number; if that lands on a busy
    /// spot, nothing is removed.
    public static func removeTrack(_ lane: Lane, from project: inout Project) throws {
        guard lane.number > Project.trackCounts.lowerBound, project.hasLane(lane) else { throw EditError("Only added tracks (V3 or A3 and up) can be removed.") }
        guard !project.clips.contains(where: { $0.lane == lane }) else { throw EditError("\(lane.rawValue) is not empty.") }
        var candidate = project
        let above = candidate.clips.filter { $0.lane.kind == lane.kind && $0.lane.number > lane.number }
        let links = Set(above.compactMap(\.linkID)), moving = Set(above.map(\.id))
        for i in candidate.clips.indices {
            let clip = candidate.clips[i]
            guard moving.contains(clip.id) || clip.linkID.map(links.contains) == true else { continue }
            candidate.clips[i].lane = Lane(clip.lane.kind,clip.lane.number-1)
        }
        if lane.isVideo { candidate.videoTrackCount -= 1 } else { candidate.audioTrackCount -= 1 }
        let result: Project
        do { result = try candidate.validated() }
        catch { throw EditError("\(lane.rawValue) cannot be removed here: linked \(lane.isVideo ? "audio" : "video") above it would move onto a busy \(lane.isVideo ? "A" : "V")\(lane.number).") }
        // Moving a linked partner can separate it from the clip it has a transition with.
        guard result.transitions.count == project.transitions.count else {
            throw EditError("\(lane.rawValue) cannot be removed: a transition above it would be lost when its clips move to different tracks.")
        }
        project = result
    }
    public static func addText(at time: MediaTime, to project: inout Project) throws -> UUID {
        let start = project.frameRate.quantize(max(.zero,time)), duration = project.frameRate.quantize(.init(seconds:3))
        let covering = project.clips.filter { $0.lane.isVideo && $0.start < start+duration && start < $0.end }.map(\.lane.number).max() ?? 0
        let lane = Lane(.video,max(2,covering+1))
        var candidate = project
        guard lane.number <= Project.trackCounts.upperBound else { throw EditError("Every video track is in use here. Move the playhead to add a title.") }
        try candidate.ensureLane(lane)
        let clip = Clip(name: "Title", kind: .text, lane: lane, start: start, duration: duration)
        candidate.clips.append(clip); project = try candidate.validated(); return clip.id
    }
    public static func move(_ id: UUID, to time: MediaTime, lane: Lane, in project: inout Project) throws {
        guard let selected = project.clips.first(where: { $0.id == id }), lane.isVideo == selected.lane.isVideo else { throw EditError("Incompatible track.") }
        let ids = Set(project.group(for: id).map(\.id))
        let delta = project.frameRate.quantize(max(.zero,time)) - selected.start
        var candidate = project
        guard candidate.hasLane(lane) else { throw EditError("\(lane.rawValue) does not exist. Add a track first.") }
        if ids.count > 1 { try candidate.ensureLane(lane.paired) }
        for i in candidate.clips.indices where ids.contains(candidate.clips[i].id) {
            candidate.clips[i].start = candidate.clips[i].start + delta
            candidate.clips[i].lane = candidate.clips[i].id == id ? lane : lane.paired
        }
        project = try candidate.validated()
    }
    public static func trim(_ id: UUID, leading: Bool, to boundary: MediaTime, in project: inout Project) throws {
        guard let selected = project.clips.first(where: { $0.id == id }) else { return }
        let ids = Set(project.group(for: id).map(\.id))
        let boundary = project.frameRate.quantize(boundary)
        let delta = boundary - (leading ? selected.start : selected.end)
        var candidate = project
        for i in candidate.clips.indices where ids.contains(candidate.clips[i].id) {
            if leading {
                candidate.clips[i].start = candidate.clips[i].start + delta
                // Source advances at the clip's own rate, so a retimed clip consumes delta*speed.
                if candidate.clips[i].kind == .video || candidate.clips[i].kind == .audio { candidate.clips[i].sourceStart = candidate.clips[i].sourceStart + delta.scaled(by: candidate.clips[i].speed) }
                candidate.clips[i].duration = candidate.clips[i].duration - delta
            } else { candidate.clips[i].duration = candidate.clips[i].duration + delta }
        }
        project = try candidate.validated()
    }
    public static func split(_ id: UUID, at time: MediaTime, in project: inout Project) throws {
        let group = project.group(for: id)
        guard let selected = group.first else { return }
        let time = project.frameRate.quantize(time)
        guard time > selected.start, time < selected.end else { throw EditError("Place the playhead inside the selected clip to split.") }
        let newLink = selected.linkID == nil ? nil : UUID()
        var candidate = project
        for clip in group {
            guard let i = candidate.clips.firstIndex(where: { $0.id == clip.id }) else { continue }
            let leftDuration = time - clip.start
            candidate.clips[i].duration = leftDuration
            var right = clip; right.id = UUID(); right.linkID = newLink; right.start = time
            // Pin the right half to the original source END. Head-anchoring instead
            // (sourceStart + round(L*speed)) can land a tick past the asset, because
            // round(L*s) + round(R*s) may exceed round((L+R)*s), and reject a legal split.
            if clip.kind == .video || clip.kind == .audio { right.sourceStart = clip.sourceStart + clip.sourceLength - (clip.duration - leftDuration).scaled(by: clip.speed) }
            right.duration = clip.duration - leftDuration
            candidate.clips.append(right)
            // The transition on the clip's end now belongs to the right-hand piece.
            for t in candidate.transitions.indices where candidate.transitions[t].from == clip.id { candidate.transitions[t].from = right.id }
        }
        project = try candidate.validated()
    }
    /// Retimes a clip while keeping the source content it already points at:
    /// the timeline length changes instead of the in/out points.
    /// `base` is the document a live drag started from. Resolving every sample against it keeps
    /// the operation idempotent: without it each slider sample re-quantises the previous sample's
    /// result and a 1x -> 4x -> 1x drag permanently eats source content.
    public static func setSpeed(_ id: UUID, to speed: Double, in project: inout Project, basedOn base: Project? = nil) throws {
        // A SwiftUI Slider lands on values like 1.0000000000000002, which defeats every `speed == 1`
        // fast path (Clip.sourceLength, the badge, the composition's no-scale branch).
        let speed = (speed * 1000).rounded() / 1000
        guard speed.isFinite, Clip.speedRange.contains(speed) else { throw EditError("Clip speed must be between 25% and 400%.") }
        let anchor = base ?? project
        guard let selected = anchor.clips.first(where: { $0.id == id }) else { return }
        guard selected.kind == .video || selected.kind == .audio else { throw EditError("Only video and audio clips can be retimed.") }
        let frame = project.frameRate.frame
        // floor, not quantize: floor(x) <= x, so the retimed clip can never round up past the source.
        var duration = project.frameRate.floor(selected.sourceLength.scaled(by: 1 / speed))
        if duration < frame { duration = frame }
        if let asset = project.media(for: selected) {
            while duration > frame, selected.sourceStart + duration.scaled(by: speed) > asset.duration { duration = duration - frame }
        }
        let ids = Set(project.group(for: id).map(\.id))
        var candidate = project
        // During a slider drag every sample starts from the drag's first snapshot, transitions
        // included: dragging away and back must not lose a transition a middle sample dropped.
        if let base { candidate.transitions = base.transitions }
        for i in candidate.clips.indices where ids.contains(candidate.clips[i].id) {
            candidate.clips[i].speed = speed
            candidate.clips[i].duration = duration
            candidate.clips[i].sourceStart = selected.sourceStart
        }
        project = try candidate.validated()
    }
    public static func delete(_ id: UUID, from project: inout Project) {
        let ids = Set(project.group(for: id).map(\.id)); project.clips.removeAll { ids.contains($0.id) }
    }
    /// The empty range on `lane` containing `time`, bounded by a following clip.
    /// Trailing space after the last clip is not a gap: there is nothing to close up against.
    public static func gap(on lane: Lane, at time: MediaTime, in project: Project) -> TimelineGap? {
        let onLane = project.clips.filter { $0.lane == lane }
        guard !onLane.contains(where: { time >= $0.start && time < $0.end }) else { return nil }
        guard let end = onLane.filter({ $0.start > time }).map(\.start).min() else { return nil }
        let start = onLane.filter { $0.end <= time }.map(\.end).max() ?? .zero
        return end > start ? TimelineGap(lane: lane, start: start, end: end) : nil
    }
    /// Ripple-closes a gap: every clip starting at or after it on that lane, and anything
    /// linked to those clips, moves earlier by the gap duration. Rejected as one unit.
    public static func closeGap(_ gap: TimelineGap, in project: inout Project) throws {
        guard gap.duration > .zero else { return }
        let following = project.clips.filter { $0.lane == gap.lane && $0.start >= gap.end }
        guard !following.isEmpty else { throw EditError("There is no clip after this gap to close up.") }
        var ids: Set<UUID> = []
        for clip in following { ids.formUnion(project.group(for: clip.id).map(\.id)) }
        var candidate = project
        for i in candidate.clips.indices where ids.contains(candidate.clips[i].id) {
            candidate.clips[i].start = candidate.clips[i].start - gap.duration
        }
        project = try candidate.validated()
    }
    public static func snapped(_ time: MediaTime, duration: MediaTime = .zero, excluding id: UUID? = nil,
                               playhead: MediaTime, threshold: MediaTime, project: Project) -> MediaTime {
        let excluded = Set(id.map { project.group(for: $0).map(\.id) } ?? [])
        let edges = [.zero,playhead] + project.clips.filter { !excluded.contains($0.id) }.flatMap { [$0.start,$0.end] }
        let candidates = edges.flatMap { [$0, $0 - duration] }.filter { $0 >= .zero && abs($0.ticks-time.ticks) <= threshold.ticks }
        return project.frameRate.quantize(candidates.min { abs($0.ticks-time.ticks) < abs($1.ticks-time.ticks) } ?? time)
    }
}

public struct EditHistory: Sendable {
    private var past: [(String, Project)] = []
    private var future: [(String, Project)] = []
    public init() {}
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var undoName: String { past.last?.0 ?? "" }
    public var redoName: String { future.last?.0 ?? "" }
    public mutating func record(_ project: Project, name: String) {
        past.append((name, project)); if past.count > 100 { past.removeFirst() }; future.removeAll()
    }
    public mutating func undo(_ current: Project) -> Project? {
        guard let entry = past.popLast() else { return nil }; future.append((entry.0,current)); return entry.1
    }
    public mutating func redo(_ current: Project) -> Project? {
        guard let entry = future.popLast() else { return nil }; past.append((entry.0,current)); return entry.1
    }
}
