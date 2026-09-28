import AppKit
import FrameCore

/// A validated library item placement. Free movement within a track is silent;
/// entering a track and acquiring an alignment are discrete tactile landmarks.
struct MediaDropTarget: Equatable {
    let id: UUID
    let lane: Lane
    let time: MediaTime
    let snappedTime: MediaTime?
}

struct MediaDropFeedback {
    private var previous: MediaDropTarget?
    private var lastCueAt = -Double.infinity
    private var lastAlignment: MediaDropTarget?
    private var lastAlignmentAt = -Double.infinity

    mutating func cue(for target: MediaDropTarget?, at timestamp: TimeInterval,
                      enabled: Bool) -> NSHapticFeedbackManager.FeedbackPattern? {
        defer { previous = target }
        guard enabled, let target else { return nil }
        let entered = previous?.id != target.id || previous?.lane != target.lane
        if target.snappedTime != nil, entered || previous?.snappedTime != target.snappedTime {
            // Suppress jitter off and back onto the same edge, without swallowing a
            // new alignment immediately after the lighter track-entry cue.
            guard lastAlignment != target || timestamp-lastAlignmentAt >= 0.18 else { return nil }
            lastAlignment = target; lastAlignmentAt = timestamp; lastCueAt = timestamp
            return .alignment
        }
        guard entered, timestamp-lastCueAt >= 0.08 else { return nil }
        lastCueAt = timestamp
        return .generic
    }
}

/// Something dragged catching a place: a clip or its edge snapping onto an edge, the playhead or
/// the start, or a transition from the library onto the clip edge it would go on. One alignment
/// tick as it lands there; nothing while it stays or moves freely, and the same place again only
/// after 0.18 s, so jitter across the edge is not felt as a buzz.
struct CatchFeedback<Target: Equatable> {
    private var current: Target?
    private var last: Target?
    private var lastAt = -Double.infinity

    mutating func cue(for target: Target?, at timestamp: TimeInterval, enabled: Bool) -> Bool {
        defer { current = target }
        guard enabled, let target, target != current else { return false }
        guard target != last || timestamp-lastAt >= 0.18 else { return false }
        last = target; lastAt = timestamp
        return true
    }
}
typealias SnapFeedback = CatchFeedback<MediaTime>
