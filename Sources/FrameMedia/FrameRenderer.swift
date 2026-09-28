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
    /// When the layer is drawn: the clip, widened by the part of a transition across a cut that
    /// lies outside it.
    public let visibleStart: MediaTime
    public let visibleEnd: MediaTime
    /// Where the track holds real frames for the layer. A transition that reaches past them (the
    /// source has nothing, or not enough, beyond the clip's edge) holds the first frame there
    /// (`headImage`) or the last one (`tailImage`), as Premiere and Resolve do.
    public let framesStart: MediaTime
    public let framesEnd: MediaTime
    public let headImage: CIImage?
    public let tailImage: CIImage?
    public let transitions: [LayerTransition]
    public init(clip: Clip, trackID: CMPersistentTrackID?, preferredTransform: CGAffineTransform = .identity,
                image: CIImage? = nil, fallbackImage: CIImage? = nil,
                visibleStart: MediaTime? = nil, visibleEnd: MediaTime? = nil,
                framesStart: MediaTime? = nil, framesEnd: MediaTime? = nil, headImage: CIImage? = nil, tailImage: CIImage? = nil,
                transitions: [LayerTransition] = []) {
        self.clip = clip; self.trackID = trackID; self.preferredTransform = preferredTransform
        self.image = image; self.fallbackImage = fallbackImage
        self.visibleStart = visibleStart ?? clip.start; self.visibleEnd = visibleEnd ?? clip.end
        self.framesStart = framesStart ?? self.visibleStart; self.framesEnd = framesEnd ?? self.visibleEnd
        self.headImage = headImage; self.tailImage = tailImage
        self.transitions = transitions
    }
    /// The same layer showing a changed clip (style, text) and, for text, its new image.
    func with(clip: Clip, image newImage: CIImage?) -> RenderLayer {
        RenderLayer(clip:clip,trackID:trackID,preferredTransform:preferredTransform,image:newImage ?? image,fallbackImage:fallbackImage,
                    visibleStart:visibleStart,visibleEnd:visibleEnd,framesStart:framesStart,framesEnd:framesEnd,
                    headImage:headImage,tailImage:tailImage,transitions:transitions)
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
            layer.clip.id == clip.id ? layer.with(clip:clip,image:newImage) : layer
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
        // One side of a transition across a cut, waiting for the other side (the next layer on its
        // lane): the two are combined over what the lanes below show, not stacked one on the other.
        var waiting: (transition: LayerTransition, image: CIImage, lane: Lane)?
        func flush() {
            guard let w = waiting else { return }
            waiting = nil
            result = TransitionRenderer.composite(w.transition,below:result,outgoing:w.transition.role == .outgoing ? w.image : nil,
                                                  incoming:w.transition.role == .incoming ? w.image : nil,at:time,canvas:bounds)
        }
        for layer in layers where time >= layer.visibleStart && time < layer.visibleEnd {
            guard let image = placedImage(layer,at:time,canvas:bounds,frame:frame) else { continue }
            let active = layer.transitions.first { $0.contains(time) }
            if let w = waiting, w.lane != layer.clip.lane || w.transition.id != active?.id { flush() }
            guard let transition = active else { result = image.composited(over:result); continue }
            if !transition.paired {
                result = TransitionRenderer.composite(transition,below:result,outgoing:transition.role == .outgoing ? image : nil,
                                                      incoming:transition.role == .incoming ? image : nil,at:time,canvas:bounds)
            } else if let w = waiting {
                waiting = nil
                let (a,b) = transition.role == .incoming ? (w.image,image) : (image,w.image)
                result = TransitionRenderer.composite(transition,below:result,outgoing:a,incoming:b,at:time,canvas:bounds)
            } else {
                waiting = (transition,image,layer.clip.lane)
            }
        }
        flush()
        return result.cropped(to:bounds)
    }
    /// A layer's picture at `time`, styled and placed on the canvas.
    private static func placedImage(_ layer: RenderLayer, at time: MediaTime, canvas bounds: CGRect, frame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage? {
        var image: CIImage
        if let still = layer.image { image = still }
        else if let id = layer.trackID, let buffer = frame(id) { image = CIImage(cvPixelBuffer:buffer).transformed(by:layer.coreImageOrientation) }
        // Outside the frames the track holds for a transition: hold the nearest one.
        else if time < layer.framesStart, let head = layer.headImage ?? layer.fallbackImage { image = head.transformed(by:layer.coreImageOrientation) }
        else if time >= layer.framesEnd, let tail = layer.tailImage ?? layer.fallbackImage { image = tail.transformed(by:layer.coreImageOrientation) }
        // A decoder that has not primed yet must not blank the frame or abort the whole render.
        else if let fallback = layer.fallbackImage { image = fallback.transformed(by:layer.coreImageOrientation) }
        else { return nil }
        let s = layer.clip.style
        image = image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let geometry = VisualGeometry(sourceSize:extent.size,canvasSize:bounds.size,style:s,isText:layer.clip.kind == .text)
        image = image.applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:s.brightness,kCIInputContrastKey:s.contrast,kCIInputSaturationKey:s.saturation])
        return image.transformed(by:geometry.renderTransform)
            .applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:s.opacity)])
    }
    /// Room a title's image keeps for its outline and shadow (the shadow's distance plus its blur's
    /// spread), in 1080-basis units, on every side: an effect never moves the letters. The
    /// transform box leaves it out, so it fits the letters, not the shadow.
    public static func effectMargin(_ style: ClipStyle) -> CGFloat {
        let reach = (style.hasOutline ? style.outlineWidth : 0)+(style.hasShadow ? style.shadowDistance+style.shadowBlur*1.5 : 0)
        return reach > 0 ? ceil(reach)+2 : 0
    }
    /// A title drawn into an image. `scale` is output pixels per point of the 1080-pixel basis the
    /// style is written in (2 for a 4K export). The text is laid out once, at the basis size, and
    /// drawn scaled: a 4K title breaks, spaces and sizes everything (emoji included) exactly as
    /// the preview does, only rasterised at 4K instead of enlarged from 1080. The image comes back
    /// in basis units, so it is placed the same at every resolution. Titles without an outline or
    /// shadow at scale 1 keep exactly the raster they always had.
    public static func textImage(_ style: ClipStyle, scale requested: CGFloat = 1) throws -> CIImage {
        let scale = max(1,requested.isFinite ? requested : 1)
        let space = CGColorSpace(name:CGColorSpace.sRGB)!
        let font = FontLibrary.font(style.fontName,size:style.fontSize)       // the default when not available here
        let color = CGColor(colorSpace:space,components:[style.red,style.green,style.blue,1])!
        let text = NSAttributedString(string:style.text.isEmpty ? " " : style.text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):color])
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter,CFRange(location:0,length:0),nil,CGSize(width:1700,height:4000),nil)
        let box = CGRect(x:0,y:0,width:ceil(suggested.width),height:ceil(suggested.height))
        let frame = CTFramesetterCreateFrame(framesetter,CFRange(location:0,length:0),CGPath(rect:box,transform:nil),nil)
        // Some fonts draw past their line metrics (Gmarket Sans descenders reach 0.35 em below a
        // 0.2 em descent). Widen the margin, on every side so the title stays centred, only when
        // the ink needs it.
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating:.zero,count:lines.count)
        CTFrameGetLineOrigins(frame,CFRange(location:0,length:0),&origins)
        let ink = zip(lines,origins).reduce(CGRect.null) { $0.union(CTLineGetImageBounds($1.0,nil).offsetBy(dx:$1.1.x,dy:$1.1.y)) }
        let overhang = ink.isNull ? 0 : max(0,-ink.minX,-ink.minY,ink.maxX-box.maxX,ink.maxY-box.maxY)
        let pad = (overhang > 10 ? Int(ceil(overhang))+2 : 12)+Int(effectMargin(style))
        let width = max(8,Int(box.width)+2*pad), height = max(8,Int(box.height)+2*pad)
        guard let context = CGContext(data:nil,width:Int(CGFloat(width)*scale),height:Int(CGFloat(height)*scale),bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditError("Cannot render text.") }
        context.scaleBy(x:scale,y:scale)
        context.translateBy(x:CGFloat(pad),y:CGFloat(pad))
        CTFrameDraw(frame,context)
        guard var image = context.makeImage() else { throw EditError("Cannot create text image.") }
        if style.hasOutline || style.hasShadow { image = try withEffects(image,drawnIn:context,style,scale:scale) }
        let drawn = CIImage(cgImage:image)
        // Back to the 1080 layout's size exactly, also for scales such as 4/3 (QHD) whose
        // pixel sizes round: the picture then fits the same box at every quality.
        return scale == 1 ? drawn : drawn.transformed(by:CGAffineTransform(scaleX:CGFloat(width)/CGFloat(image.width),y:CGFloat(height)/CGFloat(image.height)))
    }
    /// The letters with their outline under them and one shadow under both (never one per part:
    /// the shadow is cast by the finished picture). `context` holds the letters' pixels.
    private static func withEffects(_ letters: CGImage, drawnIn context: CGContext, _ style: ClipStyle, scale: CGFloat) throws -> CGImage {
        let width = letters.width, height = letters.height, space = CGColorSpace(name:CGColorSpace.sRGB)!
        let all = CGRect(x:0,y:0,width:width,height:height)
        func canvas() throws -> CGContext {
            guard let made = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditError("Cannot render text.") }
            return made
        }
        var body = letters
        if style.hasOutline {
            guard let pixels = context.data else { throw EditError("Cannot render text.") }
            let cover = TitleOutline.coverage(of:pixels.assumingMemoryBound(to:UInt8.self),width:width,height:height,bytesPerRow:context.bytesPerRow,radius:style.outlineWidth*scale)
            let outlined = try canvas()
            guard let data = outlined.data else { throw EditError("Cannot render text.") }
            // Premultiplied sRGB in the outline's colour, then the letters drawn over it.
            let bytes = data.assumingMemoryBound(to:UInt8.self), rowBytes = outlined.bytesPerRow
            let tint = [style.outlineRed,style.outlineGreen,style.outlineBlue].map { $0*255 }
            for y in 0..<height {
                for x in 0..<width {
                    let c = cover[y*width+x]
                    guard c > 0 else { continue }
                    let i = y*rowBytes+x*4, a = Double(c)/255
                    bytes[i] = UInt8(tint[0]*a+0.5); bytes[i+1] = UInt8(tint[1]*a+0.5); bytes[i+2] = UInt8(tint[2]*a+0.5); bytes[i+3] = c
                }
            }
            outlined.draw(letters,in:all)
            guard let made = outlined.makeImage() else { throw EditError("Cannot create text image.") }
            body = made
        }
        if style.hasShadow {
            let shadowed = try canvas()
            // The angle is on screen, clockwise from the right, whatever the title's rotation (the
            // image is turned clockwise by `rotation` after this). Quartz offsets are y-up and,
            // like the blur, in pixels.
            let angle = (style.shadowAngle-style.rotation)*Double.pi/180, distance = style.shadowDistance*scale
            let color = CGColor(colorSpace:space,components:[style.shadowRed,style.shadowGreen,style.shadowBlue,style.shadowOpacity])!
            shadowed.setShadow(offset:CGSize(width:cos(angle)*distance,height:-sin(angle)*distance),blur:style.shadowBlur*scale,color:color)
            shadowed.draw(body,in:all)
            guard let made = shadowed.makeImage() else { throw EditError("Cannot create text image.") }
            body = made
        }
        return body
    }
}

public final class FrameCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    /// Sources arrive in their own colour and layout (HDR and wide colour included) and are
    /// converted by one SourceFrameConverter, whichever of preview, snapshot or export asks.
    public let sourcePixelBufferAttributes: [String:any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String:SourceFrameConverter.sourceFormats,kCVPixelBufferMetalCompatibilityKey as String:true]
    public let requiredPixelBufferAttributesForRenderContext: [String:any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferMetalCompatibilityKey as String:true]
    public let supportsWideColorSourceFrames = true
    public let supportsHDRSourceFrames = true
    private let context = FrameRenderer.makeContext()
    private let converter = SourceFrameConverter()             // used only on `queue`
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
                    let image = try FrameRenderer.render(layers:instruction.layers,at:MediaTime(request.compositionTime),size:request.renderContext.size,
                                                         frame:{ request.sourceFrame(byTrackID:$0).flatMap { converter.rec709($0) } })
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
