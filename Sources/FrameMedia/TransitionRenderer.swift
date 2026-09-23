import Foundation
import CoreImage
import FrameCore

/// One side of a transition, as the layer it belongs to sees it.
public struct LayerTransition: Sendable, Hashable {
    public enum Role: Sendable, Hashable { case outgoing, incoming }
    public let id: UUID
    public let kind: TransitionKind
    public let direction: TransitionDirection
    public let role: Role
    /// True across a cut for kinds that show both clips at once: the renderer then combines this
    /// layer with the other side's. False for fades at a free edge, and for dips, which show one
    /// clip at a time.
    public let paired: Bool
    /// The whole window, and the cut inside it (for a fade, the cut is the window's far edge).
    public let start: MediaTime
    public let duration: MediaTime
    public let cut: MediaTime
    public init(id: UUID, kind: TransitionKind, direction: TransitionDirection, role: Role, paired: Bool, start: MediaTime, duration: MediaTime, cut: MediaTime) {
        self.id = id; self.kind = kind; self.direction = direction; self.role = role; self.paired = paired
        self.start = start; self.duration = duration; self.cut = cut
    }
    public var end: MediaTime { start+duration }
    /// When this side is drawn with the transition: a dip across a cut hands over at the cut.
    public func contains(_ time: MediaTime) -> Bool {
        let isDip = !kind.needsBothPictures && cut > start && cut < end
        if isDip { return role == .outgoing ? time >= start && time < cut : time >= cut && time < end }
        return time >= start && time < end
    }
    /// Progress through the window, or, for a dip across a cut, through this side's half.
    public func progress(at time: MediaTime) -> Double {
        var from = start, length = duration
        if !kind.needsBothPictures && cut > start && cut < end {
            if role == .outgoing { length = cut-start } else { from = cut; length = end-cut }
        }
        guard length.ticks > 0 else { return 1 }
        return min(1,max(0,Double((time-from).ticks)/Double(length.ticks)))
    }
}

/// Transitions as Core Image operations on one lane's picture over what the lanes below show.
///
/// The lane composites A (outgoing) and B (incoming) together, then over L (everything below), so
/// a dissolve is exactly mix(A over L, B over L) — a picture-in-picture or title never pops off at
/// the end — and a push's seam adds up to full coverage. Dissolves and dips blend in the encoded
/// (gamma) domain like Premiere, FFmpeg and Shotcut; a linear-light dissolve hangs bright and
/// then drops. Only built-in filters, so nothing needs a Metal build step. Maths after
/// gl-transitions (MIT) and FFmpeg xfade / MLT luma (formulas only).
public enum TransitionRenderer {
    /// The new result for a lane: `a` and/or `b` (placed on the canvas, premultiplied) over `below`.
    /// One of them is nil for a fade at a free edge, and for a dip's half.
    public static func composite(_ t: LayerTransition, below: CIImage, outgoing a: CIImage?, incoming b: CIImage?, at time: MediaTime, canvas: CGRect) -> CIImage {
        let p = t.progress(at:time), e = ease(p), u = canvas.width/1920
        func over(_ x: CIImage?) -> CIImage { x.map { $0.composited(over:below) } ?? below }
        switch t.kind {
        case .crossDissolve:
            return gammaMix(over(a),over(b),p,canvas)
        case .dipToBlack, .dipToWhite:
            let white: CGFloat = t.kind == .dipToWhite ? 1 : 0
            // Out: the outgoing picture goes to the colour; in: the incoming one comes out of it.
            if let a { return dip(a,ease(p),white).composited(over:below) }
            if let b { return dip(b,1-ease(p),white).composited(over:below) }
            return below
        case .blur:
            let radius = (40*u*sin(.pi*p)*2).rounded()/2          // half-pixel steps: fewer kernels
            if t.paired { return gammaMix(over(a.map { blur($0,radius,canvas) }),over(b.map { blur($0,radius,canvas) }),smoothstep(0.3,0.7,p),canvas) }
            if let a { return gammaMix(over(blur(a,40*u*e,canvas)),below,e,canvas) }
            if let b { return gammaMix(below,over(blur(b,40*u*(1-e),canvas)),e,canvas) }
            return below
        case .push, .whipPan:
            let (dx,dy) = travel(t.direction,canvas)
            let moved = sum(a.map { shift($0,dx*e,dy*e,canvas) },b.map { shift($0,-dx*(1-e),-dy*(1-e),canvas) },canvas)
            guard t.kind == .whipPan else { return moved.composited(over:below) }
            let radius = 90*u*sin(.pi*p)
            guard radius > 1 else { return moved.composited(over:below) }
            let angle = atan2(dy,dx)
            let smeared = (covers(moved,canvas) ? moved.clampedToExtent() : moved)
                .applyingFilter("CIMotionBlur",parameters:[kCIInputRadiusKey:radius,kCIInputAngleKey:angle]).cropped(to:canvas)
            return smeared.composited(over:below)
        case .slide:
            let (dx,dy) = travel(t.direction,canvas)
            // The incoming picture covers the still outgoing one; alone, the outgoing slides away.
            let still = t.paired ? a : a.map { shift($0,dx*e,dy*e,canvas) }
            let arriving = b.map { shift($0,-dx*(1-e),-dy*(1-e),canvas) }
            var result = below
            if let still { result = still.cropped(to:canvas).composited(over:result) }
            if let arriving { result = arriving.cropped(to:canvas).composited(over:result) }
            return result
        case .zoom:
            let q = t.paired ? smoothstep(0.35,0.65,p) : e
            return gammaMix(over(a.map { scale($0,1+0.35*e) }),over(b.map { scale($0,1+0.35*(1-e)) }),q,canvas)
        case .wipe:
            // Constant speed, soft edge 6% of the width: the incoming picture shows behind the edge.
            return blend(over(a),over(b),wipeMask(t.direction,p,canvas))
        case .iris:
            let reach = hypot(canvas.width,canvas.height)/2, rim = canvas.height*0.04
            return blend(over(a),over(b),circle(radius:p*(reach+rim),rim:rim,canvas))
        case .pixelate:
            let size = max(1,2*(ceil(50*min(p,1-p))/50)*min(canvas.width,canvas.height)/20)
            let q = t.paired ? smoothstep(0.4,0.6,p) : p
            return gammaMix(over(a.map { pixellate($0,size,canvas) }),over(b.map { pixellate($0,size,canvas) }),q,canvas)
        }
    }

    // MARK: building blocks

    static func ease(_ p: Double) -> Double { p*p*(3-2*p) }
    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double { ease(min(1,max(0,(x-e0)/(e1-e0)))) }
    /// The direction pictures travel, in Core Image space (y up), by a full canvas.
    private static func travel(_ direction: TransitionDirection, _ canvas: CGRect) -> (CGFloat,CGFloat) {
        switch direction {
        case .left: (-canvas.width,0)
        case .right: (canvas.width,0)
        case .up: (0,canvas.height)
        case .down: (0,-canvas.height)
        }
    }
    /// The picture as it shows on the canvas, moved: cropped first, so a picture scaled to fill
    /// (wider than the canvas) meets the other one exactly at the seam instead of overlapping it.
    private static func shift(_ image: CIImage, _ dx: CGFloat, _ dy: CGFloat, _ canvas: CGRect) -> CIImage {
        image.cropped(to:canvas).transformed(by:CGAffineTransform(translationX:dx,y:dy))
    }
    private static func encode(_ image: CIImage) -> CIImage { image.applyingFilter("CILinearToSRGBToneCurve") }
    private static func decode(_ image: CIImage) -> CIImage { image.applyingFilter("CISRGBToneCurveToLinear") }
    /// A dissolve from x to y by w, blended in the encoded domain, cropped to the canvas.
    private static func gammaMix(_ x: CIImage, _ y: CIImage, _ w: Double, _ canvas: CGRect) -> CIImage {
        if w <= 0 { return x.cropped(to:canvas) }
        if w >= 1 { return y.cropped(to:canvas) }
        let mixed = encode(x.cropped(to:canvas)).applyingFilter("CIDissolveTransition",parameters:[kCIInputTargetImageKey:encode(y.cropped(to:canvas)),kCIInputTimeKey:w])
        return decode(mixed).cropped(to:canvas)
    }
    /// Toward black or white by k, in the encoded domain; alpha is kept, so a title dips in place.
    private static func dip(_ image: CIImage, _ k: Double, _ white: CGFloat) -> CIImage {
        let k = min(1,max(0,k))
        guard k > 0 else { return image }
        let scaled = encode(image).applyingFilter("CIColorMatrix",parameters:[
            "inputRVector":CIVector(x:1-k,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:1-k,z:0,w:0),
            "inputBVector":CIVector(x:0,y:0,z:1-k,w:0),"inputAVector":CIVector(x:0,y:0,z:0,w:1),
            "inputBiasVector":CIVector(x:white*k,y:white*k,z:white*k,w:0)])
        return decode(scaled).cropped(to:image.extent)
    }
    private static func covers(_ image: CIImage, _ canvas: CGRect) -> Bool { image.extent.insetBy(dx:-0.5,dy:-0.5).contains(canvas) }
    /// Clamped only for a picture that fills the canvas, so a picture-in-picture keeps soft edges
    /// while full frames do not darken at the border.
    private static func blur(_ image: CIImage, _ radius: Double, _ canvas: CGRect) -> CIImage {
        guard radius > 0.5 else { return image }
        let source = covers(image,canvas) ? image.clampedToExtent() : image
        return source.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:image.extent)
    }
    /// A and B side by side: added, not stacked, so the seam where two half-covered pixels meet is
    /// fully covered instead of three-quarters.
    private static func sum(_ a: CIImage?, _ b: CIImage?, _ canvas: CGRect) -> CIImage {
        switch (a,b) {
        case let (a?,b?): b.cropped(to:canvas).applyingFilter("CIAdditionCompositing",parameters:[kCIInputBackgroundImageKey:a.cropped(to:canvas)]).cropped(to:canvas)
        case let (a?,nil): a.cropped(to:canvas)
        case let (nil,b?): b.cropped(to:canvas)
        default: .empty()
        }
    }
    /// About the picture's own centre, so a picture-in-picture zooms in place, within its box.
    private static func scale(_ image: CIImage, _ factor: CGFloat) -> CIImage {
        let box = image.extent
        guard !box.isInfinite, !box.isEmpty else { return image }
        return image.transformed(by:CGAffineTransform(translationX:-box.midX,y:-box.midY)
            .concatenating(CGAffineTransform(scaleX:factor,y:factor))
            .concatenating(CGAffineTransform(translationX:box.midX,y:box.midY))).cropped(to:box)
    }
    private static func pixellate(_ image: CIImage, _ size: Double, _ canvas: CGRect) -> CIImage {
        guard size >= 2 else { return image }
        let source = covers(image,canvas) ? image.clampedToExtent() : image
        return source.applyingFilter("CIPixellate",parameters:[kCIInputScaleKey:size,kCIInputCenterKey:CIVector(x:0,y:0)]).cropped(to:image.extent)
    }
    /// y where the mask is opaque, x elsewhere (the mask's alpha, not its grey level).
    private static func blend(_ x: CIImage, _ y: CIImage, _ mask: CIImage) -> CIImage {
        y.applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:x,kCIInputMaskImageKey:mask])
    }
    /// The soft edge crosses the canvas the way the pictures travel: Wipe Left brings B in from
    /// the right, as FFmpeg's wipeleft does.
    private static func wipeMask(_ direction: TransitionDirection, _ p: Double, _ canvas: CGRect) -> CIImage {
        let clear = CIColor(red:0,green:0,blue:0,alpha:0), solid = CIColor(red:1,green:1,blue:1,alpha:1)
        let horizontal = direction == .left || direction == .right
        let span = horizontal ? canvas.width : canvas.height, soft = canvas.width*0.06
        // The edge's travelled distance along the axis; B is on the side it came from.
        let travelled = -soft/2+p*(span+soft)
        let edge: CGFloat, bAbove: Bool
        switch direction {
        case .left: edge = canvas.maxX-travelled; bAbove = true
        case .right: edge = canvas.minX+travelled; bAbove = false
        case .up: edge = canvas.minY+travelled; bAbove = false
        case .down: edge = canvas.maxY-travelled; bAbove = true
        }
        let p0 = horizontal ? CIVector(x:edge-soft/2,y:canvas.midY) : CIVector(x:canvas.midX,y:edge-soft/2)
        let p1 = horizontal ? CIVector(x:edge+soft/2,y:canvas.midY) : CIVector(x:canvas.midX,y:edge+soft/2)
        return CIFilter(name:"CILinearGradient",parameters:["inputPoint0":p0,"inputPoint1":p1,
                                                             "inputColor0":bAbove ? clear : solid,"inputColor1":bAbove ? solid : clear])!.outputImage!.cropped(to:canvas)
    }
    /// Opaque inside a centred circle with a soft rim, clear outside.
    private static func circle(radius: CGFloat, rim: CGFloat, _ canvas: CGRect) -> CIImage {
        CIFilter(name:"CIRadialGradient",parameters:[
            "inputCenter":CIVector(x:canvas.midX,y:canvas.midY),
            "inputRadius0":max(0,radius-rim),"inputRadius1":max(0.001,radius),
            "inputColor0":CIColor(red:1,green:1,blue:1,alpha:1),"inputColor1":CIColor(red:0,green:0,blue:0,alpha:0)
        ])!.outputImage!.cropped(to:canvas)
    }
}
