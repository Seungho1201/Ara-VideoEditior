import Foundation
@preconcurrency import AVFoundation
import VideoToolbox
import FrameCore

/// FHD stand-ins for video larger than 1920 × 1080, used only by the preview.
///
/// The composed preview is already 1920 × 1080, but a 4K source is still decoded at 4K, and a
/// frame-exact seek into long-GOP HEVC decodes every frame back to the previous keyframe (about a
/// second on phone footage). A proxy is the same picture at FHD with a keyframe every fifth of a
/// second and no frame reordering, so scrubbing costs a few 1080p frames instead of dozens of 4K
/// ones. Export and snapshots always read the original.
///
/// A proxy keeps what the preview depends on: identical sample timestamps (clip in/out points and
/// speed map one to one), the source's colour tags and bit depth (HLG and PQ still reach the same
/// tone-mapping step as the original), and the track orientation. Geometry needs no special care:
/// placement is computed from the aspect ratio, which scaling by one factor keeps.
public enum ProxyMaker {
    /// The proxy's stored size, or nil when the source already fits in 1920 × 1080 either way round.
    public static func proxySize(for stored: CGSize) -> CGSize? {
        let long = max(stored.width,stored.height), short = min(stored.width,stored.height)
        guard long > 0, short > 0 else { return nil }
        let factor = min(1920/long,1080/short)
        guard factor < 1 else { return nil }
        func even(_ value: CGFloat) -> CGFloat { max(2,(value*factor/2).rounded()*2) }
        return CGSize(width:even(stored.width),height:even(stored.height))
    }
    /// True for a source a proxy would be made for (display size from the media reference).
    public static func wantsProxy(width: Int, height: Int) -> Bool {
        proxySize(for:CGSize(width:width,height:height)) != nil
    }
    static var directory: URL {
        let url = MediaPaths.cache.appendingPathComponent("proxies",isDirectory:true)
        try? FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    /// Names the proxy format. Changing how proxies are made changes it, so older ones are remade.
    static let suffix = "-fhd3.mov"
    /// Keyed by the source's path, size and modification date: a replaced file gets a new proxy.
    /// Symlinks are resolved first, so every spelling of one file's path finds the same proxy.
    public static func url(for source: URL) -> URL {
        directory.appendingPathComponent(MediaPaths.key(for:source.resolvingSymlinksInPath())+suffix)
    }
    /// The finished proxy for this source, if one is on disk. Marks it used, for pruning.
    public static func existing(for source: URL) -> URL? {
        let url = url(for:source)
        guard FileManager.default.isReadableFile(atPath:url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:url.path)
        return url
    }
    /// Deletes proxies unused for `days`, proxies of an older format, and leftovers of interrupted
    /// runs. Caches may also be purged by the system; a missing proxy is simply made again.
    public static func prune(unusedFor days: Double = 30) {
        let cutoff = Date().addingTimeInterval(-days*86400)
        let files = (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let partial = file.lastPathComponent.hasPrefix("partial-")
            let outdated = !partial && !file.lastPathComponent.hasSuffix(suffix)
            if modified < cutoff || outdated || (partial && modified < Date().addingTimeInterval(-86400)) { try? FileManager.default.removeItem(at:file) }
        }
    }

    /// Makes the proxy for `source` and returns its URL, or nil when the source needs none.
    /// Runs on its own queue; cancelling the calling task stops it and removes the partial file.
    public static func make(from source: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL? {
        let destination = url(for:source)
        if FileManager.default.isReadableFile(atPath:destination.path) { return destination }
        let asset = AVURLAsset(url:source)
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { return nil }
        let (stored,transform,timeRange,formats,fps,timescale) = try await track.load(.naturalSize,.preferredTransform,.timeRange,.formatDescriptions,.nominalFrameRate,.naturalTimeScale)
        guard let size = proxySize(for:stored), let format = formats.first else { return nil }
        // Sources a plain 4:2:0 HEVC proxy cannot stand in for keep previewing from the original:
        // - Alpha: the proxy would be opaque where the original lets lower lanes show through.
        // - Non-square pixels or a clean aperture: the compositor draws the stored pixels, while
        //   the natural size is the corrected one, so a proxy made from it would change the shape.
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let alpha = (CMFormatDescriptionGetExtension(format,extensionKey:kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool) == true
            || (CMFormatDescriptionGetExtension(format,extensionKey:kCMFormatDescriptionExtension_Depth) as? Int) == 32
        guard !alpha, CGSize(width:Int(dimensions.width),height:Int(dimensions.height)) == stored else { return nil }
        func tag(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(format,extensionKey:key) as? String }
        let transfer = tag(kCMFormatDescriptionExtension_TransferFunction)
        let primaries = tag(kCMFormatDescriptionExtension_ColorPrimaries), matrix = tag(kCMFormatDescriptionExtension_YCbCrMatrix)
        // The writer raises an uncatchable exception for a colour value it has no constant for
        // (BT.470BG, for one, arrives as "YCbCrMatrix#5"). Such a source keeps the original.
        if let primaries, !Self.primaries.contains(primaries) { return nil }
        if let transfer, !Self.transfers.contains(transfer) { return nil }
        if let matrix, !Self.matrices.contains(matrix) { return nil }
        let depth = CMFormatDescriptionGetExtension(format,extensionKey:kCMFormatDescriptionExtension_BitsPerComponent) as? Int ?? 8
        let tenBit = depth > 8 || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)

        let reader = try AVAssetReader(asset:asset)
        // The decoder scales on the way out; 4:2:0 at the source's bit depth, no colour conversion.
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[
            kCVPixelBufferPixelFormatTypeKey as String:tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String:Int(size.width),kCVPixelBufferHeightKey as String:Int(size.height)])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EditError("Cannot read \(source.lastPathComponent) for its preview proxy.") }
        reader.add(output)

        let rate = fps > 0 ? Double(fps) : 30
        var compression: [String:Any] = [
            AVVideoAverageBitRateKey:Int(min(40e6,max(4e6,size.width*size.height*rate*0.1))),
            AVVideoMaxKeyFrameIntervalKey:max(1,Int((rate/5).rounded())),
            AVVideoAllowFrameReorderingKey:false,
            AVVideoExpectedSourceFrameRateKey:rate,
            AVVideoProfileLevelKey:tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel as String : kVTProfileLevel_HEVC_Main_AutoLevel as String]
        do {
            // HDR metadata mirrors the source. Left on Auto, the encoder adds Dolby Vision metadata to
            // an HLG proxy of a plain HLG source, and the preview could tone-map it differently.
            let atoms = CMFormatDescriptionGetExtension(format,extensionKey:kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String:Any]
            if !(atoms?.keys.contains { ["dvcC","dvvC","dvwC"].contains($0) } ?? false) {
                compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_None
            }
            if let data = CMFormatDescriptionGetExtension(format,extensionKey:kCMFormatDescriptionExtension_MasteringDisplayColorVolume) { compression[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] = data }
            if let data = CMFormatDescriptionGetExtension(format,extensionKey:kCMFormatDescriptionExtension_ContentLightLevelInfo) { compression[kVTCompressionPropertyKey_ContentLightLevelInfo as String] = data }
        }
        var settings: [String:Any] = [AVVideoCodecKey:AVVideoCodecType.hevc,AVVideoWidthKey:Int(size.width),AVVideoHeightKey:Int(size.height),
                                      AVVideoCompressionPropertiesKey:compression]
        // Untagged stays untagged, so the preview interprets the proxy exactly as it would the source.
        if let primaries, let transfer, let matrix {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey:primaries,AVVideoTransferFunctionKey:transfer,AVVideoYCbCrMatrixKey:matrix]
        }
        let partial = directory.appendingPathComponent("partial-"+UUID().uuidString+".mov")
        let writer = try AVAssetWriter(outputURL:partial,fileType:.mov)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:settings)
        input.expectsMediaDataInRealTime = false
        // The source's own timescale. The writer's default (600) rounds 29.97, 59.94 and 120 fps
        // timestamps, and the preview would then show the neighbouring frame at many frame times.
        if timescale > 0 { input.mediaTimeScale = timescale }
        // Same orientation; the translation is in stored pixels, so it scales with the picture.
        let factor = size.width/stored.width
        input.transform = CGAffineTransform(a:transform.a,b:transform.b,c:transform.c,d:transform.d,tx:transform.tx*factor,ty:transform.ty*factor)
        guard writer.canAdd(input) else { throw EditError("Cannot write a preview proxy for \(source.lastPathComponent).") }
        writer.add(input)

        let job = ProxyJob(reader:reader,writer:writer,input:input,output:output,start:timeRange.start,end:timeRange.end.seconds,progress:progress)
        do {
            guard reader.startReading() else { throw reader.error ?? EditError("Cannot read \(source.lastPathComponent).") }
            guard writer.startWriting() else { throw writer.error ?? EditError("Cannot write a preview proxy.") }
            // Session at zero: a sample stamped T plays at movie time T, exactly as in the source.
            writer.startSession(atSourceTime:.zero)
            try await withTaskCancellationHandler { try await job.run() } onCancel: { job.cancel() }
            try Task.checkCancellation()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? EditError("The preview proxy could not be finished.") }
            try await verify(partial,size:size,against:timeRange)
            try? FileManager.default.removeItem(at:destination)
            try FileManager.default.moveItem(at:partial,to:destination)
            return destination
        } catch {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at:partial)
            throw error
        }
    }
    /// The colour values AVAssetWriter accepts (AVVideoSettings.h).
    static let primaries: Set<String> = [AVVideoColorPrimaries_ITU_R_709_2,AVVideoColorPrimaries_EBU_3213,AVVideoColorPrimaries_SMPTE_C,
                                         AVVideoColorPrimaries_P3_D65,AVVideoColorPrimaries_ITU_R_2020]
    static let transfers: Set<String> = [AVVideoTransferFunction_ITU_R_709_2,AVVideoTransferFunction_SMPTE_240M_1995,AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                                         AVVideoTransferFunction_ITU_R_2100_HLG,AVVideoTransferFunction_Linear,AVVideoTransferFunction_IEC_sRGB]
    static let matrices: Set<String> = [AVVideoYCbCrMatrix_ITU_R_709_2,AVVideoYCbCrMatrix_ITU_R_601_4,AVVideoYCbCrMatrix_SMPTE_240M_1995,AVVideoYCbCrMatrix_ITU_R_2020]
    /// A proxy that would shift or shorten the picture is worse than none.
    private static func verify(_ url: URL, size: CGSize, against source: CMTimeRange) async throws {
        guard let track = try await AVURLAsset(url:url).loadTracks(withMediaType:.video).first else { throw EditError("The preview proxy has no video.") }
        let (natural,range) = try await track.load(.naturalSize,.timeRange)
        guard natural == size, abs(range.start.seconds-source.start.seconds) < 0.05,
              abs(range.end.seconds-source.end.seconds) < 0.1 else { throw EditError("The preview proxy does not match its source.") }
    }
}

/// Pumps decoded, scaled frames into the encoder on a private queue.
private final class ProxyJob: @unchecked Sendable {
    let reader: AVAssetReader, writer: AVAssetWriter, input: AVAssetWriterInput, output: AVAssetReaderTrackOutput
    let start: CMTime, end: Double, progress: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label:"com.framestudio.proxy",qos:.utility)
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Void,Error>?
    private var reported = -1.0              // touched only on `queue`
    private var leadFilled = false           // touched only on `queue`
    private var pending: CMSampleBuffer?     // touched only on `queue`
    init(reader: AVAssetReader, writer: AVAssetWriter, input: AVAssetWriterInput, output: AVAssetReaderTrackOutput,
         start: CMTime, end: Double, progress: @escaping @Sendable (Double) -> Void) {
        self.reader = reader; self.writer = writer; self.input = input; self.output = output
        self.start = start; self.end = end; self.progress = progress
    }
    func cancel() { lock.withLock { cancelled = true } }
    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            lock.withLock { self.continuation = continuation }
            input.requestMediaDataWhenReady(on:queue) { [self] in
                while input.isReadyForMoreMediaData {
                    if lock.withLock({ cancelled }) { finish(CancellationError()); return }
                    let sample: CMSampleBuffer
                    if let held = pending { pending = nil; sample = held }
                    else {
                        guard let next = output.copyNextSampleBuffer() else {
                            if reader.status == .failed { finish(reader.error ?? EditError("Reading the source failed.")); return }
                            finish(nil); return
                        }
                        // Nothing to encode in a sample that carries no picture.
                        guard CMSampleBufferGetImageBuffer(next) != nil else { continue }
                        sample = leadIn(before:next)
                    }
                    guard input.append(sample) else { finish(writer.error ?? EditError("Encoding the preview proxy failed.")); return }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if end > 0, time.isFinite, time/end - reported >= 0.01 { reported = time/end; progress(min(1,reported)) }
                }
            }
        }
    }
    /// Phone HEVC often decodes nothing for its first few frames (leading pictures ahead of the
    /// edit). Left empty, the proxy would have no picture at the very start, where the original
    /// preview shows its first-frame stand-in, so the first decoded frame also covers that span.
    /// Returns what to append now; the real first frame waits in `pending` for the next turn.
    private func leadIn(before sample: CMSampleBuffer) -> CMSampleBuffer {
        guard !leadFilled else { return sample }
        leadFilled = true
        let first = CMSampleBufferGetPresentationTimeStamp(sample)
        guard first.isValid, start.isValid, CMTimeCompare(first,start) > 0 else { return sample }
        var timing = CMSampleTimingInfo(duration:first-start,presentationTimeStamp:start,decodeTimeStamp:.invalid)
        var lead: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator:nil,sampleBuffer:sample,sampleTimingEntryCount:1,
                                                    sampleTimingArray:&timing,sampleBufferOut:&lead) == noErr, let lead else { return sample }
        pending = sample
        return lead
    }
    /// Resumes the waiting task exactly once.
    private func finish(_ error: Error?) {
        guard let continuation = lock.withLock({ () -> CheckedContinuation<Void,Error>? in
            defer { self.continuation = nil }; return self.continuation
        }) else { return }
        input.markAsFinished()
        if let error { continuation.resume(throwing:error) } else { continuation.resume() }
    }
}
