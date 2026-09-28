import Foundation
import CoreGraphics

/// Shared geometry for Core Image rendering and direct manipulation in the viewer.
/// Viewer points use a top-left origin; the render transform uses Core Image's bottom-left origin.
public struct VisualGeometry {
    public let sourceSize: CGSize
    public let canvasSize: CGSize
    public let style: ClipStyle
    public let isText: Bool

    public init(sourceSize: CGSize, canvasSize: CGSize, style: ClipStyle, isText: Bool = false) {
        self.sourceSize = sourceSize; self.canvasSize = canvasSize; self.style = style; self.isText = isText
    }
    public var renderTransform: CGAffineTransform {
        let fit = isText ? min(canvasSize.width,canvasSize.height) / 1080 : min(canvasSize.width/sourceSize.width,canvasSize.height/sourceSize.height)
        let factor = fit * style.scale
        return CGAffineTransform(translationX:-sourceSize.width/2,y:-sourceSize.height/2)
            .concatenating(CGAffineTransform(scaleX:factor,y:factor))
            .concatenating(CGAffineTransform(rotationAngle:-style.rotation * .pi/180))
            .concatenating(CGAffineTransform(translationX:canvasSize.width*(0.5+style.x),y:canvasSize.height*(0.5-style.y)))
    }
    public var center: CGPoint { CGPoint(x:canvasSize.width*(0.5+style.x),y:canvasSize.height*(0.5+style.y)) }
    /// Clockwise from the top-left of the unrotated source.
    public var corners: [CGPoint] {
        [CGPoint(x:0,y:sourceSize.height),CGPoint(x:sourceSize.width,y:sourceSize.height),
         CGPoint(x:sourceSize.width,y:0),CGPoint.zero].map {
            let p = $0.applying(renderTransform); return CGPoint(x:p.x,y:canvasSize.height-p.y)
        }
    }
    public func contains(_ point: CGPoint) -> Bool {
        let source = CGPoint(x:point.x,y:canvasSize.height-point.y).applying(renderTransform.inverted())
        return source.x >= 0 && source.x <= sourceSize.width && source.y >= 0 && source.y <= sourceSize.height
    }
    /// Within `tolerance` points of one of the four edges (the outline a user can grab).
    public func isNearOutline(_ p: CGPoint, tolerance: CGFloat = 6) -> Bool {
        let c = corners
        for i in 0..<4 {
            let a = c[i], b = c[(i+1)%4], dx = b.x-a.x, dy = b.y-a.y, length = dx*dx+dy*dy
            let t = length > 0 ? max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/length)) : 0
            if hypot(p.x-(a.x+t*dx),p.y-(a.y+t*dy)) <= tolerance { return true }
        }
        return false
    }
    /// The rotation handle: a knob `offset` points past the middle of the clip's top edge, in the
    /// clip's own up direction (it turns with the clip), and the edge point its stem starts from.
    /// With `area` (viewer space), a knob that would fall outside it — a full-frame clip turned
    /// upside down puts it over the controls below the viewer — goes past the bottom edge instead,
    /// or failing that, just inside the top edge.
    public func rotationHandle(offset: CGFloat = 26, within area: CGRect? = nil, margin: CGFloat = 12) -> (edge: CGPoint, knob: CGPoint) {
        let c = corners, angle = style.rotation * .pi/180                 // clockwise on screen, y down
        let up = CGPoint(x:sin(angle),y:-cos(angle))
        let top = CGPoint(x:(c[0].x+c[1].x)/2,y:(c[0].y+c[1].y)/2), bottom = CGPoint(x:(c[2].x+c[3].x)/2,y:(c[2].y+c[3].y)/2)
        let choices = [(top,CGPoint(x:top.x+up.x*offset,y:top.y+up.y*offset)),
                       (bottom,CGPoint(x:bottom.x-up.x*offset,y:bottom.y-up.y*offset)),
                       (top,CGPoint(x:top.x-up.x*offset,y:top.y-up.y*offset))]
        guard let area else { return choices[0] }
        let inside = area.insetBy(dx:margin,dy:margin)
        return choices.first { inside.contains($0.1) } ?? choices[2]
    }
    /// Turned about its centre by the angle the pointer has swept around it since `start`, kept
    /// in −180…180. With `step` (degrees) the angle goes in steps; otherwise, within `magnet`
    /// degrees of a right angle it settles on it. Nil with the pointer (or the start) on the
    /// centre, where there is no angle to read: the caller keeps what it has.
    public func rotated(from start: CGPoint, to point: CGPoint, step: Double? = nil, magnet: Double = 0) -> ClipStyle? {
        let c = center
        guard hypot(point.x-c.x,point.y-c.y) > 2, hypot(start.x-c.x,start.y-c.y) > 2 else { return nil }
        var swept = (atan2(point.y-c.y,point.x-c.x)-atan2(start.y-c.y,start.x-c.x))*180 / .pi
        if swept > 180 { swept -= 360 } else if swept < -180 { swept += 360 }
        var angle = style.rotation+swept
        if let step, step > 0 { angle = (angle/step).rounded()*step }
        else if magnet > 0, abs(angle-(angle/90).rounded()*90) <= magnet { angle = (angle/90).rounded()*90 }
        else { angle = (angle*100).rounded()/100 }                        // hundredths: no -24.000000000000036
        angle = angle.truncatingRemainder(dividingBy:360)
        if angle > 180 { angle -= 360 } else if angle <= -180 { angle += 360 }
        var result = style; result.rotation = angle
        return result
    }
    /// Centre alignment while moving: a centre within `threshold` points of one of `centers`
    /// across or down lands exactly on it (each axis on its own). Also returns the guides it
    /// lined up on: the x of a vertical line, the y of a horizontal one.
    public func aligned(to centers: [CGPoint], threshold: CGFloat) -> (style: ClipStyle, vertical: CGFloat?, horizontal: CGFloat?) {
        let c = center
        let x = centers.map(\.x).filter { abs($0-c.x) <= threshold }.min { abs($0-c.x) < abs($1-c.x) }
        let y = centers.map(\.y).filter { abs($0-c.y) <= threshold }.min { abs($0-c.y) < abs($1-c.y) }
        var result = style
        if let x { result.x = min(2,max(-2,x/canvasSize.width-0.5)) }
        if let y { result.y = min(2,max(-2,y/canvasSize.height-0.5)) }
        return (result,x,y)
    }
    public func moved(by delta: CGSize) -> ClipStyle {
        var result = style
        result.x = min(2,max(-2,style.x + delta.width/canvasSize.width))
        result.y = min(2,max(-2,style.y + delta.height/canvasSize.height))
        return result
    }
    /// Uniform scaling along the rotated diagonal. The opposite corner remains fixed.
    public func resized(corner: Int, to point: CGPoint) -> ClipStyle {
        guard corners.indices.contains(corner) else { return style }
        let anchor = corners[(corner+2)%4], handle = corners[corner]
        let dx = handle.x-anchor.x, dy = handle.y-anchor.y
        let lengthSquared = dx*dx+dy*dy
        guard lengthSquared > 0 else { return style }
        let ratio = ((point.x-anchor.x)*dx+(point.y-anchor.y)*dy)/lengthSquared
        var result = style
        result.scale = min(4,max(0.05,style.scale*ratio))
        let clampedRatio = result.scale/style.scale
        result.x = min(2,max(-2,(anchor.x+(center.x-anchor.x)*clampedRatio)/canvasSize.width-0.5))
        result.y = min(2,max(-2,(anchor.y+(center.y-anchor.y)*clampedRatio)/canvasSize.height-0.5))
        return result
    }
}
