import Foundation
import CoreVideo
import VideoToolbox
@preconcurrency import AVFoundation

/// Brings decoded source frames to 8-bit Rec.709 BGRA, the one conversion every path shares.
///
/// Left to itself, AVFoundation converts an HDR (HLG or PQ) source to the composition's SDR
/// colour differently for each consumer: AVAssetImageGenerator (snapshots) hands a custom
/// compositor the HLG code values untouched but tagged Rec.709, while AVPlayer (preview) and
/// AVAssetReader (export) tone-map them, except for the first frame each track delivers. A
/// snapshot then came out lighter and flatter than the preview it was taken from. So the video
/// composition asks for no colour conversion, the compositor takes every source in its own
/// colour, and this does the conversion with VideoToolbox, the same HDR-to-SDR mapping AVFoundation
/// applies in playback and export. Today's look is kept, and preview, snapshot, export and held
/// frames agree.
///
/// Not thread-safe: the compositor owns one and uses it on its render queue; held-frame reads make
/// their own (a session keeps what it converted until it is invalidated).
final class SourceFrameConverter: @unchecked Sendable {
    /// What the compositor and held-frame reads ask the decoder for; AVFoundation picks the
    /// closest match per source: 10-bit 4:2:0 for HEVC and H.264, 4:2:2 for ProRes 422, and 16-bit
    /// 4:4:4 with alpha (y416) for ProRes 4444, which keeps its alpha. No x444 or half-float RGBA:
    /// with x444 listed, AVFoundation hands ProRes 4444 over without its alpha plane. H.264 4:4:4
    /// still arrives as 4:2:0.
    static let sourceFormats: [OSType] = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                                          kCVPixelFormatType_4444AYpCbCr16]
    private var session: VTPixelTransferSession?
    private var pools: [Int:CVPixelBufferPool] = [:]
    init() {
        VTPixelTransferSessionCreate(allocator:nil,pixelTransferSessionOut:&session)
        guard let session else { return }
        VTSessionSetProperty(session,key:kVTPixelTransferPropertyKey_DestinationColorPrimaries,value:kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session,key:kVTPixelTransferPropertyKey_DestinationTransferFunction,value:kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(session,key:kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,value:kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    }
    deinit { if let session { VTPixelTransferSessionInvalidate(session) } }

    /// `pooled` recycles buffers for per-frame use; held frames live on and get their own.
    func rec709(_ source: CVPixelBuffer, pooled: Bool = true) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA, Self.isRec709(source) { return source }
        guard let session else { return nil }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        var output: CVPixelBuffer?
        if pooled, let pool = pool(width,height) { CVPixelBufferPoolCreatePixelBuffer(nil,pool,&output) }
        else { CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,Self.outputAttributes(width,height) as CFDictionary,&output) }
        guard let output, VTPixelTransferSessionTransferImage(session,from:source,to:output) == noErr else { return nil }
        CVBufferSetAttachment(output,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(output,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(output,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
        CVBufferRemoveAttachment(output,kCVImageBufferCGColorSpaceKey)
        return output
    }

    private static func isRec709(_ buffer: CVPixelBuffer) -> Bool {
        let primaries = CVBufferCopyAttachment(buffer,kCVImageBufferColorPrimariesKey,nil) as? String
        let transfer = CVBufferCopyAttachment(buffer,kCVImageBufferTransferFunctionKey,nil) as? String
        return primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String && transfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String
    }
    private static func outputAttributes(_ width: Int, _ height: Int) -> [String:Any] {
        [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,
         kCVPixelBufferIOSurfacePropertiesKey as String:[:] as [String:Any],kCVPixelBufferMetalCompatibilityKey as String:true]
    }
    private func pool(_ width: Int, _ height: Int) -> CVPixelBufferPool? {
        let key = width<<20 | height
        if let pool = pools[key] { return pool }
        // Sources come in a handful of sizes; a stale pool only costs its idle buffers.
        if pools.count >= 8 { pools.removeAll() }
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil,nil,Self.outputAttributes(width,height) as CFDictionary,&pool)
        pools[key] = pool
        return pool
    }

    /// The source frame shown at `time` (source clock), decoded natively and converted like the
    /// compositor's frames, for a held frame. Nil when the track has no frame there.
    static func heldFrame(of url: URL, at time: CMTime) async -> CVPixelBuffer? {
        let asset = AVURLAsset(url:url)
        guard let track = try? await asset.loadTracks(withMediaType:.video).first, !Task.isCancelled else { return nil }
        // AVAssetReader blocks while it decodes and needs a free Swift-pool thread to hand samples
        // over, so a read on that pool can starve it: read on a dispatch queue instead.
        let source = Unchecked((asset,track))
        return await withCheckedContinuation { continuation in
            readQueue.async { continuation.resume(returning:Unchecked(read(source.value.0,source.value.1,at:time))) }
        }.value
    }
    private static let readQueue = DispatchQueue(label:"com.framestudio.heldframes",qos:.userInitiated,attributes:.concurrent)
    private struct Unchecked<Value>: @unchecked Sendable { let value: Value; init(_ value: Value) { self.value = value } }
    private static func read(_ asset: AVAsset, _ track: AVAssetTrack, at time: CMTime) -> CVPixelBuffer? {
        // The reader hands out the frame on screen at its range start, so reading from `time` is
        // enough, except for an open-GOP clip's leading frames, which decode only from the
        // keyframe before them: then nothing at or before `time` comes out, and the read starts
        // half a second earlier.
        var shown = frame(asset,track,from:time,at:time)
        if shown.map({ $0.time > time }) ?? true, time > .zero {
            shown = frame(asset,track,from:CMTimeMaximum(.zero,time-CMTime(seconds:0.5,preferredTimescale:600)),at:time) ?? shown
        }
        guard let shown else { return nil }
        return SourceFrameConverter().rec709(shown.buffer,pooled:false)
    }
    private static func frame(_ asset: AVAsset, _ track: AVAssetTrack, from start: CMTime, at time: CMTime) -> (buffer: CVPixelBuffer, time: CMTime)? {
        guard let reader = try? AVAssetReader(asset:asset) else { return nil }
        reader.timeRange = CMTimeRange(start:start,end:time+CMTime(seconds:0.25,preferredTimescale:600))
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:sourceFormats])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        var shown: (buffer: CVPixelBuffer, time: CMTime)?
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            // Presentation order: the last frame at or before `time` is the one on screen; with
            // none before it (the first frame starts later), the first one.
            let at = CMSampleBufferGetPresentationTimeStamp(sample)
            if at <= time || shown == nil { shown = (buffer,at) } else { break }
        }
        // A decode that failed part-way leaves an earlier frame; no held frame beats a wrong one.
        return reader.status == .failed ? nil : shown
    }
}
