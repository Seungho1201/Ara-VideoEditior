import XCTest
@testable import FrameCore

final class NavigationTests: XCTestCase {
    func testClipNavigationUsesEditedTimelineRangeInsteadOfSourceRange() throws {
        for rate in FrameRate.supported {
            var project = Project(); project.frameRate = rate
            let media = MediaReference(name:"Source",path:"/fixture.mov",kind:.video,duration:.init(seconds:20),hasAudio:true)
            project.media = [media]
            let id = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
            let frame = rate.frame.ticks
            try Editing.split(id,at:.init(ticks:frame*60),in:&project)
            let right = try XCTUnwrap(project.clips.first { $0.kind == .video && $0.start.ticks == frame*60 })
            try Editing.trim(right.id,leading:true,to:.init(ticks:frame*70),in:&project)
            try Editing.trim(right.id,leading:false,to:.init(ticks:frame*100),in:&project)
            try Editing.move(right.id,to:.init(ticks:frame*120),lane:.v2,in:&project)
            for clip in project.group(for:right.id) {
                XCTAssertEqual(clip.start.ticks,frame*120)
                XCTAssertEqual(clip.sourceStart.ticks,frame*70)
                XCTAssertEqual(clip.lastFrameTime(at:rate).ticks,frame*149)
                XCTAssertLessThan(clip.lastFrameTime(at:rate),clip.end)
            }
        }
    }

    func testSingleFrameClipHasSameFirstAndLastFrame() {
        for rate in FrameRate.supported {
            let clip = Clip(name:"One frame",kind:.text,lane:.v2,start:.init(ticks:rate.frame.ticks*17),duration:rate.frame)
            XCTAssertEqual(clip.lastFrameTime(at:rate),clip.start)
        }
    }

    func testSnapshotClampsToExistingFramesAndQuantizesFractionalRates() {
        XCTAssertNil(Project().snapshotTime(at:.zero))
        for rate in FrameRate.supported {
            var project = Project(); project.frameRate = rate
            let frame = rate.frame.ticks
            project.clips = [Clip(name:"Text",kind:.text,lane:.v2,start:.zero,duration:.init(ticks:frame*31))]
            XCTAssertEqual(project.snapshotTime(at:.init(seconds:-10)),.zero)
            XCTAssertEqual(project.snapshotTime(at:.init(ticks:frame*12+frame/3)),.init(ticks:frame*12))
            XCTAssertEqual(project.snapshotTime(at:project.duration),.init(ticks:frame*30))
            XCTAssertEqual(project.snapshotTime(at:.init(seconds:999)),.init(ticks:frame*30))
        }
    }
}
