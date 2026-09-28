import Foundation

/// A navigation result, independent of the player and the pointer's pixel coordinates.
public struct ScrubPosition: Equatable, Sendable {
    public let time: MediaTime
    public let snappedEnd: MediaTime?
    public init(time: MediaTime, snappedEnd: MediaTime? = nil) {
        self.time = time; self.snappedEnd = snappedEnd
    }
}

public extension Project {
    /// Snap to an exclusive clip-end boundary within five project frames, from either side.
    /// Measure the unquantized pointer first: 5.1 frames away is outside the capture zone.
    /// Equal-distance ends resolve to the earlier one, regardless of track or storage order.
    func scrubPosition(at time: MediaTime, snapping: Bool = true) -> ScrubPosition {
        let pointer = max(.zero,time)
        let free = frameRate.quantize(min(pointer,duration))
        guard snapping else { return ScrubPosition(time:free) }
        let threshold = frameRate.frame.ticks * 5
        var nearest: MediaTime?
        var distance = Int64.max
        for clip in clips {
            let end = clip.end, delta = abs(end.ticks-pointer.ticks)
            if delta <= threshold && (delta < distance || (delta == distance && end < (nearest ?? end))) {
                nearest = end; distance = delta
            }
        }
        if let nearest { return ScrubPosition(time:nearest,snappedEnd:nearest) }
        return ScrubPosition(time:free)
    }
}

/// Coalesce navigation cues without delaying the playhead. A held boundary is announced
/// once; quick jitter out and back cannot buzz repeatedly. There are no timers to outlive a
/// gesture. The UI chooses how to render these cues (including a hardware haptic, if enabled).
public struct ScrubFeedbackCadence: Sendable {
    public enum Cue: Equatable, Sendable { case frame, clipEnd }
    /// The shortest time between two frame pulses while skimming. macOS offers no haptic
    /// strength, so the skim is made gentler by pulsing 30 % less often than the original
    /// 0.08 s (at most about 8.7 pulses a second instead of 12.5). A clip-end cue is not throttled.
    public static let frameInterval: TimeInterval = 0.08/0.7
    private var previous: ScrubPosition?
    private var lastCueAt = -Double.infinity
    private var lastEnd: MediaTime?
    private var lastEndAt = -Double.infinity
    public init() {}

    public mutating func cue(for position: ScrubPosition, at timestamp: TimeInterval, enabled: Bool = true) -> Cue? {
        defer { previous = position }
        guard enabled else { return nil }
        if let end = position.snappedEnd {
            guard previous?.snappedEnd != end,
                  lastEnd != end || timestamp-lastEndAt >= 0.18 else { return nil }
            lastEnd = end; lastEndAt = timestamp; lastCueAt = timestamp
            return .clipEnd
        }
        guard position.time != previous?.time, timestamp-lastCueAt >= Self.frameInterval else { return nil }
        lastCueAt = timestamp
        return .frame
    }
}
