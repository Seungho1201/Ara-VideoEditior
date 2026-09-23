import Foundation
@preconcurrency import AVFoundation
import CoreImage
import FrameCore

public final class RenderBundle: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix
    public let duration: MediaTime
    public let size: CGSize
    public let frameRate: FrameRate
    public init(composition: AVComposition, videoComposition: AVVideoComposition, audioMix: AVAudioMix, duration: MediaTime, size: CGSize, frameRate: FrameRate) {
        self.composition = composition; self.videoComposition = videoComposition; self.audioMix = audioMix
        self.duration = duration; self.size = size; self.frameRate = frameRate
    }
    @MainActor public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset:composition); item.videoComposition = videoComposition; item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral
        // A seek completes once its composed frame is on screen, not when the timing moves: the
        // editor chases seeks one at a time while scrubbing and needs to know when a frame landed.
        item.seekingWaitsForVideoCompositionRendering = true
        return item
    }
}

public actor CompositionBuilder {
    public init() {}
    /// `videoURLs` replaces the picture (never the sound) of a source with a stand-in such as its
    /// FHD preview proxy. A stand-in must share the source's timing and aspect ratio; one that has
    /// gone missing (caches can be purged) falls back to the original.
    public func build(_ project: Project, urls: [UUID:URL], height: Int = 1080, videoURLs: [UUID:URL] = [:]) async throws -> RenderBundle {
        _ = try project.validated()
        guard project.duration > .zero else { throw EditError("Add a clip to the timeline first.") }
        guard height == 1080 || height == 2160 else { throw EditError("Unsupported output resolution.") }
        for clip in project.clips where clip.kind != .text {
            guard let id = clip.mediaID, let url = urls[id], FileManager.default.isReadableFile(atPath:url.path) else { throw EditError("Missing media: \(clip.name). Relink it in the library.") }
        }
        let seed = try await SentinelStore.shared.assets()
        try Task.checkCancellation()
        let composition = AVMutableComposition()
        let clockAsset = AVURLAsset(url:seed.0)
        guard let clockSource = try await clockAsset.loadTracks(withMediaType:.video).first,
              let clock = composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw EditError("Cannot create video clock.") }
        try clock.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(seconds:1,preferredTimescale:30)),of:clockSource,at:.zero)
        clock.scaleTimeRange(CMTimeRange(start:.zero,duration:CMTime(seconds:1,preferredTimescale:30)),toDuration:project.duration.cmTime)
        let silenceAsset = AVURLAsset(url:seed.1)
        guard let silenceSource = try await silenceAsset.loadTracks(withMediaType:.audio).first,
              let silence = composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw EditError("Cannot create audio clock.") }
        // Repeat the silent second rather than scaling it. A scaled audio edit is a time-stretch:
        // AVPlayer re-primes it on every rate change and resumes well ahead of the pause point,
        // by an amount that grows with the timeline length. Repetition carries no time mapping.
        let silentUnit = CMTime(seconds:1,preferredTimescale:48000)
        var silentCursor = CMTime.zero
        while silentCursor < project.duration.cmTime {
            try Task.checkCancellation()
            let take = CMTimeMinimum(silentUnit,project.duration.cmTime-silentCursor)
            guard take > .zero else { break }
            try silence.insertTimeRange(CMTimeRange(start:.zero,duration:take),of:silenceSource,at:silentCursor)
            silentCursor = silentCursor + take
        }
        let silentMix = AVMutableAudioMixInputParameters(track:silence); silentMix.setVolume(0,at:.zero)
        var mixes: [AVAudioMixInputParameters] = [silentMix]
        var layerTracks: [UUID:CMPersistentTrackID] = [:]
        var transforms: [UUID:CGAffineTransform] = [:]
        var videoIDs: [CMPersistentTrackID] = [clock.trackID]
        var assetCache: [URL:AVURLAsset] = [:]
        func pictureURL(_ id: UUID, _ url: URL) -> URL {
            guard let standIn = videoURLs[id], FileManager.default.isReadableFile(atPath:standIn.path) else { return url }
            return standIn
        }
        for lane in Lane.allCases {
            let clips = project.clips.filter { $0.lane == lane && ($0.kind == .video || $0.kind == .audio) }.sorted { $0.start < $1.start }
            guard !clips.isEmpty else { continue }
            let type: AVMediaType = lane.isVideo ? .video : .audio
            guard let track = composition.addMutableTrack(withMediaType:type,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw EditError("Cannot allocate composition track.") }
            let parameters = AVMutableAudioMixInputParameters(track:track); parameters.setVolume(0,at:.zero)
            for clip in clips {
                try Task.checkCancellation()
                guard let id = clip.mediaID, let original = urls[id] else { throw EditError("Missing media URL.") }
                let url = type == .video ? pictureURL(id,original) : original
                let asset = assetCache[url] ?? AVURLAsset(url:url); assetCache[url] = asset
                guard let source = try await asset.loadTracks(withMediaType:type).first else { throw EditError("No \(type.rawValue) stream in \(clip.name).") }
                let sourceRange = CMTimeRange(start:clip.sourceStart.cmTime,duration:clip.sourceLength.cmTime)
                let available = try await source.load(.timeRange)
                let range = CMTimeRangeGetIntersection(sourceRange,otherRange:available)
                if range.duration > .zero {
                    if clip.speed == 1 {
                        try track.insertTimeRange(range,of:source,at:clip.start.cmTime+(range.start-sourceRange.start))
                    } else {
                        // The retimed segment is laid out in the project clock and never past the
                        // clip's own end. A float multiply (CMTimeMultiplyByFloat64) moves to a 1e9
                        // timescale and can round a fraction of a nanosecond beyond the clip; the
                        // composition then outlasts the video instruction, AVFoundation rejects the
                        // video composition, and preview and export show no picture at all.
                        let destination = min(clip.start+MediaTime(range.start-sourceRange.start).scaled(by:1/clip.speed),clip.end)
                        let length = min(MediaTime(range.duration).scaled(by:1/clip.speed),clip.end-destination)
                        try track.insertTimeRange(range,of:source,at:destination.cmTime)
                        // scaleTimeRange rewrites in place and shifts everything after it. Clips are
                        // processed in start order and nothing later exists yet, so the shift is harmless.
                        track.scaleTimeRange(CMTimeRange(start:destination.cmTime,duration:range.duration),toDuration:length.cmTime)
                    }
                }
                if lane.isVideo {
                    layerTracks[clip.id] = track.trackID; transforms[clip.id] = try await source.load(.preferredTransform)
                } else {
                    parameters.setVolume(clip.style.muted ? 0 : Float(clip.style.volume),at:clip.start.cmTime)
                    parameters.setVolume(0,at:clip.end.cmTime)
                }
            }
            if lane.isVideo { videoIDs.append(track.trackID) } else { mixes.append(parameters) }
        }
        var layers: [RenderLayer] = []
        for lane in [Lane.v1, .v2] {
            for clip in project.clips.filter({ $0.lane == lane }).sorted(by:{ $0.start < $1.start }) {
                try Task.checkCancellation()
                var image: CIImage?
                if clip.kind == .text { image = try FrameRenderer.textImage(clip.style) }
                else if clip.kind == .image {
                    guard let id = clip.mediaID, let url = urls[id], let still = CIImage(contentsOf:url,options:[.applyOrientationProperty:true]) else { throw EditError("Cannot decode image \(clip.name).") }
                    image = still
                }
                // Decode the clip's own first frame as a stand-in. HDR sources deliver nothing for
                // roughly the first three frames of each segment while the decoder primes, and a
                // still beats both a black flash and aborting the whole render.
                var fallback: CIImage?
                if clip.kind == .video, let id = clip.mediaID, let url = urls[id] {
                    let generator = AVAssetImageGenerator(asset:assetCache[pictureURL(id,url)] ?? AVURLAsset(url:pictureURL(id,url)))
                    generator.appliesPreferredTrackTransform = false
                    // Must be the clip's own in-point: a loose tolerance returns an unrelated keyframe.
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                    if let cg = try? await generator.image(at:clip.sourceStart.cmTime).image { fallback = CIImage(cgImage:cg) }
                }
                layers.append(RenderLayer(clip:clip,trackID:layerTracks[clip.id],preferredTransform:transforms[clip.id] ?? .identity,image:image,fallbackImage:fallback))
            }
        }
        let size = CGSize(width:height*16/9,height:height)
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = FrameCompositor.self
        video.renderSize = size; video.frameDuration = project.frameRate.frame.cmTime
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        // The instruction must cover every instant of the composition or the whole video
        // composition is invalid (no picture at all). Tracks are laid out to end by the project
        // duration; covering the composition's own duration keeps any rounding from mattering.
        video.instructions = [FrameInstruction(duration:CMTimeMaximum(project.duration.cmTime,composition.duration),trackIDs:videoIDs,layers:layers)]
        let audio = AVMutableAudioMix(); audio.inputParameters = mixes
        return RenderBundle(composition:composition.copy() as! AVComposition,videoComposition:video.copy() as! AVVideoComposition,audioMix:audio.copy() as! AVAudioMix,duration:project.duration,size:size,frameRate:project.frameRate)
    }
}

/// Small reusable clock tracks make image-only, text-only, audio-only and gap playback work.
private actor SentinelStore {
    static let shared = SentinelStore()
    private var pending: Task<(URL,URL),Error>?
    func assets() async throws -> (URL,URL) {
        if let pending { return try await pending.value }
        let task = Task { try await self.create() }; pending = task
        do { return try await task.value } catch { pending = nil; throw error }
    }
    private func create() async throws -> (URL,URL) {
        let videoURL = MediaPaths.cache.appendingPathComponent("clock-v1.mov")
        let audioURL = MediaPaths.cache.appendingPathComponent("silence-v1.caf")
        if !FileManager.default.fileExists(atPath:videoURL.path) {
            let temporary = MediaPaths.cache.appendingPathComponent(UUID().uuidString+".mov")
            defer { try? FileManager.default.removeItem(at:temporary) }
            let writer = try AVAssetWriter(outputURL:temporary,fileType:.mov)
            let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:64])
            let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:64,kCVPixelBufferHeightKey as String:64,kCVPixelBufferIOSurfacePropertiesKey as String:[:] as [String:String]])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? EditError("Cannot create video clock.") }
            writer.startSession(atSourceTime:.zero)
            var buffer: CVPixelBuffer?
            guard let pool = adapter.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer) == kCVReturnSuccess, let buffer else { throw EditError("Cannot allocate clock buffer.") }
            let context = FrameRenderer.makeContext(); context.render(CIImage(color:.black).cropped(to:CGRect(x:0,y:0,width:64,height:64)),to:buffer)
            for frame in 0..<30 {
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed { throw writer.error ?? EditError("Clock encoder failed.") }
                    try await Task.sleep(for:.milliseconds(2))
                }
                guard adapter.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:30)) else { throw writer.error ?? EditError("Cannot write clock frame.") }
            }
            input.markAsFinished(); writer.endSession(atSourceTime:CMTime(value:1,timescale:1)); await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? EditError("Cannot finish clock video.") }
            try FileManager.default.moveItem(at:temporary,to:videoURL)
        }
        if !FileManager.default.fileExists(atPath:audioURL.path) {
            let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
            let file = try AVAudioFile(forWriting:audioURL,settings:format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
            buffer.frameLength = 48000
            for channel in 0..<2 { memset(buffer.floatChannelData![channel],0,48000*MemoryLayout<Float>.size) }
            try file.write(from:buffer)
        }
        return (videoURL,audioURL)
    }
}
