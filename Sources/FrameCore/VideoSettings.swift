import Foundation
import CoreGraphics

/// Canvas presets share the same dimensions in preview, snapshots and movie export.
/// Output quality presets, by the canvas's short edge: 720 (HD) to 2160 (4K).
public enum OutputQuality: Int, CaseIterable, Sendable, Identifiable {
    case hd = 720, fullHD = 1080, twoK = 1152, qhd = 1440, threeK = 1620, uhd = 2160
    public var id: Int { rawValue }
    public var name: String {
        switch self {
        case .hd: "HD"
        case .fullHD: "Full HD"
        case .twoK: "2K"
        case .qhd: "QHD"
        case .threeK: "3K"
        case .uhd: "4K"
        }
    }
    public static let resolutions = allCases.map(\.rawValue)
    /// H.264 average bit rate: 12 Mbps at Full HD and 40 at 4K as before, the rest in between.
    public static func bitRate(shortEdge: Int) -> Int {
        switch shortEdge {
        case ..<1080: 8_000_000
        case ..<1152: 12_000_000
        case ..<1440: 16_000_000
        case ..<1620: 24_000_000
        case ..<2160: 30_000_000
        default: 40_000_000
        }
    }
}

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
    /// `resolution` is the short edge of an `OutputQuality` (1080 for the preview). Both sides
    /// are even, as H.264 needs: 4:5 at 3K is 1620 × 2024, not 2025.
    public func size(resolution: Int = 1080) -> CGSize {
        let base: (Int,Int) = switch self {
        case .landscape: (1920,1080)
        case .portrait: (1080,1920)
        case .square: (1080,1080)
        case .classic: (1440,1080)
        case .social: (1080,1350)
        }
        func even(_ side: Int) -> Int { (side*resolution/1080)/2*2 }
        return CGSize(width:even(base.0),height:even(base.1))
    }
    public var value: Double { let s = size(); return s.width/s.height }
    public func dimensions(resolution: Int = 1080) -> String {
        let s = size(resolution:resolution); return "\(Int(s.width)) × \(Int(s.height))"
    }
}

public extension Editing {
    /// Preserve speed, source in-points and linked A/V. Each cut goes to the nearest frame of the
    /// new grid, once for every clip that shares it, so clips that met still meet and the tracks
    /// stay in sync (rounding each duration on its own would accumulate gaps or overlaps). A
    /// whole clip's end can round past its source's end by less than a frame: its last frame is
    /// held there (`Project.fitsSource`). One that would overrun by more, after earlier rate
    /// changes, ends on the last frame its source reaches instead. Refuse a conversion that
    /// leaves a clip shorter than a frame; the original project remains untouched on failure.
    static func setVideoSettings(aspectRatio: VideoAspectRatio, frameRate: FrameRate, resolution: Int? = nil, in project: inout Project) throws {
        guard FrameRate.supported.contains(frameRate) else { throw EditError("Unsupported project frame rate.") }
        var candidate = try project.validated()
        if frameRate != candidate.frameRate {
            let clips = candidate.clips
            var converted = candidate; converted.frameRate = frameRate
            let assets = Dictionary(uniqueKeysWithValues:candidate.media.map { ($0.id,$0) })
            let ending = Dictionary(grouping:clips,by:\.end)
            var mapped: [MediaTime:MediaTime] = [:]
            var previous = MediaTime.zero
            for boundary in Set(clips.flatMap { [$0.start,$0.end] }).sorted() {
                var time = frameRate.quantize(boundary)
                for clip in ending[boundary] ?? [] where clip.kind == .video || clip.kind == .audio {
                    guard let asset = clip.mediaID.flatMap({ assets[$0] }), let start = mapped[clip.start] else { continue }
                    var fitted = clip; fitted.start = start; fitted.duration = time-start
                    while fitted.duration > frameRate.frame, !converted.fitsSource(fitted,of:asset) { fitted.duration = fitted.duration-frameRate.frame }
                    time = min(time,fitted.end)
                }
                // Never before an earlier cut: clips that did not overlap still do not.
                time = max(time,previous)
                mapped[boundary] = time; previous = time
            }
            for i in candidate.clips.indices {
                let clip = clips[i], start = mapped[clip.start]!, end = mapped[clip.end]!
                guard end-start >= frameRate.frame else {
                    throw EditError("At \(frameRate.label) fps “\(clip.name)” would be shorter than one frame. Lengthen it or choose another frame rate.")
                }
                candidate.clips[i].start = start
                candidate.clips[i].duration = end-start
                // A length remembered for the next speed change stays while it still describes the
                // clip, so 1x gives back the range it was given; rounded past it or too far from it,
                // the clip has a new source range.
                if let length = clip.retimedSourceLength, !candidate.clips[i].wasGiven(length) { candidate.clips[i].retimedSourceLength = nil }
                if clip.kind == .video || clip.kind == .audio, let asset = clip.mediaID.flatMap({ assets[$0] }), !converted.fitsSource(candidate.clips[i],of:asset) {
                    throw EditError("At \(frameRate.label) fps “\(clip.name)” would end more than a frame after its source. Trim its end by a frame, then change the frame rate.")
                }
            }
            candidate.frameRate = frameRate
        }
        candidate.aspectRatio = aspectRatio
        if let resolution { candidate.outputResolution = resolution }
        project = try candidate.validated()
    }
}
