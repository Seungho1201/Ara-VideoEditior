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
        let fit = isText ? canvasSize.height / 1080 : min(canvasSize.width/sourceSize.width,canvasSize.height/sourceSize.height)
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
