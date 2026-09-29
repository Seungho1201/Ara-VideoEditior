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
    /// The media files it reads, as they were when it was built: an export that fails can name
    /// the one that has changed or gone since.
    let sources: [URL:FileStamp]
    public convenience init(composition: AVComposition, videoComposition: AVVideoComposition, audioMix: AVAudioMix, duration: MediaTime, size: CGSize, frameRate: FrameRate) {
        self.init(composition:composition,videoComposition:videoComposition,audioMix:audioMix,duration:duration,size:size,frameRate:frameRate,sources:[:])
    }
    init(composition: AVComposition, videoComposition: AVVideoComposition, audioMix: AVAudioMix, duration: MediaTime, size: CGSize, frameRate: FrameRate, sources: [URL:FileStamp]) {
        self.composition = composition; self.videoComposition = videoComposition; self.audioMix = audioMix
        self.duration = duration; self.size = size; self.frameRate = frameRate; self.sources = sources
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
    private let sentinels: SentinelStore
    public init() { sentinels = .shared }
    /// Clock and silence files kept somewhere else than the app's cache (tests).
    init(sentinels: SentinelStore) { self.sentinels = sentinels }
    /// `videoURLs` replaces the picture (never the sound) of a source with a stand-in such as its
    /// FHD preview proxy. A stand-in must share the source's timing and aspect ratio; one that has
    /// gone missing (caches can be purged) falls back to the original.
    /// `height` is an `OutputQuality` preset (the short canvas edge for any aspect ratio).
    public func build(_ project: Project, urls: [UUID:URL], height: Int = 1080, videoURLs: [UUID:URL] = [:]) async throws -> RenderBundle {
        let project = try project.validated()             // transitions reconciled with their clips
        guard project.duration > .zero else { throw EditError("Add a clip to the timeline first.") }
        guard OutputQuality.resolutions.contains(height) else { throw EditError("Unsupported output resolution.") }
        for clip in project.clips where clip.kind != .text {
            guard let id = clip.mediaID, let url = urls[id], FileManager.default.isReadableFile(atPath:url.path) else { throw EditError("Missing media: \(clip.name). Relink it in the library.") }
        }
        let seed = try await sentinels.assets()
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
        // Every source stream a clip plays, and the stretch of time it really covers.
        var sources: [UUID:(track: AVAssetTrack, available: CMTimeRange)] = [:]
        for clip in project.clips where clip.kind == .video || clip.kind == .audio {
            try Task.checkCancellation()
            guard let id = clip.mediaID, let original = urls[id] else { throw EditError("Missing media URL.") }
            let type: AVMediaType = clip.lane.isVideo ? .video : .audio
            let url = type == .video ? pictureURL(id,original) : original
            let asset = assetCache[url] ?? AVURLAsset(url:url); assetCache[url] = asset
            guard let source = try await asset.loadTracks(withMediaType:type).first else {
                throw type == .video ? EditError("No video stream in \(clip.name).") : EditError("No audio stream in \(clip.name).")
            }
            sources[clip.id] = (source,try await source.load(.timeRange))
        }
        /// Timeline time the source has to spare before the clip's in-point, or after its out-point.
        func room(_ clip: Clip, before: Bool) -> MediaTime {
            guard let available = sources[clip.id]?.available else { return .zero }
            let spare = before ? clip.sourceStart-MediaTime(available.start) : MediaTime(available.end)-(clip.sourceStart+clip.sourceLength)
            return spare > .zero ? project.frameRate.floor(spare.scaled(by:1/clip.speed)) : .zero
        }
        func linkedSound(_ id: UUID?) -> Clip? {
            guard let link = id.flatMap(project.clip)?.linkID else { return nil }
            return project.clips.first { $0.linkID == link && !$0.lane.isVideo }
        }
        // Transitions: how far past its edges each visual clip shows across a cut (head before its
        // start, tail after its end), its side of each transition, and what its linked sound does:
        // a crossfade across a cut when both sources have sound beyond it, otherwise out before
        // the cut and in after it. The crossfade keeps constant power, except between the two
        // halves of a split clip: they play the same sound there, which adds up in step (a
        // constant-power one would be 3 dB louder in the middle), so theirs keeps constant gain.
        var head: [UUID:MediaTime] = [:], tail: [UUID:MediaTime] = [:]
        var sides: [UUID:[LayerTransition]] = [:]
        var fadeIn: [UUID:MediaTime] = [:], fadeOut: [UUID:MediaTime] = [:]
        var crossIn: [UUID:TransitionWindow] = [:], crossOut: [UUID:TransitionWindow] = [:]
        var inStep = Set<UUID>()
        for transition in project.transitions {
            guard let window = project.window(of:transition) else { continue }
            // Both pictures at once across a cut; a dip shows one at a time and switches at the cut.
            let paired = transition.isCut && transition.kind.needsBothPictures
            let cut = window.start+window.before
            for (id,role) in [(transition.from,LayerTransition.Role.outgoing),(transition.to,.incoming)] {
                guard let id else { continue }
                sides[id,default:[]].append(LayerTransition(id:transition.id,kind:transition.kind,direction:transition.direction,role:role,paired:paired,
                                                            start:window.start,duration:window.duration,cut:cut))
            }
            if paired, let from = transition.from, let to = transition.to { tail[from] = window.after; head[to] = window.before }
            let outgoing = linkedSound(transition.from), incoming = linkedSound(transition.to)
            if paired, let outgoing, let incoming, outgoing.lane == incoming.lane, outgoing.end == cut, incoming.start == cut,
               room(outgoing,before:false) >= window.after, room(incoming,before:true) >= window.before {
                crossOut[outgoing.id] = window; crossIn[incoming.id] = window
                // One source carrying on across the cut (to a tick, at one speed): the same sound on both sides.
                if outgoing.mediaID == incoming.mediaID, outgoing.speed == incoming.speed,
                   abs((outgoing.sourceStart+outgoing.sourceLength-incoming.sourceStart).ticks) <= 1 { inStep.formUnion([outgoing.id,incoming.id]) }
            } else {
                if let outgoing, window.before > .zero { fadeOut[outgoing.id] = window.before }
                if let incoming, window.after > .zero { fadeIn[incoming.id] = window.after }
            }
        }
        // Where each video layer's track holds real frames, and the frames to hold beyond them.
        var frames: [UUID:(from: MediaTime, to: MediaTime)] = [:]
        var headHold: [UUID:CMTime] = [:], tailHold: [UUID:CMTime] = [:]
        for lane in project.videoLanes+project.audioLanes {
            let clips = project.clips.filter { $0.lane == lane && ($0.kind == .video || $0.kind == .audio) }.sorted { $0.start < $1.start }
            guard !clips.isEmpty else { continue }
            let type: AVMediaType = lane.isVideo ? .video : .audio
            // A/B roll: across a cut that plays both clips at once they decode together, so the
            // incoming clip goes on the lane's other composition track (each with its own levels).
            var tracks: [AVMutableCompositionTrack] = [], levels: [AVMutableAudioMixInputParameters] = []
            func track(_ slot: Int) throws -> AVMutableCompositionTrack {
                while tracks.count <= slot {
                    guard let made = composition.addMutableTrack(withMediaType:type,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw EditError("Cannot allocate composition track.") }
                    tracks.append(made)
                    let parameters = AVMutableAudioMixInputParameters(track:made); parameters.setVolume(0,at:.zero); levels.append(parameters)
                }
                return tracks[slot]
            }
            var slots: [Int] = [], slot = 0
            for clip in clips {
                if (lane.isVideo ? head[clip.id] : crossIn[clip.id]?.before) != nil { slot = 1-slot }
                slots.append(slot)
            }
            for (index,clip) in clips.enumerated() {
                try Task.checkCancellation()
                guard let (source,available) = sources[clip.id] else { throw EditError("Missing media URL.") }
                let target = try track(slots[index])
                // Frames (or sound) beyond the clip's edges, as much as the source has: the
                // renderer holds the nearest frame for the rest of a transition.
                let wantHead = lane.isVideo ? head[clip.id] ?? .zero : crossIn[clip.id]?.before ?? .zero
                let wantTail = lane.isVideo ? tail[clip.id] ?? .zero : crossOut[clip.id]?.after ?? .zero
                var extraHead = min(wantHead,room(clip,before:true))
                let extraTail = min(wantTail,room(clip,before:false))
                // Never reach back into what the track already holds: an insert there would push it later.
                let filled = MediaTime(target.timeRange.end)
                if extraHead > .zero, clip.start-extraHead < filled { extraHead = max(.zero,clip.start-filled) }
                let headSource = extraHead.scaled(by:clip.speed), tailSource = extraTail.scaled(by:clip.speed)
                let sourceStart = clip.sourceStart-headSource
                let sourceLength = clip.sourceLength+headSource+tailSource
                let begin = clip.start-extraHead, finish = clip.end+extraTail
                let sourceRange = CMTimeRange(start:sourceStart.cmTime,duration:sourceLength.cmTime)
                let range = CMTimeRangeGetIntersection(sourceRange,otherRange:available)
                var framesFrom = clip.start, framesTo = clip.start
                if range.duration > .zero {
                    if clip.speed == 1 {
                        try target.insertTimeRange(range,of:source,at:begin.cmTime+(range.start-sourceRange.start))
                        framesFrom = begin+MediaTime(range.start-sourceRange.start); framesTo = framesFrom+MediaTime(range.duration)
                    } else {
                        // The retimed segment is laid out in the project clock and never past the
                        // clip's own end (plus its transition tail). A float multiply
                        // (CMTimeMultiplyByFloat64) moves to a 1e9 timescale and can round a fraction
                        // of a nanosecond beyond it; the composition then outlasts the video
                        // instruction, AVFoundation rejects the video composition, and preview and
                        // export show no picture at all.
                        let destination = min(begin+MediaTime(range.start-sourceRange.start).scaled(by:1/clip.speed),finish)
                        let length = min(MediaTime(range.duration).scaled(by:1/clip.speed),finish-destination)
                        try target.insertTimeRange(range,of:source,at:destination.cmTime)
                        // scaleTimeRange rewrites in place and shifts everything after it. Clips are
                        // processed in start order and nothing later exists on this track yet.
                        target.scaleTimeRange(CMTimeRange(start:destination.cmTime,duration:range.duration),toDuration:length.cmTime)
                        framesFrom = destination; framesTo = destination+length
                    }
                }
                if lane.isVideo {
                    layerTracks[clip.id] = target.trackID; transforms[clip.id] = try await source.load(.preferredTransform)
                    frames[clip.id] = (framesFrom,framesTo)
                    // The first and last frames the track has, when a transition (or a source
                    // shorter than the clip) reaches past them. The clip's own first frame is the
                    // decoder fallback already.
                    if range.duration > .zero {
                        if framesFrom > clip.start-wantHead, range.start != clip.sourceStart.cmTime { headHold[clip.id] = range.start }
                        if framesTo < clip.end+wantTail { tailHold[clip.id] = (MediaTime(range.end)-MediaTime(ticks:1)).cmTime }
                    }
                } else {
                    let parameters = levels[slots[index]]
                    let volume: Float = clip.style.muted ? 0 : Float(clip.style.volume)
                    if let window = crossIn[clip.id] { Self.crossfade(parameters,level:volume,over:window,rising:true,inStep:inStep.contains(clip.id)) }
                    else if let rampIn = fadeIn[clip.id] { parameters.setVolumeRamp(fromStartVolume:0,toEndVolume:volume,timeRange:CMTimeRange(start:clip.start.cmTime,duration:rampIn.cmTime)) }
                    else { parameters.setVolume(volume,at:clip.start.cmTime) }
                    if let window = crossOut[clip.id] { Self.crossfade(parameters,level:volume,over:window,rising:false,inStep:inStep.contains(clip.id)) }
                    else if let rampOut = fadeOut[clip.id] { parameters.setVolumeRamp(fromStartVolume:volume,toEndVolume:0,timeRange:CMTimeRange(start:(clip.end-rampOut).cmTime,duration:rampOut.cmTime)) }
                    // The next clip on this track sets the level itself when it begins right here.
                    let audibleEnd = crossOut[clip.id]?.end ?? clip.end
                    let next = clips.indices.first { $0 > index && slots[$0] == slots[index] }.map { clips[$0] }
                    if next.map({ (crossIn[$0.id]?.start ?? $0.start) != audibleEnd }) ?? true { parameters.setVolume(0,at:audibleEnd.cmTime) }
                }
            }
            if lane.isVideo { videoIDs.append(contentsOf:tracks.map(\.trackID)) } else { mixes.append(contentsOf:levels) }
        }
        // Each video clip's own first frame is decoded as a stand-in. HDR sources deliver nothing
        // for roughly the first three frames of each segment while the decoder primes, and a
        // still beats both a black flash and aborting the whole render. Held frames are decoded
        // natively and converted exactly as the compositor converts the frames around them, so a
        // held first or last frame matches in colour. They are gathered first and decoded a few
        // at a time, skipping any an earlier build decoded (SourceFrameConverter.heldFrames).
        var wanted: [(url: URL, time: CMTime)] = []
        func picture(_ clip: Clip) -> URL? { clip.mediaID.flatMap { id in urls[id].map { pictureURL(id,$0) } } }
        for clip in project.clips where clip.kind == .video {
            guard let url = picture(clip) else { continue }
            wanted += [clip.sourceStart.cmTime,headHold[clip.id],tailHold[clip.id]].compactMap { $0.map { (url,$0) } }
        }
        let decoded = await SourceFrameConverter.heldFrames(wanted)
        try Task.checkCancellation()
        func held(_ clip: Clip, at time: CMTime?) -> CIImage? {
            guard let time, let url = picture(clip) else { return nil }
            return decoded[HeldFrameRequest(url,time)]
        }
        var layers: [RenderLayer] = []
        // Bottom to top: each video track draws over the ones numbered below it.
        for lane in project.videoLanes {
            for clip in project.clips.filter({ $0.lane == lane }).sorted(by:{ $0.start < $1.start }) {
                try Task.checkCancellation()
                var image: CIImage?
                // Titles are drawn at the output's own resolution (a 4K export draws them at 4K).
                if clip.kind == .text { image = try FrameRenderer.textImage(clip.style,scale:CGFloat(height)/1080) }
                else if clip.kind == .image {
                    guard let id = clip.mediaID, let url = urls[id], let still = CIImage(contentsOf:url,options:[.applyOrientationProperty:true]) else { throw EditError("Cannot decode image \(clip.name).") }
                    image = still
                }
                var fallback: CIImage?, headImage: CIImage?, tailImage: CIImage?
                if clip.kind == .video {
                    fallback = held(clip,at:clip.sourceStart.cmTime)
                    headImage = held(clip,at:headHold[clip.id]); tailImage = held(clip,at:tailHold[clip.id])
                }
                layers.append(RenderLayer(clip:clip,trackID:layerTracks[clip.id],preferredTransform:transforms[clip.id] ?? .identity,image:image,fallbackImage:fallback,
                                          visibleStart:clip.start-(head[clip.id] ?? .zero),visibleEnd:clip.end+(tail[clip.id] ?? .zero),
                                          framesStart:frames[clip.id]?.from,framesEnd:frames[clip.id]?.to,headImage:headImage,tailImage:tailImage,
                                          transitions:sides[clip.id] ?? []))
            }
        }
        let size = project.aspectRatio.size(resolution:height)
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = FrameCompositor.self
        video.renderSize = size; video.frameDuration = project.frameRate.frame.cmTime
        // No colour properties: with them AVFoundation converts HDR sources itself, differently for
        // the image generator than for playback and export. The compositor converts every source
        // (SourceFrameConverter) and tags its Rec.709 output.
        // The instruction must cover every instant of the composition or the whole video
        // composition is invalid (no picture at all). Tracks are laid out to end by the project
        // duration; covering the composition's own duration keeps any rounding from mattering.
        video.instructions = [FrameInstruction(duration:CMTimeMaximum(project.duration.cmTime,composition.duration),trackIDs:videoIDs,layers:layers)]
        let audio = AVMutableAudioMix(); audio.inputParameters = mixes
        let files = Set(project.clips.compactMap { clip in clip.mediaID.flatMap { id in urls[id].map { clip.kind == .video ? pictureURL(id,$0) : $0 } } })
        return RenderBundle(composition:composition.copy() as! AVComposition,videoComposition:video.copy() as! AVVideoComposition,audioMix:audio.copy() as! AVAudioMix,
                            duration:project.duration,size:size,frameRate:project.frameRate,sources:Dictionary(uniqueKeysWithValues:files.map { ($0,FileStamp($0)) }))
    }
    /// A sine (in) or cosine (out) gain curve across the window in eight straight pieces: the two
    /// sides of a crossfade keep constant power, where a linear one dips about 3 dB in the middle
    /// between different sounds. `inStep` sounds (one source on both sides) add as amplitudes,
    /// so they fade in a straight line instead: the sum stays at `level` throughout.
    private static func crossfade(_ parameters: AVMutableAudioMixInputParameters, level: Float, over window: TransitionWindow, rising: Bool, inStep: Bool) {
        if inStep {
            parameters.setVolumeRamp(fromStartVolume:rising ? 0 : level,toEndVolume:rising ? level : 0,timeRange:CMTimeRange(start:window.start.cmTime,duration:window.duration.cmTime))
            return
        }
        let steps: Int64 = 8
        func at(_ step: Int64) -> MediaTime { window.start+MediaTime(ticks:window.duration.ticks*step/steps) }
        func gain(_ step: Int64) -> Float {
            let x = Float(step)/Float(steps)*Float.pi/2
            return level*(rising ? sin(x) : cos(x))
        }
        for step in 0..<steps {
            parameters.setVolumeRamp(fromStartVolume:gain(step),toEndVolume:gain(step+1),timeRange:CMTimeRange(start:at(step).cmTime,end:at(step+1).cmTime))
        }
    }
}

/// Small reusable clock tracks make image-only, text-only, audio-only and gap playback work.
actor SentinelStore {
    static let shared = SentinelStore { MediaPaths.cache }
    /// Where the two files live, asked each time: the folder itself may have been deleted.
    private let folder: @Sendable () -> URL
    private var pending: Task<(URL,URL),Error>?
    init(folder: @escaping @Sendable () -> URL) { self.folder = folder }
    /// The files are checked before every use: the cache folder can be emptied while Ara runs
    /// (by the user, a cleaner app or the system), and whichever file is missing is made again.
    func assets() async throws -> (URL,URL) {
        while true {
            if let current = pending {
                if let urls = try? await current.value, FileManager.default.fileExists(atPath:urls.0.path), FileManager.default.fileExists(atPath:urls.1.path) { return urls }
                // Another build may have started making them while this one waited.
                guard pending == current else { continue }
            }
            let task = Task { try await self.create() }; pending = task
            do { return try await task.value } catch { if pending == task { pending = nil }; throw error }
        }
    }
    private func create() async throws -> (URL,URL) {
        let folder = folder()
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let videoURL = folder.appendingPathComponent("clock-v1.mov")
        let audioURL = folder.appendingPathComponent("silence-v1.caf")
        if !FileManager.default.fileExists(atPath:videoURL.path) {
            let temporary = folder.appendingPathComponent(UUID().uuidString+".mov")
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
            // Made while another build waited on the writer: keep that one.
            if !FileManager.default.fileExists(atPath:videoURL.path) { try FileManager.default.moveItem(at:temporary,to:videoURL) }
        }
        if !FileManager.default.fileExists(atPath:audioURL.path) {
            // Written aside and moved into place, so a build never finds half a file.
            let temporary = folder.appendingPathComponent(UUID().uuidString+".caf")
            defer { try? FileManager.default.removeItem(at:temporary) }
            let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
            do {                                                   // the file is finished when it goes
                let file = try AVAudioFile(forWriting:temporary,settings:format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
                buffer.frameLength = 48000
                for channel in 0..<2 { memset(buffer.floatChannelData![channel],0,48000*MemoryLayout<Float>.size) }
                try file.write(from:buffer)
            }
            try FileManager.default.moveItem(at:temporary,to:audioURL)
        }
        return (videoURL,audioURL)
    }
}
