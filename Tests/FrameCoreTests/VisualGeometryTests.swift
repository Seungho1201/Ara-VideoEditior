import XCTest
import CoreGraphics
@testable import FrameCore

final class VisualGeometryTests: XCTestCase {
    private let canvas = CGSize(width:960,height:540)
    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x,expected.x,accuracy:0.000001,file:file,line:line)
        XCTAssertEqual(actual.y,expected.y,accuracy:0.000001,file:file,line:line)
    }
    func testAspectFitBoundsAndHitTestingUseSourceNotWholeCanvas() {
        let landscape = VisualGeometry(sourceSize:.init(width:1920,height:1080),canvasSize:canvas,style:ClipStyle())
        assertPoint(landscape.corners[0],.zero)
        assertPoint(landscape.corners[2],.init(x:960,y:540))
        let portrait = VisualGeometry(sourceSize:.init(width:2160,height:3840),canvasSize:canvas,style:ClipStyle())
        assertPoint(portrait.corners[0],.init(x:328.125,y:0))
        assertPoint(portrait.corners[2],.init(x:631.875,y:540))
        XCTAssertTrue(portrait.contains(.init(x:480,y:270)))
        XCTAssertFalse(portrait.contains(.init(x:100,y:270)))
    }
    func testMovementIsNormalizedAndYMatchesRendering() {
        let geometry = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:ClipStyle())
        let moved = geometry.moved(by:.init(width:96,height:54))
        XCTAssertEqual(moved.x,0.1,accuracy:1e-12); XCTAssertEqual(moved.y,0.1,accuracy:1e-12)
        let result = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:moved)
        assertPoint(result.corners[0],.init(x:96,y:54))
        // The same top-left point in Core Image coordinates, reflected vertically.
        assertPoint(CGPoint(x:0,y:540).applying(result.renderTransform),.init(x:96,y:486))
    }
    func testRotatedResizeKeepsOppositeCornerAndAspectRatio() {
        for degrees in [-90.0,0,37,180] {
            var style = ClipStyle(); style.rotation = degrees; style.scale = 0.6; style.x = 0.1
            let geometry = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:style)
            for corner in 0..<4 {
                let anchor = geometry.corners[(corner+2)%4], handle = geometry.corners[corner]
                let target = CGPoint(x:anchor.x+(handle.x-anchor.x)*1.5,y:anchor.y+(handle.y-anchor.y)*1.5)
                let resized = geometry.resized(corner:corner,to:target)
                XCTAssertEqual(resized.scale,0.9,accuracy:1e-12)
                XCTAssertEqual(resized.rotation,degrees)
                let result = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:resized)
                assertPoint(result.corners[corner],target)
                assertPoint(result.corners[(corner+2)%4],anchor)
                XCTAssertTrue(result.contains(result.center))
            }
        }
    }
    func testResizeAndMoveClampToModelLimits() {
        let geometry = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:ClipStyle())
        XCTAssertEqual(geometry.resized(corner:2,to:.init(x:100_000,y:100_000)).scale,4)
        XCTAssertEqual(geometry.resized(corner:2,to:.init(x:-1000,y:-1000)).scale,0.05)
        let moved = geometry.moved(by:.init(width:100_000,height:-100_000))
        XCTAssertEqual(moved.x,2); XCTAssertEqual(moved.y,-2)
    }
    func testTextUses1080CanvasUnitsAndOutputResolutionDoesNotChangePlacement() {
        var style = ClipStyle(); style.x = -0.1; style.y = 0.2; style.scale = 1.7; style.rotation = 23
        let small = VisualGeometry(sourceSize:.init(width:400,height:100),canvasSize:canvas,style:style,isText:true)
        let large = VisualGeometry(sourceSize:.init(width:400,height:100),canvasSize:.init(width:3840,height:2160),style:style,isText:true)
        for (a,b) in zip(small.corners,large.corners) { assertPoint(b,.init(x:a.x*4,y:a.y*4)) }
    }
    func testTransformUndoPersistenceDoesNotChangeAudioOrTiming() throws {
        var project = Project()
        let media = MediaReference(name:"Source",path:"/video.mov",kind:.video,duration:.init(seconds:10),hasAudio:true)
        project.media = [media]
        let id = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
        let before = project
        let i = try XCTUnwrap(project.clips.firstIndex { $0.id == id })
        let geometry = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:project.clips[i].style)
        project.clips[i].style = geometry.resized(corner:2,to:.init(x:800,y:450))
        _ = try project.validated()
        XCTAssertEqual(project.clips[1],before.clips[1])
        XCTAssertEqual(project.clips[i].start,before.clips[i].start)
        XCTAssertEqual(project.clips[i].sourceStart,before.clips[i].sourceStart)
        var history = EditHistory(); history.record(before,name:"Transform")
        XCTAssertEqual(history.undo(project),before)
        XCTAssertEqual(history.redo(before),project)
        XCTAssertEqual(try ProjectFile.decode(ProjectFile.encode(project)),project)
    }
    func testOutlineHitIsABandAroundTheEdgesEvenWhenRotatedAndOffCanvas() {
        var style = ClipStyle(); style.rotation = 30; style.x = 0.8; style.scale = 1.2   // pushed well off the right edge
        let g = VisualGeometry(sourceSize:CGSize(width:400,height:300),canvasSize:CGSize(width:640,height:360),style:style)
        let c = g.corners
        let mid = CGPoint(x:(c[0].x+c[1].x)/2,y:(c[0].y+c[1].y)/2)           // middle of the top edge
        XCTAssertTrue(g.isNearOutline(mid))
        XCTAssertGreaterThan(mid.x, 0)
        // Five points straight out from that edge: on the band. Twenty: off it.
        let dx = c[1].x-c[0].x, dy = c[1].y-c[0].y, n = hypot(dx,dy)
        let normal = CGPoint(x:-dy/n,y:dx/n)
        XCTAssertTrue(g.isNearOutline(CGPoint(x:mid.x+normal.x*5,y:mid.y+normal.y*5)))
        XCTAssertFalse(g.isNearOutline(CGPoint(x:mid.x+normal.x*20,y:mid.y+normal.y*20)))
        // The centre of the clip is inside it but nowhere near its outline.
        let centre = CGPoint(x:(c[0].x+c[2].x)/2,y:(c[0].y+c[2].y)/2)
        XCTAssertTrue(g.contains(centre)); XCTAssertFalse(g.isNearOutline(centre))
        // Corners belong to the band too.
        XCTAssertTrue(g.isNearOutline(c[2]))
    }
    func testRotationHandleSitsPastTheTopEdgeAndTurnsWithTheClip() {
        for degrees in [0.0,90,-45,180] {
            var style = ClipStyle(); style.rotation = degrees; style.scale = 0.5; style.x = -0.1
            let g = VisualGeometry(sourceSize:CGSize(width:400,height:300),canvasSize:canvas,style:style)
            let (edge,knob) = g.rotationHandle(offset:26)
            let c = g.corners
            assertPoint(edge,CGPoint(x:(c[0].x+c[1].x)/2,y:(c[0].y+c[1].y)/2))
            XCTAssertEqual(hypot(knob.x-edge.x,knob.y-edge.y),26,accuracy:1e-9)
            // Straight out from the centre through the top edge, outside the clip.
            let centre = g.center
            let outward = CGPoint(x:edge.x-centre.x,y:edge.y-centre.y), toKnob = CGPoint(x:knob.x-edge.x,y:knob.y-edge.y)
            XCTAssertEqual(outward.x*toKnob.y-outward.y*toKnob.x,0,accuracy:1e-6)
            XCTAssertGreaterThan(outward.x*toKnob.x+outward.y*toKnob.y,0)
            XCTAssertFalse(g.contains(knob))
        }
        // Unturned, the knob is straight above; turned 90° clockwise, straight to the right.
        let upright = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:ClipStyle()).rotationHandle(offset:20)
        assertPoint(upright.knob,CGPoint(x:upright.edge.x,y:upright.edge.y-20))
        var turned = ClipStyle(); turned.rotation = 90
        let right = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:turned).rotationHandle(offset:20)
        assertPoint(right.knob,CGPoint(x:right.edge.x+20,y:right.edge.y))
    }
    func testDraggingTheHandleTurnsTheClipUnderThePointer() {
        var style = ClipStyle(); style.scale = 0.5; style.rotation = 10
        let g = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:style)
        let start = g.rotationHandle().knob, c = g.center, radius = hypot(start.x-c.x,start.y-c.y)
        func pointer(at screenDegrees: Double) -> CGPoint {                 // clockwise from straight up
            let a = screenDegrees * .pi/180
            return CGPoint(x:c.x+sin(a)*radius,y:c.y-cos(a)*radius)
        }
        // The knob follows the pointer round: the result's own knob points where the pointer is.
        for target in [40.0,100,-30,175,-170] {
            let turned = g.rotated(from:start,to:pointer(at:target))!
            XCTAssertEqual(turned.rotation,target,accuracy:1e-9)
            XCTAssertEqual(turned.scale,style.scale); XCTAssertEqual(turned.x,style.x); XCTAssertEqual(turned.y,style.y)
            let knob = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:turned).rotationHandle().knob
            let a = atan2(knob.x-c.x,-(knob.y-c.y))*180 / .pi
            XCTAssertEqual(a,target,accuracy:1e-6)
        }
        // Across ±180 the angle wraps instead of running past it.
        var nearly = style; nearly.rotation = 170
        let g2 = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:nearly)
        let s2 = g2.rotationHandle().knob
        let past = CGPoint(x:c.x+(s2.x-c.x)*cos(.pi/6)-(s2.y-c.y)*sin(.pi/6),y:c.y+(s2.x-c.x)*sin(.pi/6)+(s2.y-c.y)*cos(.pi/6))   // 30° further clockwise
        XCTAssertEqual(g2.rotated(from:s2,to:past)!.rotation,-160,accuracy:1e-9)
        // Shift steps, the right-angle magnet, and a pointer on the centre.
        XCTAssertEqual(g.rotated(from:start,to:pointer(at:37),step:15)!.rotation,30,accuracy:1e-9)
        XCTAssertEqual(g.rotated(from:start,to:pointer(at:38),step:15)!.rotation,45,accuracy:1e-9)
        XCTAssertEqual(g.rotated(from:start,to:pointer(at:88.5),magnet:2)!.rotation,90,accuracy:1e-9)
        XCTAssertEqual(g.rotated(from:start,to:pointer(at:87),magnet:2)!.rotation,87,accuracy:1e-9)
        XCTAssertEqual(g.rotated(from:start,to:pointer(at:-1.5),magnet:2)!.rotation,0,accuracy:1e-9)
        // Hundredths of a degree, never float noise.
        XCTAssertEqual(g.rotated(from:start,to:pointer(at:-24.000000001))!.rotation,-24)
        // On the centre there is no angle: nothing, so the caller keeps the angle it has.
        XCTAssertNil(g.rotated(from:start,to:c))
        XCTAssertNil(g.rotated(from:CGPoint(x:c.x+1,y:c.y),to:pointer(at:40)))
    }
    func testRotationHandleStaysInsideTheViewer() {
        let viewer = CGRect(origin:.zero,size:canvas)                     // the canvas fills the viewer
        // Room above: the usual place.
        var small = ClipStyle(); small.scale = 0.5
        let g = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:small)
        XCTAssertEqual(g.rotationHandle(within:viewer).knob,g.rotationHandle().knob)
        // Full frame turned upside down: its top is the canvas bottom, and past it are the
        // controls under the viewer. The knob goes past the other edge, then inside.
        for degrees in [180.0,0] {
            var full = ClipStyle(); full.rotation = degrees
            let f = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:full)
            let handle = f.rotationHandle(within:viewer)
            XCTAssertFalse(viewer.contains(f.rotationHandle().knob))
            XCTAssertTrue(viewer.insetBy(dx:12,dy:12).contains(handle.knob),"\(degrees)°")
        }
        // A clip turned 180°: with room below it in the viewer the knob stays past its own top
        // edge (below it on screen); with room only above, it goes past its bottom edge instead.
        var turned = ClipStyle(); turned.rotation = 180; turned.scale = 0.9
        let t = VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:turned), c = t.corners
        let tall = CGRect(x:0,y:-100,width:canvas.width,height:canvas.height+200)
        XCTAssertEqual(t.rotationHandle(within:tall).knob,t.rotationHandle().knob)
        let roomAbove = CGRect(x:0,y:-100,width:canvas.width,height:canvas.height+100)
        let knob = t.rotationHandle(within:roomAbove).knob
        let bottomMiddle = CGPoint(x:(c[2].x+c[3].x)/2,y:(c[2].y+c[3].y)/2)
        XCTAssertEqual(hypot(knob.x-bottomMiddle.x,knob.y-bottomMiddle.y),26,accuracy:1e-9)
        XCTAssertLessThan(knob.y,bottomMiddle.y)                            // above the clip on screen
        XCTAssertTrue(roomAbove.contains(knob))
    }
    func testMovingLinesTheCentreUpWithOtherCentres() {
        let centers = [CGPoint(x:480,y:270),CGPoint(x:200,y:100)]
        func near(_ x: CGFloat, _ y: CGFloat) -> VisualGeometry {
            var style = ClipStyle(); style.scale = 0.3
            style.x = x/canvas.width-0.5; style.y = y/canvas.height-0.5
            return VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:style)
        }
        // Across: within 5 pt of 480 lands on it; down, nothing near.
        var result = near(483.5,150).aligned(to:centers,threshold:5)
        XCTAssertEqual(result.vertical,480); XCTAssertNil(result.horizontal)
        XCTAssertEqual(VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:result.style).center.x,480,accuracy:1e-9)
        XCTAssertEqual(result.style.y,near(483.5,150).style.y,"the other axis is left alone")
        // Both at once, each to its nearest.
        result = near(201,103).aligned(to:centers,threshold:5)
        XCTAssertEqual(result.vertical,200); XCTAssertEqual(result.horizontal,100)
        assertPoint(VisualGeometry(sourceSize:canvas,canvasSize:canvas,style:result.style).center,CGPoint(x:200,y:100))
        // Farther than the threshold: untouched.
        result = near(330,190).aligned(to:centers,threshold:5)
        XCTAssertNil(result.vertical); XCTAssertNil(result.horizontal)
        XCTAssertEqual(result.style,near(330,190).style)
    }
}
