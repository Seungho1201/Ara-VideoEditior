import Foundation
@preconcurrency import AVFoundation
import FrameCore
import Darwin

public actor MovieExporter {
    public init() {}
    public func export(_ bundle: RenderBundle, to destination: URL, progress: @escaping @Sendable (Double) async -> Void) async throws {
        let workspace = destination.deletingLastPathComponent().appendingPathComponent(".frame-\(UUID().uuidString).work",isDirectory:true)
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:false)
        let temporary = workspace.appendingPathComponent("output.partial.mp4")
        // Remove the parent too, so a late encoder callback cannot recreate an orphan file.
        defer { try? FileManager.default.removeItem(at:workspace) }
        let reader = try AVAssetReader(asset:bundle.composition)
        let videoTracks = try await bundle.composition.loadTracks(withMediaType:.video)
        let audioTracks = try await bundle.composition.loadTracks(withMediaType:.audio)
        let video = AVAssetReaderVideoCompositionOutput(videoTracks:videoTracks,videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferIOSurfacePropertiesKey as String:[:] as [String:String]])
        video.videoComposition = bundle.videoComposition; video.alwaysCopiesSampleData = false
        let audio = AVAssetReaderAudioMixOutput(audioTracks:audioTracks,audioSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false,AVSampleRateKey:48000,AVNumberOfChannelsKey:2])
        audio.audioMix = bundle.audioMix; audio.alwaysCopiesSampleData = false
        // Match the preview's retime algorithm, or a speed-changed clip exports at a different pitch than it previewed.
        audio.audioTimePitchAlgorithm = .spectral
        guard reader.canAdd(video), reader.canAdd(audio) else { throw EditError("Cannot configure export readers.") }
        reader.add(video); reader.add(audio); reader.timeRange = CMTimeRange(start:.zero,duration:bundle.duration.cmTime)
        let writer = try AVAssetWriter(outputURL:temporary,fileType:.mp4); writer.shouldOptimizeForNetworkUse = true
        writer.movieTimeScale = CMTimeScale(MediaTime.scale)
        let settings: [String:Any] = [AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:Int(bundle.size.width),AVVideoHeightKey:Int(bundle.size.height),AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:bundle.size.height > 1080 ? 40_000_000 : 12_000_000,AVVideoProfileLevelKey:AVVideoProfileLevelH264HighAutoLevel,AVVideoExpectedSourceFrameRateKey:bundle.frameRate.value,AVVideoMaxKeyFrameIntervalKey:Int(bundle.frameRate.value.rounded()*2),AVVideoAllowFrameReorderingKey:false],AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2]]
        let videoInput = AVAssetWriterInput(mediaType:.video,outputSettings:settings)
        videoInput.mediaTimeScale = CMTimeScale(MediaTime.scale)
        let audioInput = AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:192000])
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw EditError("H.264/AAC encoder unavailable.") }
        writer.add(videoInput); writer.add(audioInput)
        do {
            try Task.checkCancellation()
            guard writer.startWriting() else { throw writer.error ?? EditError("Cannot start MP4 writer.") }
            writer.startSession(atSourceTime:.zero)
            guard reader.startReading() else { throw reader.error ?? EditError("Cannot start media reader.") }
            var videoDone = false, audioDone = false
            var lastProgress = -1.0
            while !videoDone || !audioDone {
                try Task.checkCancellation()
                if writer.status == .failed { throw writer.error ?? EditError("Encoder failed.") }
                if reader.status == .failed { throw reader.error ?? EditError("Source media could not be decoded.") }
                var didWork = false
                if !videoDone && videoInput.isReadyForMoreMediaData {
                    var timestamp: Double?
                    try autoreleasepool {
                        if let sample = video.copyNextSampleBuffer() {
                            guard videoInput.append(sample) else { throw writer.error ?? EditError("Failed to encode a video frame.") }
                            timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        } else { videoInput.markAsFinished(); videoDone = true }
                    }
                    if let timestamp {
                        let value = min(0.99,timestamp/bundle.duration.seconds)
                        if value-lastProgress > 0.005 { lastProgress = value; await progress(value) }
                    }
                    didWork = true
                }
                if !audioDone && audioInput.isReadyForMoreMediaData {
                    try autoreleasepool {
                        if let sample = audio.copyNextSampleBuffer() {
                            guard audioInput.append(sample) else { throw writer.error ?? EditError("Failed to encode audio.") }
                        } else { audioInput.markAsFinished(); audioDone = true }
                    }
                    didWork = true
                }
                if !didWork { try await Task.sleep(for:.milliseconds(2)) }
                else { await Task.yield() }
            }
            if reader.status == .failed { throw reader.error ?? EditError("Media read failed.") }
            try Task.checkCancellation()
            writer.endSession(atSourceTime:bundle.duration.cmTime)
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? EditError("MP4 export did not complete.") }
            // POSIX rename atomically replaces an existing destination only after success.
            guard rename(temporary.path,destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
            await progress(1)
        } catch {
            reader.cancelReading(); writer.cancelWriting(); throw error
        }
    }
}
