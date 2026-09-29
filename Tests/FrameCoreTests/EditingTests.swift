import XCTest
@testable import FrameCore

final class EditingTests: XCTestCase {
    func fixture(rate:FrameRate = .init(30)) throws -> (Project,UUID) {
        var p = Project(); p.frameRate = rate
        let media = MediaReference(name:"Source",path:"/fixture.mov",kind:.video,duration:.init(seconds:20),hasAudio:true)
        p.media = [media]
        let id = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&p)
        return (p,id)
    }
    func testFractionalFrameClockHasNoAccumulatedDrift() {
        for rate in FrameRate.supported {
            let count: Int64 = 1_000_000
            let time = MediaTime(ticks:rate.frame.ticks*count)
            XCTAssertEqual(time.seconds,Double(count)*Double(rate.denominator)/Double(rate.numerator),accuracy:0.000001)
            XCTAssertEqual(rate.quantize(time),time)
        }
    }
    func testLinkedSplitTrimMovePreservesSourceAndSync() throws {
        var (p,id) = try fixture()
        try Editing.split(id,at:.init(seconds:8),in:&p)
        XCTAssertEqual(p.clips.count,4)
        let right = try XCTUnwrap(p.clips.first { $0.kind == .video && $0.start == .init(seconds:8) })
        XCTAssertEqual(right.sourceStart,.init(seconds:8))
        XCTAssertNotEqual(right.linkID,p.clips.first { $0.id == id }?.linkID)
        try Editing.trim(right.id,leading:true,to:.init(seconds:10),in:&p)
        try Editing.trim(right.id,leading:false,to:.init(seconds:17),in:&p)
        try Editing.move(right.id,to:.init(seconds:12),lane:.v2,in:&p)
        let group = p.group(for:right.id)
        XCTAssertEqual(Set(group.map(\.start)),[.init(seconds:12)])
        XCTAssertEqual(Set(group.map(\.sourceStart)),[.init(seconds:10)])
        XCTAssertEqual(Set(group.map(\.duration)),[.init(seconds:7)])
        XCTAssertEqual(Set(group.map(\.lane)),[.v2,.a2])
        XCTAssertNoThrow(try p.validated())
    }
    func testRejectedEditIsAtomic() throws {
        var (p,id) = try fixture(); let original = p
        XCTAssertThrowsError(try Editing.trim(id,leading:true,to:.init(seconds:-1),in:&p))
        XCTAssertEqual(p,original)
        XCTAssertThrowsError(try Editing.add(mediaID:p.media[0].id,lane:.v1,at:.init(seconds:1),to:&p))
        XCTAssertEqual(p,original)
        XCTAssertThrowsError(try Editing.split(id,at:.zero,in:&p))
    }
    func testHistoryAndPersistenceRoundTrip() throws {
        var (p,id) = try fixture(rate:.init(30000,1001)); let original = p
        p.media[0].bookmark = Data([1,2,3]); let bookmarkVersion = p
        var history = EditHistory(); history.record(p,name:"Split")
        try Editing.split(id,at:p.frameRate.quantize(.init(seconds:5)),in:&p)
        let split = p
        p = try XCTUnwrap(history.undo(p)); XCTAssertEqual(p,bookmarkVersion)
        p = try XCTUnwrap(history.redo(p)); XCTAssertEqual(p,split)
        let encoded = try ProjectFile.encode(p)
        XCTAssertEqual(try ProjectFile.decode(encoded),p)
        XCTAssertEqual(try ProjectFile.decode(encoded).media[0].bookmark,Data([1,2,3]))
        XCTAssertEqual(original.frameRate,p.frameRate)
    }
    func testSnapIncludesEndAndExcludesLinkedSelf() throws {
        let (p,id) = try fixture()
        let snapped = Editing.snapped(.init(seconds:3.04),excluding:id,playhead:.init(seconds:3),threshold:.init(seconds:0.1),project:p)
        XCTAssertEqual(snapped,.init(seconds:3))
        let edge = Editing.snapped(.init(seconds:18.95),duration:.init(seconds:1),playhead:.zero,threshold:.init(seconds:0.1),project:p)
        XCTAssertEqual(edge,.init(seconds:19))
    }
    func testImageDurationAtFractionalRateAndVersionValidation() throws {
        var p = Project(); p.frameRate = .init(24000,1001)
        let image = MediaReference(name:"Still",path:"/still.png",kind:.image,duration:.init(seconds:5))
        p.media = [image]
        _ = try Editing.add(mediaID:image.id,lane:.v1,at:.zero,to:&p)
        XCTAssertNoThrow(try p.validated())
        p.version = 999
        XCTAssertThrowsError(try ProjectFile.encode(p))
    }
    func testDeleteRemovesOnlyLinkedPair() throws {
        var (p,id) = try fixture()
        let title = try Editing.addText(at:.zero,to:&p)
        Editing.delete(id,from:&p)
        XCTAssertEqual(p.clips.map(\.id),[title])
    }
    /// Two linked A/V clips on V1/A1 with an empty second between them.
    func gapFixture() throws -> (Project,UUID) {
        var p = Project()
        let media = MediaReference(name:"Source",path:"/fixture.mov",kind:.video,duration:.init(seconds:20),hasAudio:true)
        p.media = [media]
        let first = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&p)
        try Editing.trim(first,leading:false,to:.init(seconds:4),in:&p)
        let second = try Editing.add(mediaID:media.id,lane:.v1,at:.init(seconds:5),to:&p)
        try Editing.trim(second,leading:false,to:.init(seconds:9),in:&p)
        return (p,second)
    }
    func testGapDetectionBoundsAndTrailingSpace() throws {
        let (p,_) = try gapFixture()
        let gap = try XCTUnwrap(Editing.gap(on:.v1,at:.init(seconds:4.5),in:p))
        XCTAssertEqual(gap.start,.init(seconds:4))
        XCTAssertEqual(gap.end,.init(seconds:5))
        XCTAssertEqual(gap.duration,.init(seconds:1))
        // Inside a clip is not a gap, and neither is space past the last clip.
        XCTAssertNil(Editing.gap(on:.v1,at:.init(seconds:2),in:p))
        XCTAssertNil(Editing.gap(on:.v1,at:.init(seconds:30),in:p))
        // A lane with no clips at all has no closable gap.
        XCTAssertNil(Editing.gap(on:.v2,at:.init(seconds:4.5),in:p))
        // Leading space before the first clip is a gap starting at zero, and closes to the head.
        var late = Project()
        let media = MediaReference(name:"Source",path:"/fixture.mov",kind:.video,duration:.init(seconds:20),hasAudio:true)
        late.media = [media]
        let only = try Editing.add(mediaID:media.id,lane:.v1,at:.init(seconds:2),to:&late)
        let leading = try XCTUnwrap(Editing.gap(on:.v1,at:.init(seconds:1),in:late))
        XCTAssertEqual(leading.start,.zero)
        XCTAssertEqual(leading.end,.init(seconds:2))
        try Editing.closeGap(leading,in:&late)
        XCTAssertEqual(Set(late.group(for:only).map(\.start)),[.zero])
    }
    func testCloseGapRipplesLaneAndLinkedAudio() throws {
        var (p,second) = try gapFixture()
        let gap = try XCTUnwrap(Editing.gap(on:.v1,at:.init(seconds:4.5),in:p))
        try Editing.closeGap(gap,in:&p)
        let group = p.group(for:second)
        XCTAssertEqual(Set(group.map(\.start)),[.init(seconds:4)])          // butts against the first clip
        XCTAssertEqual(Set(group.map(\.lane)),[.v1,.a1])                    // linked audio came along
        XCTAssertEqual(Set(group.map(\.sourceStart)),[.zero])               // source range untouched
        XCTAssertEqual(Set(group.map(\.duration)),[.init(seconds:4)])
        XCTAssertNil(Editing.gap(on:.v1,at:.init(seconds:4.5),in:p))
        XCTAssertNoThrow(try p.validated())
    }
    func testCloseGapIsAtomicAndRefusesTrailingSpace() throws {
        var (p,_) = try gapFixture(); let original = p
        // Nothing after the gap to close up against.
        XCTAssertThrowsError(try Editing.closeGap(TimelineGap(lane:.v1,start:.init(seconds:9),end:.init(seconds:12)),in:&p))
        XCTAssertEqual(p,original)
        // An unlinked A1 clip sitting exactly where the linked audio would ripple into:
        // the whole close must fail and leave the document untouched.
        var blocked = p
        let audio = MediaReference(name:"Tone",path:"/tone.wav",kind:.audio,duration:.init(seconds:1),hasAudio:true)
        blocked.media.append(audio)
        _ = try Editing.add(mediaID:audio.id,lane:.a1,at:.init(seconds:4),to:&blocked)
        let snapshot = blocked
        let gap = try XCTUnwrap(Editing.gap(on:.v1,at:.init(seconds:4.5),in:blocked))
        XCTAssertThrowsError(try Editing.closeGap(gap,in:&blocked))
        XCTAssertEqual(blocked,snapshot)
    }
    func testSpeedRetimesTimelineLengthAndKeepsSourceContent() throws {
        var (p,id) = try fixture()                                   // 20s source, 1x, whole clip on V1+A1
        let source = try XCTUnwrap(p.clips.first { $0.id == id }).sourceLength
        XCTAssertEqual(source,.init(seconds:20))
        try Editing.setSpeed(id,to:2,in:&p)
        let group = p.group(for:id)
        XCTAssertEqual(Set(group.map(\.speed)),[2])                  // linked audio retimed too
        XCTAssertEqual(Set(group.map(\.duration)),[.init(seconds:10)])
        XCTAssertEqual(Set(group.map(\.sourceLength)),[.init(seconds:20)])  // same source content
        XCTAssertEqual(Set(group.map(\.sourceStart)),[.zero])
        XCTAssertNoThrow(try p.validated())
        // Going back to 1x restores the original timeline length exactly.
        try Editing.setSpeed(id,to:1,in:&p)
        XCTAssertEqual(Set(p.group(for:id).map(\.duration)),[.init(seconds:20)])
    }
    func testSplitAndLeadingTrimConsumeSourceAtClipSpeed() throws {
        var (p,id) = try fixture()
        try Editing.setSpeed(id,to:2,in:&p)                          // 10s on the timeline, 20s of source
        try Editing.split(id,at:.init(seconds:4),in:&p)
        let right = try XCTUnwrap(p.clips.first { $0.kind == .video && $0.start == .init(seconds:4) })
        XCTAssertEqual(right.sourceStart,.init(seconds:8))           // 4s of timeline at 2x = 8s of source
        XCTAssertEqual(right.duration,.init(seconds:6))
        XCTAssertEqual(right.speed,2)
        XCTAssertEqual(right.sourceLength,.init(seconds:12))
        try Editing.trim(right.id,leading:true,to:.init(seconds:5),in:&p)
        let trimmed = try XCTUnwrap(p.clips.first { $0.id == right.id })
        XCTAssertEqual(trimmed.sourceStart,.init(seconds:10))        // another 1s of timeline = 2s of source
        XCTAssertEqual(trimmed.duration,.init(seconds:5))
        XCTAssertEqual(Set(p.group(for:right.id).map(\.sourceStart)),[.init(seconds:10)])
        XCTAssertNoThrow(try p.validated())
    }
    func testSpeedIsBoundedAndRefusedForTextAndOverlongSource() throws {
        var (p,id) = try fixture(); let original = p
        XCTAssertThrowsError(try Editing.setSpeed(id,to:0.05,in:&p))  // below 0.1x
        XCTAssertThrowsError(try Editing.setSpeed(id,to:10.5,in:&p))  // above 10x
        for speed in [5.0,10.0,2.37] { var copy = p; XCTAssertNoThrow(try Editing.setSpeed(id,to:speed,in:&copy),"\(speed)x") }
        XCTAssertEqual(p,original)
        let title = try Editing.addText(at:.init(seconds:25),to:&p)
        XCTAssertThrowsError(try Editing.setSpeed(title,to:2,in:&p))  // text has no source to retime
        // Slowing down must not read past the end of the asset.
        var slow = original
        try Editing.setSpeed(id,to:0.5,in:&slow)
        let clip = try XCTUnwrap(slow.clips.first { $0.id == id })
        XCTAssertEqual(clip.duration,.init(seconds:40))
        XCTAssertLessThanOrEqual((clip.sourceStart+clip.sourceLength).ticks,MediaTime(seconds:20).ticks)
        XCTAssertNoThrow(try slow.validated())
    }
    func testDocumentsSavedBeforeSpeedStillLoadAtOneX() throws {
        var (p,id) = try fixture()
        try Editing.setSpeed(id,to:2,in:&p)
        // Strip every "speed" key, exactly as a pre-retime document would look on disk.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try ProjectFile.encode(p)) as? [String:Any])
        var clips = try XCTUnwrap(json["clips"] as? [[String:Any]])
        for i in clips.indices { clips[i].removeValue(forKey:"speed"); clips[i]["duration"] = ["ticks":MediaTime(seconds:20).ticks] }
        json["clips"] = clips
        let legacy = try JSONSerialization.data(withJSONObject:json)
        let loaded = try ProjectFile.decode(legacy)
        XCTAssertEqual(Set(loaded.clips.map(\.speed)),[1])
        XCTAssertEqual(Set(loaded.clips.map(\.sourceLength)),[.init(seconds:20)])
    }
    /// A retimed clip whose tail sits flush against the end of its source used to fail to split:
    /// round(L*speed) + round(R*speed) can exceed round((L+R)*speed) by a tick.
    func testSplitOfRetimedClipFlushWithSourceEndSucceeds() throws {
        // 24000/1001 fps: a frame is 25025 ticks, so duration*speed is not an integer and the
        // halves can each round up. 32 frames at 1.519x consumes 1_216_415 ticks, but splitting
        // in the middle head-anchored would consume 608_208 + 608_208 = 1_216_416 — one tick more.
        var p = Project(); p.frameRate = .init(24000,1001)
        let media = MediaReference(name:"Source",path:"/fixture.mov",kind:.video,duration:.init(ticks:12_000_000),hasAudio:false)
        p.media = [media]
        var clip = Clip(mediaID:media.id,name:"Source",kind:.video,lane:.v1,start:.zero,
                        sourceStart:.init(ticks:10_783_585),duration:.init(ticks:25_025*32),speed:1.519)
        clip.id = UUID(); p.clips = [clip]
        let sourceEnd = clip.sourceStart + clip.sourceLength
        XCTAssertEqual(sourceEnd,.init(ticks:12_000_000))       // the clip ends flush with its source
        XCTAssertNoThrow(try p.validated())
        try Editing.split(clip.id,at:.init(ticks:25_025*16),in:&p)
        let right = try XCTUnwrap(p.clips.first { $0.start == .init(ticks:25_025*16) })
        // Both halves must still end exactly where the original ended — no extra tick.
        XCTAssertEqual(right.sourceStart + right.sourceLength,sourceEnd)
        XCTAssertNoThrow(try p.validated())
    }
    /// Dragging the speed slider out and back must restore the clip, not ratchet it down.
    func testInteractiveSpeedDragIsIdempotentAgainstItsBase() throws {
        var (p,id) = try fixture(); let base = p
        let originalDuration = try XCTUnwrap(p.clips.first { $0.id == id }).duration
        // 600 samples out to 4x and back, every one resolved against the drag's starting snapshot.
        for step in 0...300 { try Editing.setSpeed(id,to:1 + 3 * Double(step)/300,in:&p,basedOn:base) }
        for step in 0...300 { try Editing.setSpeed(id,to:4 - 3 * Double(step)/300,in:&p,basedOn:base) }
        XCTAssertEqual(try XCTUnwrap(p.clips.first { $0.id == id }).speed,1)
        XCTAssertEqual(try XCTUnwrap(p.clips.first { $0.id == id }).duration,originalDuration)
        XCTAssertEqual(p,base)
        // Without an anchor each step starts from the source range the clip was given (not the
        // whole frames the previous speed left), so the same sweep loses nothing either.
        var stepped = base
        for step in 0...300 { try Editing.setSpeed(id,to:1 + 3 * Double(step)/300,in:&stepped) }
        for step in 0...300 { try Editing.setSpeed(id,to:4 - 3 * Double(step)/300,in:&stepped) }
        XCTAssertEqual(try XCTUnwrap(stepped.clips.first { $0.id == id }).duration,originalDuration)
        XCTAssertEqual(stepped,base)
    }
    /// A speed and then 1x again, from the menu or a typed value rather than Undo, gives back the
    /// clip's own frames: each speed starts from the source range the clip was given, never from
    /// the whole frames the previous speed left of it, and never reads past its out point.
    func testSpeedRoundTripsKeepTheSourceRangeAtManyLengthsAndSpeeds() throws {
        for rate in [FrameRate(30),FrameRate(24000,1001),FrameRate(60)] {
            for frames in stride(from:3,through:300,by:7) {
                for speed in [0.25,0.5,0.75,1.23,1.5,2,2.5,3,4,5,7.3,10] {
                    var (p,id) = try fixture(rate:rate)
                    try Editing.trim(id,leading:false,to:MediaTime(ticks:rate.frame.ticks*Int64(frames)),in:&p)
                    let before = p, length = try XCTUnwrap(p.clip(id)).sourceLength
                    do { try Editing.setSpeed(id,to:speed,in:&p) }
                    catch { XCTAssertLessThan(Double(frames),speed,"\(frames) frames at \(speed)x is at least a frame"); XCTAssertEqual(p,before); continue }
                    let retimed = try XCTUnwrap(p.clip(id))
                    XCTAssertLessThanOrEqual(retimed.sourceLength,length,"\(frames) frames at \(speed)x reads past the out point")
                    XCTAssertEqual(Set(p.group(for:id).map(\.duration)),[retimed.duration])
                    try Editing.setSpeed(id,to:1.5,in:&p)                          // another speed on the way back
                    try Editing.setSpeed(id,to:1,in:&p)
                    XCTAssertEqual(p,before,"\(frames) frames → \(speed)x → 1.5x → 1x at \(rate.label) fps")
                }
            }
        }
    }
    func testASpeedThatLeavesLessThanAFrameIsRefused() throws {
        var (p,id) = try fixture()
        try Editing.trim(id,leading:false,to:.init(ticks:p.frameRate.frame.ticks*3),in:&p)
        let before = p
        XCTAssertThrowsError(try Editing.setSpeed(id,to:10,in:&p)) { XCTAssertTrue(($0 as? EditError)?.message.contains("less than one frame") == true,"\($0)") }
        XCTAssertEqual(p,before)
        try Editing.setSpeed(id,to:3,in:&p)                                     // exactly one frame
        XCTAssertEqual(p.clip(id)?.duration,p.frameRate.frame)
        XCTAssertEqual(p.clip(id)?.sourceLength,.init(ticks:p.frameRate.frame.ticks*3))
    }
    /// The slider stops at the fastest speed that leaves a frame, as it stops against the next
    /// clip, rather than failing on every sample past it; dragging back restores the clip.
    func testALiveDragStopsAtTheFastestSpeedThatLeavesAFrame() throws {
        for rate in [FrameRate(30),FrameRate(24000,1001)] {
            var (p,id) = try fixture(rate:rate)
            try Editing.trim(id,leading:false,to:.init(ticks:rate.frame.ticks*3),in:&p)
            let base = p
            for speed in [2.0,3.5,7,10] { try Editing.setSpeed(id,to:speed,in:&p,basedOn:base) }
            let fastest = try XCTUnwrap(p.clip(id))
            XCTAssertEqual(fastest.speed,3); XCTAssertEqual(fastest.duration,rate.frame)
            XCTAssertEqual(fastest.sourceLength,.init(ticks:rate.frame.ticks*3),"no frame past the out point")
            for speed in [5.0,2,1] { try Editing.setSpeed(id,to:speed,in:&p,basedOn:base) }
            XCTAssertEqual(p,base)
        }
    }
    /// A whole clip that ends a little past its source after a frame rate change keeps that end
    /// through a slow speed that allows less (and is cut to fit meanwhile) and back.
    func testASlowSpeedOnAClipEndingPastItsSourceComesBackWhole() throws {
        var p = Project()
        let media = MediaReference(name:"Six",path:"/six.mov",kind:.video,duration:.init(seconds:6),hasAudio:true)
        p.media = [media]
        let id = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&p)
        try Editing.setVideoSettings(aspectRatio:.landscape,frameRate:.init(30000,1001),in:&p)
        let converted = p, clip = try XCTUnwrap(p.clip(id))
        XCTAssertGreaterThan(clip.sourceLength,media.duration)                     // 180 frames of 29.97: 6.006 s
        try Editing.setSpeed(id,to:0.1,in:&p)
        let slow = try XCTUnwrap(p.clip(id))
        XCTAssertLessThan((slow.sourceStart+slow.sourceLength-media.duration).ticks,p.frameRate.frame.scaled(by:0.1).ticks)
        XCTAssertEqual(slow.duration,.init(ticks:p.frameRate.frame.ticks*1799))    // a frame short of 1800 to fit
        try Editing.setSpeed(id,to:1,in:&p)
        XCTAssertEqual(p,converted)
    }
    /// Edits that give a retimed clip a new source range forget the one it was given, and a
    /// remembered length that no longer describes the clip is not used.
    func testTrimSplitAndStaleLengthsStartFromTheCurrentRange() throws {
        var (p,id) = try fixture()
        try Editing.trim(id,leading:false,to:.init(seconds:5),in:&p)                // 150 frames
        try Editing.setSpeed(id,to:4,in:&p)                                        // 37 frames, 148 of source
        XCTAssertEqual(p.clip(id)?.retimedSourceLength,.init(seconds:5))
        XCTAssertEqual(try ProjectFile.decode(ProjectFile.encode(p)),p)             // saved with the document
        var trimmed = p
        try Editing.trim(id,leading:false,to:p.clip(id)!.end-p.frameRate.frame,in:&trimmed)
        XCTAssertEqual(Set(trimmed.group(for:id).map(\.retimedSourceLength)),[nil])
        try Editing.setSpeed(id,to:1,in:&trimmed)
        XCTAssertEqual(trimmed.clip(id)?.duration,.init(ticks:p.frameRate.frame.ticks*144))
        var split = p
        try Editing.split(id,at:.init(ticks:p.frameRate.frame.ticks*20),in:&split)
        XCTAssertEqual(Set(split.clips.map(\.retimedSourceLength)),[nil])
        var stale = p
        for i in stale.clips.indices { stale.clips[i].retimedSourceLength = .init(seconds:9) }
        try Editing.setSpeed(id,to:1,in:&stale)
        XCTAssertEqual(stale.clip(id)?.duration,.init(ticks:p.frameRate.frame.ticks*148))
        // Documents without the remembered length (and older Ara versions) are unaffected.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with:ProjectFile.encode(p)) as? [String:Any])
        json["clips"] = try XCTUnwrap(json["clips"] as? [[String:Any]]).map { var clip = $0; clip.removeValue(forKey:"retimedSourceLength"); return clip }
        XCTAssertEqual(Set(try ProjectFile.decode(JSONSerialization.data(withJSONObject:json)).clips.map(\.retimedSourceLength)),[nil])
    }
    /// A trim stops at its source's end, also for a source that is not a whole number of frames
    /// long (10.01 s is 300 frames and a third at 30 fps): the clip is added as 300 frames, and its
    /// end handle goes no further, at any speed. Only a frame rate change ends a clip past its
    /// source (holding its last frame): a trim can shorten such a clip, but lengthens it no more.
    func testATrimStopsAtTheSourcesEndWhenItIsNotAWholeNumberOfFrames() throws {
        for (seconds,speed) in [(10.01,1.0),(10.021,1.0),(10.0,1.0),(10.01,10.0),(10.01,0.5)] {
            var p = Project()
            let media = MediaReference(name:"Phone",path:"/phone.mov",kind:.video,duration:.init(seconds:seconds),hasAudio:true)
            p.media = [media]
            let id = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&p)
            if speed != 1 { try Editing.setSpeed(id,to:speed,in:&p) }
            let clip = try XCTUnwrap(p.clip(id)), before = p
            XCTAssertThrowsError(try Editing.trim(id,leading:false,to:clip.end+p.frameRate.frame,in:&p),"\(seconds) s at \(speed)x") {
                XCTAssertEqual($0.localizedDescription,"Clip exceeds its source duration.")
            }
            XCTAssertEqual(p,before)
            // Shorter and back is fine.
            try Editing.trim(id,leading:false,to:clip.end-p.frameRate.frame,in:&p)
            try Editing.trim(id,leading:false,to:clip.end,in:&p)
            XCTAssertEqual(p.clip(id)?.end,clip.end)
        }
        var p = Project()
        let six = MediaReference(name:"Six",path:"/six.mov",kind:.video,duration:.init(seconds:6),hasAudio:true)
        p.media = [six]
        let id = try Editing.add(mediaID:six.id,lane:.v1,at:.zero,to:&p)
        try Editing.setVideoSettings(aspectRatio:.landscape,frameRate:.init(30000,1001),in:&p)
        let held = try XCTUnwrap(p.clip(id))
        XCTAssertGreaterThan(held.sourceStart+held.sourceLength,six.duration)          // 180 frames of 29.97: 6.006 s
        XCTAssertThrowsError(try Editing.trim(id,leading:false,to:held.end+p.frameRate.frame,in:&p))
        try Editing.trim(id,leading:false,to:held.end-p.frameRate.frame,in:&p)
        XCTAssertThrowsError(try Editing.trim(id,leading:false,to:held.end,in:&p),"not back past the source")
    }
    func testSpeedIsSnappedSoOneXStaysExactlyOneX() throws {
        var (p,id) = try fixture()
        try Editing.setSpeed(id,to:1.0000000000000002,in:&p)
        let clip = try XCTUnwrap(p.clips.first { $0.id == id })
        XCTAssertEqual(clip.speed,1)                       // exact, so every `speed == 1` fast path holds
        XCTAssertEqual(clip.sourceLength,clip.duration)
    }
    /// Leading trim in and back out must land on the original source in-point at any speed.
    func testLeadingTrimRoundTripRestoresSourceStartAtAnySpeed() throws {
        for speed in [0.25, 0.5, 1.0, 1.75, 2.0, 3.3, 4.0] {
            var (p,id) = try fixture()
            try Editing.setSpeed(id,to:speed,in:&p)
            let before = try XCTUnwrap(p.clips.first { $0.id == id })
            let inward = before.start + .init(seconds:1)
            try Editing.trim(id,leading:true,to:inward,in:&p)
            try Editing.trim(id,leading:true,to:before.start,in:&p)
            let after = try XCTUnwrap(p.clips.first { $0.id == id })
            XCTAssertEqual(after.sourceStart,before.sourceStart,"speed \(speed)")
            XCTAssertEqual(after.duration,before.duration,"speed \(speed)")
        }
    }
    func testMalformedProjectTimesAndPropertiesAreRejected() throws {
        let (original,_) = try fixture()
        let fields: [WritableKeyPath<Clip,MediaTime>] = [\.start, \.sourceStart, \.duration]
        for field in fields {
            var p = original
            p.clips[0][keyPath:field] = MediaTime(ticks:Int64.max)
            let bytes = try JSONEncoder().encode(p)
            XCTAssertThrowsError(try ProjectFile.decode(bytes))
        }
        var p = original; p.clips[0].style.x = 1e100
        XCTAssertThrowsError(try p.validated())
        p = original; p.clips[0].style.red = -1
        XCTAssertThrowsError(try p.validated())
    }
}
