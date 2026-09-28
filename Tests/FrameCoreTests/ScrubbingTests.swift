import XCTest
@testable import FrameCore

final class ScrubbingTests: XCTestCase {
    private func project(_ rate: FrameRate = .init(60)) -> Project {
        var result = Project(); result.frameRate = rate
        let frame = rate.frame.ticks
        result.clips = [
            Clip(name:"A",kind:.text,lane:.v1,start:.zero,duration:.init(ticks:100*frame)),
            Clip(name:"B",kind:.text,lane:.v1,start:.init(ticks:100*frame),duration:.init(ticks:100*frame))
        ]
        return result
    }

    func testFiveFrameCaptureIsInclusiveFromBothSidesAtEveryRate() {
        for rate in FrameRate.supported {
            let project = project(rate), frame = rate.frame.ticks, end = MediaTime(ticks:100*frame)
            for offset in -5...5 {
                XCTAssertEqual(project.scrubPosition(at:.init(ticks:end.ticks+Int64(offset)*frame)),
                               ScrubPosition(time:end,snappedEnd:end))
            }
            for offset in [-6,6] {
                let time = MediaTime(ticks:end.ticks+Int64(offset)*frame)
                XCTAssertEqual(project.scrubPosition(at:time),ScrubPosition(time:time))
            }
            // Rounding the pointer to a frame before testing would incorrectly capture these.
            for sign: Int64 in [-1,1] {
                let pointer = MediaTime(ticks:end.ticks+sign*(5*frame+1))
                XCTAssertNil(project.scrubPosition(at:pointer).snappedEnd)
            }
        }
    }

    func testLinkedEndsAreOneTargetAndEquidistantTracksResolveEarlier() {
        var project = project()
        let frame = project.frameRate.frame.ticks
        let link = UUID(); project.clips[0].linkID = link
        var audio = project.clips[0]; audio.id = UUID(); audio.kind = .audio; audio.lane = .a1
        project.clips.append(audio)
        project.clips.append(Clip(name:"Overlay",kind:.text,lane:.v2,start:.zero,duration:.init(ticks:108*frame)))
        XCTAssertEqual(project.scrubPosition(at:.init(ticks:104*frame)).snappedEnd,.init(ticks:100*frame))
        XCTAssertEqual(project.scrubPosition(at:.init(ticks:105*frame)).snappedEnd,.init(ticks:108*frame))
        let expected = project.scrubPosition(at:.init(ticks:104*frame))
        project.clips.reverse()
        XCTAssertEqual(project.scrubPosition(at:.init(ticks:104*frame)),expected)
    }

    func testOnlyEndsCaptureAndDisablingSnapAllowsEveryFrame() {
        var project = project()
        let frame = project.frameRate.frame.ticks
        project.clips[1].start = .init(ticks:130*frame) // gap before the next start
        XCTAssertNil(project.scrubPosition(at:.init(ticks:128*frame)).snappedEnd)
        let time = MediaTime(ticks:98*frame)
        XCTAssertEqual(project.scrubPosition(at:time,snapping:false),ScrubPosition(time:time))
        // Leaving the capture zone releases immediately; no positional hysteresis.
        XCTAssertEqual(project.scrubPosition(at:.init(ticks:106*frame)).time,.init(ticks:106*frame))
    }

    func testEmptyTimelineAndOutOfBoundsNavigationAreClampedWithoutFalseSnap() {
        XCTAssertEqual(Project().scrubPosition(at:.init(seconds:1)),ScrubPosition(time:.zero))
        let project = project()
        XCTAssertEqual(project.scrubPosition(at:.init(seconds:-1)),ScrubPosition(time:.zero))
        XCTAssertEqual(project.scrubPosition(at:.init(seconds:100)),ScrubPosition(time:project.duration))
        XCTAssertEqual(project.scrubPosition(at:project.duration),ScrubPosition(time:project.duration,snappedEnd:project.duration))
    }

    func testUsesEditedEndNotSourceEndAndDoesNotChangeDocument() throws {
        for rate in FrameRate.supported {
            var project = project(rate)
            let frame = rate.frame.ticks
            let id = project.clips[0].id
            try Editing.trim(id,leading:false,to:.init(ticks:80*frame),in:&project)
            try Editing.move(id,to:.init(ticks:10*frame),lane:.v2,in:&project)
            let before = project
            XCTAssertEqual(project.scrubPosition(at:.init(ticks:87*frame)).snappedEnd,.init(ticks:90*frame))
            XCTAssertEqual(project,before)
        }
    }

    func testCadenceThrottlesFramesButBoundaryHasPriorityAndDoesNotRepeat() {
        var cadence = ScrubFeedbackCadence()
        func position(_ frame: Int64) -> ScrubPosition { .init(time:.init(ticks:frame*10_000)) }
        XCTAssertEqual(cadence.cue(for:position(1),at:0),.frame)
        XCTAssertNil(cadence.cue(for:position(2),at:0.01))
        XCTAssertNil(cadence.cue(for:position(3),at:0.09))           // 0.08 s is no longer enough
        XCTAssertEqual(cadence.cue(for:position(4),at:0.12),.frame)
        let end = ScrubPosition(time:.init(ticks:1_000_000),snappedEnd:.init(ticks:1_000_000))
        XCTAssertEqual(cadence.cue(for:end,at:0.13),.clipEnd) // not lost to the frame throttle
        XCTAssertNil(cadence.cue(for:end,at:1)) // holding still never repeats
        XCTAssertEqual(cadence.cue(for:position(106),at:1.1),.frame)
        XCTAssertEqual(cadence.cue(for:end,at:1.11),.clipEnd) // a later re-entry
        XCTAssertNil(cadence.cue(for:position(106),at:1.12))
        XCTAssertNil(cadence.cue(for:end,at:1.13)) // edge jitter suppressed
    }

    func testSkimmingPulsesThirtyPercentLessOften() {
        // A fast skim: a new frame every 10 ms for a second.
        func pulses(interval: TimeInterval) -> Int {
            var last = -Double.infinity, count = 0
            for step in 0...100 { let t = Double(step)*0.01; if t-last >= interval-1e-9 { count += 1; last = t } }
            return count
        }
        var cadence = ScrubFeedbackCadence(), now = 0
        for step in 0...100 where cadence.cue(for:.init(time:.init(ticks:Int64(step)*20_000)),at:Double(step)*0.01) == .frame { now += 1 }
        let before = pulses(interval:0.08)
        XCTAssertEqual(before,13)
        XCTAssertLessThanOrEqual(Double(now),Double(before)*0.7+0.5,"about 30 % fewer pulses (\(now) against \(before))")
        XCTAssertGreaterThanOrEqual(now,8,"but still a steady feel")
    }

    func testSameFrameAndDisabledFeedbackAreSilentAndFreshGestureResets() {
        let position = ScrubPosition(time:.init(seconds:1))
        var cadence = ScrubFeedbackCadence()
        XCTAssertNil(cadence.cue(for:position,at:1,enabled:false))
        XCTAssertNil(cadence.cue(for:position,at:2))
        cadence = ScrubFeedbackCadence()
        XCTAssertEqual(cadence.cue(for:position,at:3),.frame)
        XCTAssertNil(cadence.cue(for:position,at:4))
    }
}
