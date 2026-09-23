import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreImage
import ImageIO
import CryptoKit
import FrameCore

public extension MediaTime {
    var cmTime: CMTime { CMTime(value: ticks, timescale: CMTimeScale(Self.scale)) }
    init(_ time: CMTime) { self.init(ticks: time.isNumeric ? CMTimeConvertScale(time, timescale: CMTimeScale(Self.scale), method: .roundTowardZero).value : 0) }
}

public enum MediaPaths {
    public static var cache: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.framestudio.editor", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public static func resolve(_ reference: MediaReference) -> (url: URL, stale: Bool, needsRelink: Bool) {
        if let data = reference.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) { return (url,stale,false) }
        }
        // A path or a bookmark issued to another app is not an access grant.
        // Request a user-selected replacement instead of opening an unscoped protected file.
        return (URL(fileURLWithPath: reference.path), true, true)
    }
    public static func key(for url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let input = "v1|\(url.path)|\(attrs?[.size] ?? 0)|\(attrs?[.modificationDate] ?? "")"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct MediaAnalysis: Sendable {
    public let thumbnail: Data?
    public let peaks: [Float]
    public init(thumbnail: Data?, peaks: [Float]) { self.thumbnail = thumbnail; self.peaks = peaks }
}

public actor MediaLibrary {
    public init() {}

    public func inspect(_ url: URL) async throws -> MediaReference {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw EditError("Cannot read \(url.lastPathComponent). Relink the source file.") }
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        if ["png","jpg","jpeg","tif","tiff"].contains(ext) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,nil), CGImageSourceGetCount(source) > 0,
                  let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else { throw EditError("Unsupported or damaged image: \(url.lastPathComponent)") }
            guard (props[kCGImagePropertyDepth] as? Int ?? 8) <= 8 else { throw EditError("High-bit-depth/HDR images are not supported in this SDR MVP. Convert to 8-bit sRGB PNG/JPEG.") }
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeHDRGainMap) != nil ||
                CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeISOGainMap) != nil {
                throw EditError("HDR gain-map images are not supported. Convert to a standard SDR PNG/JPEG first.")
            }
            guard width > 0, height > 0, width <= 16384, height <= 16384 else { throw EditError("Image dimensions must be between 1 and 16384 pixels.") }
            return MediaReference(name:url.lastPathComponent,path:url.path,bookmark:MediaPaths.bookmark(for:url),kind:.image,duration:.init(seconds:5),width:width,height:height)
        }
        let asset = AVURLAsset(url:url)
        guard try await asset.load(.isPlayable), !(try await asset.load(.hasProtectedContent)) else { throw EditError("Unsupported or protected media: \(url.lastPathComponent)") }
        let duration = MediaTime(try await asset.load(.duration))
        guard duration > .zero, duration.seconds < 7 * 86400 else { throw EditError("Media must have a finite duration under 7 days.") }
        let videos = try await asset.loadTracks(withMediaType:.video)
        let audio = try await asset.loadTracks(withMediaType:.audio)
        if let video = videos.first {
            // HDR (PQ / HLG, BT.2020) is accepted and tone-mapped to SDR Rec.709 by the render
            // pipeline. Read the real colour tags instead of grepping a stringified extension
            // dictionary: that dump embeds sample-description atoms as hex, where "2084" and
            // "2100" occur by chance and refuse ordinary Rec.709 files.
            let formats = try await video.load(.formatDescriptions)
            for format in formats {
                let subtype = CMFormatDescriptionGetMediaSubType(format)
                // Dolby Vision profiles carry a second enhancement layer this app cannot combine.
                if subtype == 0x64766831 || subtype == 0x64766865 {
                    throw EditError("Dolby Vision is not supported. Convert \(url.lastPathComponent) to SDR Rec.709, HLG or PQ first.")
                }
                // A log curve is signalled by its OWN extension, never by TransferFunction, whose
                // value is always one of the nine CoreMedia constants (none of them a log curve).
                // Log footage graded as Rec.709 would export washed out, so refuse it.
                if CMFormatDescriptionGetExtension(format,extensionKey:kCMFormatDescriptionExtension_LogTransferFunction) != nil {
                    throw EditError("Log-encoded input is not supported. Convert \(url.lastPathComponent) to SDR Rec.709 first.")
                }
            }
            let size = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let bounds = CGRect(origin:.zero,size:size).applying(transform)
            let fps = try await video.load(.nominalFrameRate)
            return MediaReference(name:url.lastPathComponent,path:url.path,bookmark:MediaPaths.bookmark(for:url),kind:.video,duration:duration,width:Int(abs(bounds.width)),height:Int(abs(bounds.height)),frameRate:Double(fps),hasAudio:!audio.isEmpty)
        }
        guard !audio.isEmpty else { throw EditError("No supported video or audio stream in \(url.lastPathComponent). Images supported: PNG, JPEG, 8-bit TIFF.") }
        return MediaReference(name:url.lastPathComponent,path:url.path,bookmark:MediaPaths.bookmark(for:url),kind:.audio,duration:duration,hasAudio:true)
    }

    public func analyze(_ reference: MediaReference, at url: URL) async throws -> MediaAnalysis {
        let key = MediaPaths.key(for:url)
        let thumbURL = MediaPaths.cache.appendingPathComponent(key+".jpg")
        let peaksURL = MediaPaths.cache.appendingPathComponent(key+".json")
        var thumbnail = try? Data(contentsOf:thumbURL)
        if thumbnail == nil {
            var cgImage: CGImage?
            if reference.kind == .image, let source = CGImageSourceCreateWithURL(url as CFURL,nil) {
                cgImage = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:480,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary)
            } else if reference.kind == .video {
                let generator = AVAssetImageGenerator(asset:AVURLAsset(url:url))
                generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width:480,height:270)
                cgImage = try await generator.image(at:CMTime(seconds:min(0.2,reference.duration.seconds/2),preferredTimescale:600)).image
            }
            if let cgImage {
                let data = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(data,"public.jpeg" as CFString,1,nil) {
                    CGImageDestinationAddImage(destination,cgImage,[kCGImageDestinationLossyCompressionQuality:0.8] as CFDictionary)
                    if CGImageDestinationFinalize(destination) { thumbnail = data as Data; try? thumbnail?.write(to:thumbURL,options:.atomic) }
                }
            }
        }
        try Task.checkCancellation()
        var peaks = (try? Data(contentsOf:peaksURL)).flatMap { try? JSONDecoder().decode([Float].self,from:$0) } ?? []
        if peaks.isEmpty && reference.hasAudio {
            peaks = try await waveform(url, duration:reference.duration.seconds)
            try? JSONEncoder().encode(peaks).write(to:peaksURL,options:.atomic)
        }
        return MediaAnalysis(thumbnail:thumbnail,peaks:peaks)
    }

    private func waveform(_ url: URL, duration: Double) async throws -> [Float] {
        let asset = AVURLAsset(url:url)
        guard let track = try await asset.loadTracks(withMediaType:.audio).first else { return [] }
        let reader = try AVAssetReader(asset:asset)
        let settings: [String: Any] = [AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false,AVSampleRateKey:8000,AVNumberOfChannelsKey:1]
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:settings); output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EditError("Cannot analyze this audio format.") }; reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditError("Could not read audio.") }
        defer { reader.cancelReading() }
        let count = min(16000,max(256,Int(duration*24)))
        var peaks = [Float](repeating:0,count:count); var offset = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if let block = CMSampleBufferGetDataBuffer(sample) {
                var length = 0; var pointer: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(block,atOffset:0,lengthAtOffsetOut:nil,totalLengthOut:&length,dataPointerOut:&pointer) == kCMBlockBufferNoErr, let pointer {
                    let frames = length / MemoryLayout<Float>.size
                    pointer.withMemoryRebound(to:Float.self,capacity:frames) { values in
                        for i in 0..<frames {
                            let bin = min(count-1,Int(Double(offset+i)/max(1,duration*8000)*Double(count)))
                            peaks[bin] = max(peaks[bin],min(1,abs(values[i])))
                        }
                    }
                    offset += frames
                }
            }
            await Task.yield()
        }
        if reader.status == .failed { throw reader.error ?? EditError("Waveform analysis failed.") }
        return peaks
    }
}
