import Foundation
import CoreGraphics

/// Canvas presets share the same dimensions in preview, snapshots and movie export.
public enum VideoAspectRatio: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case landscape = "16:9", portrait = "9:16", square = "1:1", classic = "4:3", social = "4:5"
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .landscape: "16:9 · Landscape"
        case .portrait: "9:16 · Portrait"
        case .square: "1:1 · Square"
        case .classic: "4:3 · Classic"
        case .social: "4:5 · Portrait"
        }
    }
    /// `resolution` is the short edge: 1080 for preview/HD, 2160 for the 4K preset.
    public func size(resolution: Int = 1080) -> CGSize {
        let base: (Int,Int) = switch self {
        case .landscape: (1920,1080)
        case .portrait: (1080,1920)
        case .square: (1080,1080)
        case .classic: (1440,1080)
        case .social: (1080,1350)
        }
        return CGSize(width:base.0*resolution/1080,height:base.1*resolution/1080)
    }
    public var value: Double { let s = size(); return s.width/s.height }
    public func dimensions(resolution: Int = 1080) -> String {
        let s = size(resolution:resolution); return "\(Int(s.width)) × \(Int(s.height))"
    }
}

public extension Editing {
    /// Preserve speed, source in-points and linked A/V. Quantize shared cut boundaries once,
    /// rather than rounding each duration independently and accumulating gaps or overlaps.
    /// Source-limited ends round down. Refuse a conversion that loses a clip or moves an edge
    /// by a full frame; the original project remains untouched on failure.
    static func setVideoSettings(aspectRatio: VideoAspectRatio, frameRate: FrameRate, resolution: Int? = nil, in project: inout Project) throws {
        guard FrameRate.supported.contains(frameRate) else { throw EditError("Unsupported project frame rate.") }
        var candidate = try project.validated()
        if frameRate != candidate.frameRate {
            let clips = candidate.clips
            let ending = Dictionary(grouping:clips,by:\.end)
            let boundaries = Set(clips.flatMap { [$0.start,$0.end] }).sorted()
            var mapped: [MediaTime:MediaTime] = [:]
            var previous = MediaTime.zero
            let failure = EditError("This frame rate cannot preserve these cuts within one frame. Use a higher frame rate or lengthen the shortest clips first.")
            for boundary in boundaries {
                var time = frameRate.quantize(boundary)
                for clip in ending[boundary] ?? [] where clip.kind == .video || clip.kind == .audio {
                    guard let source = candidate.media(for:clip), let start = mapped[clip.start] else { throw failure }
                    let available = source.duration-clip.sourceStart
                    var limit = frameRate.floor(available.scaled(by:1/clip.speed))
                    // Inverse-speed rounding must never consume a tick beyond the source.
                    if limit.scaled(by:clip.speed) > available { limit -= frameRate.frame }
                    time = min(time,start+limit)
                }
                guard time >= previous, abs(time.ticks-boundary.ticks) < frameRate.frame.ticks else { throw failure }
                mapped[boundary] = time; previous = time
            }
            for i in candidate.clips.indices {
                let clip = clips[i], start = mapped[clip.start]!, end = mapped[clip.end]!
                guard end-start >= frameRate.frame else { throw failure }
                candidate.clips[i].start = start
                candidate.clips[i].duration = end-start
            }
            candidate.frameRate = frameRate
        }
        candidate.aspectRatio = aspectRatio
        if let resolution { candidate.outputResolution = resolution }
        project = try candidate.validated()
    }
}
