import Foundation

/// The transitions Ara draws (after the usual open-source editor sets: gl-transitions, FFmpeg
/// xfade, MLT luma, Olive, Blender VSE). Each also works one-sided at a clip's free edge, where the
/// missing picture is whatever the tracks below show.
public enum TransitionKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case crossDissolve, dipToBlack, dipToWhite, blur, push, slide, whipPan, zoom, wipe, iris, pixelate
    public enum Category: String, CaseIterable, Sendable { case dissolve = "Dissolve", motion = "Motion", wipe = "Wipe", stylize = "Stylize" }
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .crossDissolve: "Cross Dissolve"
        case .dipToBlack: "Dip to Black"
        case .dipToWhite: "Dip to White"
        case .blur: "Blur"
        case .push: "Push"
        case .slide: "Slide"
        case .whipPan: "Whip Pan"
        case .zoom: "Zoom"
        case .wipe: "Wipe"
        case .iris: "Iris"
        case .pixelate: "Pixelate"
        }
    }
    public var category: Category {
        switch self {
        case .crossDissolve, .dipToBlack, .dipToWhite: .dissolve
        case .push, .slide, .whipPan, .zoom: .motion
        case .wipe, .iris: .wipe
        case .blur, .pixelate: .stylize
        }
    }
    public var defaultDuration: MediaTime {
        switch self {
        case .crossDissolve, .dipToBlack, .wipe, .iris: MediaTime(seconds:1)
        case .dipToWhite: MediaTime(seconds:0.5)
        case .blur, .pixelate: MediaTime(seconds:0.8)
        case .push, .slide, .zoom: MediaTime(seconds:0.7)
        case .whipPan: MediaTime(seconds:0.4)
        }
    }
    /// Push, slide, whip pan and wipe move one way; the others have no direction.
    public var hasDirection: Bool { self == .push || self == .slide || self == .whipPan || self == .wipe }
    /// Everything but the dips shows both clips at once across a cut, so it needs frames from
    /// beyond each clip's edge. A dip shows one clip at a time and switches at the cut.
    public var needsBothPictures: Bool { self != .dipToBlack && self != .dipToWhite }
}

/// The way a push, slide, whip pan or wipe travels.
public enum TransitionDirection: String, Codable, CaseIterable, Sendable, Identifiable {
    case left, right, up, down
    public var id: String { rawValue }
}

/// A transition on a clip edge. With both clips it spans the cut between them (they must abut on
/// one track); with only `to` it fades that clip in, with only `from` it fades it out.
public struct Transition: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var kind: TransitionKind
    public var direction: TransitionDirection = .left
    public var duration: MediaTime
    /// The clip that ends where the transition sits (outgoing).
    public var from: UUID?
    /// The clip that begins where the transition sits (incoming).
    public var to: UUID?
    public init(kind: TransitionKind, direction: TransitionDirection = .left, duration: MediaTime, from: UUID?, to: UUID?) {
        self.kind = kind; self.direction = direction; self.duration = duration; self.from = from; self.to = to
    }
    private enum CodingKeys: String, CodingKey { case id, kind, direction, duration, from, to }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        // A kind or direction this version does not know (from a newer Ara) opens as a dissolve
        // rather than refusing the whole document.
        id = try c.decode(UUID.self,forKey:.id)
        kind = (try? c.decode(TransitionKind.self,forKey:.kind)) ?? .crossDissolve
        direction = (try? c.decodeIfPresent(TransitionDirection.self,forKey:.direction)) ?? .left
        duration = try c.decode(MediaTime.self,forKey:.duration)
        from = try c.decodeIfPresent(UUID.self,forKey:.from); to = try c.decodeIfPresent(UUID.self,forKey:.to)
    }
    public static let longest = MediaTime(seconds: 5)
    public static let standard = MediaTime(seconds: 1)
    public var isCut: Bool { from != nil && to != nil }
}

/// Where a transition plays on the timeline, and how much of it lies in each clip.
public struct TransitionWindow: Hashable, Sendable {
    public let start: MediaTime
    public let duration: MediaTime
    public var end: MediaTime { start + duration }
    /// Portion before the edit point (inside or past the outgoing clip) and after it.
    public let before: MediaTime
    public let after: MediaTime
}

public extension Project {
    /// Centred on a cut (the extra frame, for an odd length, falls after the cut); inside the
    /// clip for a fade in or out.
    func window(of transition: Transition) -> TransitionWindow? {
        let d = frameRate.quantize(transition.duration)
        if let a = transition.from.flatMap(clip), let b = transition.to.flatMap(clip) {
            guard a.lane == b.lane, a.end == b.start else { return nil }
            let before = frameRate.floor(MediaTime(ticks: d.ticks / 2))
            return TransitionWindow(start: a.end - before, duration: d, before: before, after: d - before)
        }
        if let b = transition.to.flatMap(clip), transition.from == nil { return TransitionWindow(start: b.start, duration: d, before: .zero, after: d) }
        if let a = transition.from.flatMap(clip), transition.to == nil { return TransitionWindow(start: a.end - d, duration: d, before: d, after: .zero) }
        return nil
    }
    func clip(_ id: UUID) -> Clip? { clips.first { $0.id == id } }
    /// The transition on a clip's start (`incoming`) or end, if any.
    func transition(into id: UUID) -> Transition? { transitions.first { $0.to == id } }
    func transition(outOf id: UUID) -> Transition? { transitions.first { $0.from == id } }
    /// How long a transition on this edge can be: each clip must hold its share, and a clip's
    /// two transitions may not overlap.
    func longestTransition(from: UUID?, to: UUID?) -> MediaTime {
        var limit = Transition.longest
        func room(_ id: UUID, excluding other: Transition?) -> MediaTime {
            guard let clip = clip(id) else { return .zero }
            var used = MediaTime.zero
            if let other, let window = window(of: other) { used = other.to == id ? window.after : window.before }
            return clip.duration - used
        }
        if let from, let to {
            // Each side holds about half; allow what both sides have room for.
            let a = room(from, excluding: transition(into: from)), b = room(to, excluding: transition(outOf: to))
            limit = min(limit, MediaTime(ticks: min(a.ticks, b.ticks) * 2))
        } else if let to {
            limit = min(limit, room(to, excluding: transition(outOf: to)))
        } else if let from {
            limit = min(limit, room(from, excluding: transition(into: from)))
        }
        return limit > .zero ? frameRate.floor(limit) : .zero
    }
    /// Drops transitions whose clips are gone or no longer meet, and shortens any that no longer
    /// fit their clips. Edits call this through `validated()`, so moving, trimming or deleting a
    /// clip never leaves a transition dangling. When a clip's two transitions no longer both fit,
    /// both shrink in proportion; one is dropped only when not even a frame of it fits.
    func reconcilingTransitions() -> Project {
        var result = self
        let frame = frameRate.frame
        // 1. Keep transitions whose clips exist, are visual and still meet; one per clip edge; a
        //    fresh id for any id seen twice (only a damaged document has one).
        var kept: [Transition] = []
        var seenIn = Set<UUID>(), seenOut = Set<UUID>(), seenIDs = Set<UUID>()
        for var transition in transitions {
            guard transition.from != nil || transition.to != nil else { continue }
            let a = transition.from.flatMap(clip), b = transition.to.flatMap(clip)
            if transition.from != nil && a == nil { continue }
            if transition.to != nil && b == nil { continue }
            if let a, !a.lane.isVideo { continue }
            if let b, !b.lane.isVideo { continue }
            if let a, let b, a.lane != b.lane || a.end != b.start { continue }
            if let from = transition.from, seenOut.contains(from) { continue }
            if let to = transition.to, seenIn.contains(to) { continue }
            if seenIDs.contains(transition.id) { transition.id = UUID() }
            seenIDs.insert(transition.id)
            transition.duration = max(frame,min(frameRate.quantize(transition.duration),Transition.longest))
            kept.append(transition)
            if let from = transition.from { seenOut.insert(from) }
            if let to = transition.to { seenIn.insert(to) }
        }
        // 2. Fit: each clip must hold its share of both of its transitions. Shrink by the tightest
        //    clip's ratio, a few rounds (a cut shares two clips), then drop what cannot hold a frame.
        for _ in 0..<4 {
            result.transitions = kept
            var worst: [UUID:Double] = [:]
            for clip in clips where clip.lane.isVideo {
                var used = MediaTime.zero
                if let t = result.transition(into:clip.id), let w = result.window(of:t) { used = used+w.after }
                if let t = result.transition(outOf:clip.id), let w = result.window(of:t) { used = used+w.before }
                guard used > clip.duration, used.ticks > 0 else { continue }
                let ratio = Double(clip.duration.ticks)/Double(used.ticks)
                for t in [result.transition(into:clip.id),result.transition(outOf:clip.id)].compactMap({ $0 }) { worst[t.id] = min(worst[t.id] ?? 1,ratio) }
            }
            guard !worst.isEmpty else { break }
            for i in kept.indices {
                guard let ratio = worst[kept[i].id] else { continue }
                // Round down to whole frames, and to an even count across a cut so each side's
                // share (half, the odd frame after the cut) stays inside the ratio.
                var frames = Int64((Double(kept[i].duration.ticks)*ratio)/Double(frame.ticks))
                if kept[i].isCut && frames > 1 { frames -= frames % 2 }
                kept[i].duration = MediaTime(ticks:max(0,frames)*frame.ticks)
            }
            kept.removeAll { $0.duration < frame }
        }
        result.transitions = kept
        return result
    }
}

public extension Editing {
    /// The clip edge at `time` on `lane`: the cut between two abutting clips, or one clip's start
    /// or end. Nil when no clip begins or ends there.
    static func edge(on lane: Lane, at time: MediaTime, in project: Project) -> (from: UUID?, to: UUID?)? {
        guard lane.isVideo else { return nil }
        let onLane = project.clips.filter { $0.lane == lane }
        let ending = onLane.first { $0.end == time }, starting = onLane.first { $0.start == time }
        guard ending != nil || starting != nil else { return nil }
        return (ending?.id, starting?.id)
    }
    /// Adds a transition on an edge, or replaces the one already there. The length is fitted to
    /// the clips; it never overlaps the clip's other transition.
    @discardableResult
    static func setTransition(_ kind: TransitionKind, direction: TransitionDirection = .left, duration: MediaTime? = nil, from: UUID?, to: UUID?, in project: inout Project) throws -> UUID {
        let duration = duration ?? kind.defaultDuration
        guard from != nil || to != nil else { throw EditError("Choose a clip edge for the transition.") }
        var candidate = project
        let existing = candidate.transitions.firstIndex { $0.from == from && $0.to == to }
        // A clip edge holds one transition: replacing a fade with a cut transition (or back).
        candidate.transitions.removeAll { t in (from != nil && t.from == from) || (to != nil && t.to == to) }
        for id in [from, to].compactMap({ $0 }) {
            guard let clip = candidate.clip(id), clip.lane.isVideo else { throw EditError("Transitions go on video, image and title clips.") }
        }
        if let from, let to {
            guard let a = candidate.clip(from), let b = candidate.clip(to), a.lane == b.lane, a.end == b.start else { throw EditError("A transition between clips needs them to meet on the same track.") }
        }
        var transition = Transition(kind: kind, direction: direction, duration: duration, from: from, to: to)
        if let existing { transition.id = project.transitions[existing].id }
        transition.duration = min(candidate.frameRate.quantize(duration), candidate.longestTransition(from: from, to: to))
        guard transition.duration >= candidate.frameRate.frame else { throw EditError("These clips are too short for a transition.") }
        candidate.transitions.append(transition)
        project = try candidate.validated()
        return transition.id
    }
    static func updateTransition(_ id: UUID, kind: TransitionKind? = nil, direction: TransitionDirection? = nil, duration: MediaTime? = nil, in project: inout Project) throws {
        guard let index = project.transitions.firstIndex(where: { $0.id == id }) else { return }
        var candidate = project
        if let kind { candidate.transitions[index].kind = kind }
        if let direction { candidate.transitions[index].direction = direction }
        if let duration {
            let t = candidate.transitions[index]
            var others = candidate; others.transitions.remove(at: index)
            candidate.transitions[index].duration = max(candidate.frameRate.frame, min(candidate.frameRate.quantize(duration), others.longestTransition(from: t.from, to: t.to)))
        }
        project = try candidate.validated()
    }
    static func removeTransition(_ id: UUID, from project: inout Project) {
        project.transitions.removeAll { $0.id == id }
    }
}
