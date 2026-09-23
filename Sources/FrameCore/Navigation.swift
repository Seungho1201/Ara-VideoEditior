import Foundation

public extension Clip {
    /// The end is exclusive; displaying it would show the following clip or a gap.
    func lastFrameTime(at rate: FrameRate) -> MediaTime { max(start,end-rate.frame) }
}

public extension Project {
    /// Clamp still capture to an actual project frame, including at the end of playback.
    func snapshotTime(at playhead: MediaTime) -> MediaTime? {
        guard duration > .zero else { return nil }
        return min(max(.zero,frameRate.quantize(playhead)),max(.zero,duration-frameRate.frame))
    }
}
