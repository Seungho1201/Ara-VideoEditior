import Foundation
@preconcurrency import AVFoundation
import CoreImage
import CoreText
import Metal
import FrameCore

/// Immutable snapshots are shared with AVFoundation's compositor queue.
public struct RenderLayer: @unchecked Sendable {
    /// The track's preferred transform, restated for Core Image. A track transform is written for a
    /// y-down pixel grid; Core Image is y-up. Conjugating by a vertical flip negates b and c, which
    /// matters exactly for 90° and 270° (portrait phone video): applied as-is those came out upside
    /// down. 0°, 180° and mirror transforms are unchanged. The translation is dropped because the
    /// renderer moves every layer back to the origin right after orienting it.
    public var coreImageOrientation: CGAffineTransform {
        let t = preferredTransform
        return CGAffineTransform(a:t.a,b:-t.b,c:-t.c,d:t.d,tx:0,ty:0)
    }
    public let clip: Clip
    public let trackID: CMPersistentTrackID?
    public let preferredTransform: CGAffineTransform
    public let image: CIImage?
    /// Stand-in for composition times where the decoder has not yet produced a buffer.
    /// HDR sources prime for about three frames at the start of every segment.
    public let fallbackImage: CIImage?
    public init(clip: Clip, trackID: CMPersistentTrackID?, preferredTransform: CGAffineTransform = .identity,
                image: CIImage? = nil, fallbackImage: CIImage? = nil) {
        self.clip = clip; self.trackID = trackID; self.preferredTransform = preferredTransform
        self.image = image; self.fallbackImage = fallbackImage
    }
}

public final class FrameInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = true
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    public let layers: [RenderLayer]
    public init(duration: CMTime, trackIDs: [CMPersistentTrackID], layers: [RenderLayer]) {
        timeRange = CMTimeRange(start:.zero,duration:duration)
        requiredSourceTrackIDs = trackIDs.map { NSNumber(value:$0) }
        self.layers = layers
    }
    /// Reuses decoded sources and track mappings while replacing only the edited layer.
    public func replacingTransform(of clip: Clip) -> FrameInstruction { replacingLayer(for:clip) }
    /// Swaps one layer's clip (and, for text, its rendered image) while keeping the track, the
    /// source transform and the decoder-priming fallback, so a paused preview can re-render
    /// without rebuilding the AVComposition or replacing the player item.
    public func replacingLayer(for clip: Clip, image newImage: CIImage? = nil) -> FrameInstruction {
        let updated = layers.map { layer in
            layer.clip.id == clip.id
                ? RenderLayer(clip:clip,trackID:layer.trackID,preferredTransform:layer.preferredTransform,
                              image:newImage ?? layer.image,fallbackImage:layer.fallbackImage)
                : layer
        }
        return FrameInstruction(duration:timeRange.duration,trackIDs:(requiredSourceTrackIDs ?? []).compactMap { ($0 as? NSNumber)?.int32Value },layers:updated)
    }
}

public enum FrameRenderer {
    // Match the color space AVFoundation derives from our actual video attachments.
    // CGColorSpace.itur_709 is a different ICC transfer curve from NCLC 1-1-1's HDTV
    // profile on macOS. Rendering with one and tagging with the other lifts midtones
    // every time a captured frame is imported and composed again.
    public static let outputColorSpace: CGColorSpace = {
        let attachments: [CFString:Any] = [
            kCVImageBufferColorPrimariesKey:kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey:kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey:kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ]
        return CVImageBufferCreateColorSpaceFromAttachments(attachments as CFDictionary)!.takeRetainedValue()
    }()
    public static func makeContext() -> CIContext {
        let options: [CIContextOption:Any] = [.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!, .outputColorSpace:outputColorSpace, .cacheIntermediates:false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice:device,options:options) }
        return CIContext(options:options)
    }
    public static func render(layers: [RenderLayer], at time: MediaTime, size: CGSize,
                              frame: (CMPersistentTrackID) -> CVPixelBuffer?) throws -> CIImage {
        let bounds = CGRect(origin:.zero,size:size)
        var result = CIImage(color:.black).cropped(to:bounds)
        for layer in layers where time >= layer.clip.start && time < layer.clip.end {
            var image: CIImage
            if let still = layer.image { image = still }
            else if let id = layer.trackID, let buffer = frame(id) { image = CIImage(cvPixelBuffer:buffer).transformed(by:layer.coreImageOrientation) }
            // A decoder that has not primed yet must not blank the frame or abort the whole render.
            else if let fallback = layer.fallbackImage { image = fallback.transformed(by:layer.coreImageOrientation) }
            else { continue }
            let s = layer.clip.style
            image = image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { continue }
            let geometry = VisualGeometry(sourceSize:extent.size,canvasSize:size,style:s,isText:layer.clip.kind == .text)
            image = image.applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:s.brightness,kCIInputContrastKey:s.contrast,kCIInputSaturationKey:s.saturation])
            image = image.transformed(by:geometry.renderTransform)
                .applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:s.opacity)])
            result = image.composited(over:result)
        }
        return result.cropped(to:bounds)
    }
    public static func textImage(_ style: ClipStyle) throws -> CIImage {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString,style.fontSize,nil)
        let color = CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[style.red,style.green,style.blue,1])!
        let text = NSAttributedString(string:style.text.isEmpty ? " " : style.text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):color])
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter,CFRange(location:0,length:0),nil,CGSize(width:1700,height:4000),nil)
        let width = max(8,Int(ceil(suggested.width))+24), height = max(8,Int(ceil(suggested.height))+24)
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditError("Cannot render text.") }
        let path = CGPath(rect:CGRect(x:12,y:12,width:width-24,height:height-24),transform:nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter,CFRange(location:0,length:0),path,nil),context)
        guard let image = context.makeImage() else { throw EditError("Cannot create text image.") }
        return CIImage(cgImage:image)
    }
}

public final class FrameCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    public let sourcePixelBufferAttributes: [String:any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferMetalCompatibilityKey as String:true]
    public let requiredPixelBufferAttributesForRenderContext: [String:any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferMetalCompatibilityKey as String:true]
    public let supportsWideColorSourceFrames = false
    public let supportsHDRSourceFrames = false
    private let context = FrameRenderer.makeContext()
    private let queue = DispatchQueue(label:"com.framestudio.compositor",qos:.userInitiated)
    private let lock = NSLock()
    private var generation: UInt = 0
    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let generation = lock.withLock { self.generation }
        queue.async { [self] in
            guard lock.withLock({ self.generation == generation }) else { request.finishCancelledRequest(); return }
            autoreleasepool {
                do {
                    guard let instruction = request.videoCompositionInstruction as? FrameInstruction,
                          let output = request.renderContext.newPixelBuffer() else { throw EditError("Cannot allocate a video frame.") }
                    let image = try FrameRenderer.render(layers:instruction.layers,at:MediaTime(request.compositionTime),size:request.renderContext.size,frame:{ request.sourceFrame(byTrackID:$0) })
                    context.render(image,to:output,bounds:CGRect(origin:.zero,size:request.renderContext.size),colorSpace:FrameRenderer.outputColorSpace)
                    CVBufferSetAttachment(output,kCVImageBufferCGColorSpaceKey,FrameRenderer.outputColorSpace,.shouldPropagate)
                    CVBufferSetAttachment(output,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
                    CVBufferSetAttachment(output,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
                    CVBufferSetAttachment(output,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
                    request.finish(withComposedVideoFrame:output)
                } catch { request.finish(with:error) }
            }
        }
    }
    public func cancelAllPendingVideoCompositionRequests() { lock.withLock { generation &+= 1 } }
}
