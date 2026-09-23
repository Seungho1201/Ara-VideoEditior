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
}
