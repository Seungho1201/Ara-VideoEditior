import Foundation
@preconcurrency import AVFoundation
import FrameCore
import Darwin

public actor MovieExporter {
    public init() {}
    /// Failures are told in terms of what the user chose and uses: the destination folder (never
    /// the hidden work folder inside it) and the source file that stopped being readable.
    public func export(_ bundle: RenderBundle, to destination: URL, progress: @escaping @Sendable (Double) async -> Void) async throws {
        let folder = destination.deletingLastPathComponent()
        let workspace = folder.appendingPathComponent(".frame-\(UUID().uuidString).work",isDirectory:true)
        do { try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:false) }
        catch { throw Self.cannotWrite(in:folder,error) }
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
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL:temporary,fileType:.mp4) } catch { throw Self.cannotWrite(in:folder,error) }
        writer.shouldOptimizeForNetworkUse = true
        writer.movieTimeScale = CMTimeScale(MediaTime.scale)
        let settings: [String:Any] = [AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:Int(bundle.size.width),AVVideoHeightKey:Int(bundle.size.height),AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:OutputQuality.bitRate(shortEdge:Int(min(bundle.size.width,bundle.size.height))),AVVideoProfileLevelKey:AVVideoProfileLevelH264HighAutoLevel,AVVideoExpectedSourceFrameRateKey:bundle.frameRate.value,AVVideoMaxKeyFrameIntervalKey:Int(bundle.frameRate.value.rounded()*2),AVVideoAllowFrameReorderingKey:false],AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2]]
        let videoInput = AVAssetWriterInput(mediaType:.video,outputSettings:settings)
        videoInput.mediaTimeScale = CMTimeScale(MediaTime.scale)
        let audioInput = AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:192000])
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw EditError("H.264/AAC encoder unavailable.") }
        writer.add(videoInput); writer.add(audioInput)
        do {
            try Task.checkCancellation()
            guard writer.startWriting() else { throw Self.cannotWrite(in:folder,writer.error) }
            writer.startSession(atSourceTime:.zero)
            guard reader.startReading() else { throw Self.unreadable(bundle) }
            var videoDone = false, audioDone = false
            var lastProgress = -1.0
            while !videoDone || !audioDone {
                try Task.checkCancellation()
                if writer.status == .failed { throw Self.cannotWrite(in:folder,writer.error) }
                if reader.status == .failed { throw Self.unreadable(bundle) }
                var didWork = false
                if !videoDone && videoInput.isReadyForMoreMediaData {
                    var timestamp: Double?
                    try autoreleasepool {
                        if let sample = video.copyNextSampleBuffer() {
                            guard videoInput.append(sample) else { throw Self.cannotWrite(in:folder,writer.error) }
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
                            guard audioInput.append(sample) else { throw Self.cannotWrite(in:folder,writer.error) }
                        } else { audioInput.markAsFinished(); audioDone = true }
                    }
                    didWork = true
                }
                if !didWork { try await Task.sleep(for:.milliseconds(2)) }
                else { await Task.yield() }
            }
            if reader.status == .failed { throw Self.unreadable(bundle) }
            try Task.checkCancellation()
            writer.endSession(atSourceTime:bundle.duration.cmTime)
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw Self.cannotWrite(in:folder,writer.error) }
            // POSIX rename atomically replaces an existing destination only after success.
            guard rename(temporary.path,destination.path) == 0 else { throw EditError("“\(destination.lastPathComponent)” cannot be replaced. Choose another name.") }
            await progress(1)
        } catch {
            reader.cancelReading(); writer.cancelWriting(); throw error
        }
    }
    /// A file error while writing in `folder` (the system's own text would name the hidden work
    /// folder), as no space or no way to save there; an encoder error as it is.
    private static func cannotWrite(in folder: URL, _ error: Error?) -> Error {
        let name = FileManager.default.displayName(atPath:folder.path)
        let errors = [error as NSError?,(error as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
        if errors.contains(where: { ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError) || ($0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC))
                                    || ($0.domain == AVFoundationErrorDomain && $0.code == AVError.Code.diskFull.rawValue) }) {
            return EditError("There is not enough space in “\(name)” to export this movie. Free some space or choose another folder.")
        }
        if errors.contains(where: { ($0.domain == NSCocoaErrorDomain && (NSFileErrorMinimum...NSFileErrorMaximum).contains($0.code)) || $0.domain == NSPOSIXErrorDomain }) {
            return EditError("Ara cannot save the movie in “\(name)”. Choose a folder you can write to.")
        }
        return error ?? EditError("Encoder failed.")
    }
    /// A source that failed mid-export, named when one has gone, become unreadable or changed
    /// since the composition was built (a file cut short under the reader, a drive ejected).
    static func unreadable(_ bundle: RenderBundle) -> EditError {
        let changed = bundle.sources.filter { url,stamp in !FileManager.default.isReadableFile(atPath:url.path) || FileStamp(url) != stamp }.keys.map(\.lastPathComponent).sorted()
        if let name = changed.first {
            return EditError("“\(name)” could not be read while exporting. Check that the file is still there and its drive is connected, then export again.")
        }
        return EditError("A source file could not be read while exporting. Check that your media files are still there and their drives are connected, then export again.")
    }
}
