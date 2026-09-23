import XCTest
@testable import FrameCore

final class TrackTests: XCTestCase {
    private func project() -> (Project,MediaReference) {
        var p = Project()
        let media = MediaReference(name:"Source",path:"/fixture.mov",kind:.video,duration:.init(seconds:20),hasAudio:true)
        p.media = [media]
        return (p,media)
    }

    func testLaneNamesRoundTripAndRejectNonsense() throws {
        XCTAssertEqual(Lane(rawValue:"V3"),Lane(.video,3))
        XCTAssertEqual(Lane(rawValue:"A1"),.a1)
        for bad in ["","V","V0","A-1","X1","V100","v1"] { XCTAssertNil(Lane(rawValue:bad),bad) }
        let encoded = try JSONEncoder().encode([Lane(.video,3),.a2])
        XCTAssertEqual(String(data:encoded,encoding:.utf8),#"["V3","A2"]"#)
        XCTAssertEqual(try JSONDecoder().decode([Lane].self,from:encoded),[Lane(.video,3),.a2])
        XCTAssertThrowsError(try JSONDecoder().decode([Lane].self,from:Data(#"["Q7"]"#.utf8)))
        XCTAssertEqual(Lane(.video,3).paired,Lane(.audio,3))
    }

    func testDocumentsWithoutTrackCountsOpenWithTwoOfEach() throws {
        var (p,media) = project()
        _ = try Editing.add(mediaID:media.id,lane:.v2,at:.zero,to:&p)
        var json = try JSONSerialization.jsonObject(with:ProjectFile.encode(p)) as! [String:Any]
        json.removeValue(forKey:"videoTrackCount"); json.removeValue(forKey:"audioTrackCount")
        let legacy = try ProjectFile.decode(JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(legacy.videoTrackCount,2); XCTAssertEqual(legacy.audioTrackCount,2)
        XCTAssertEqual(legacy.clips.map(\.lane).sorted { $0.rawValue < $1.rawValue },[.a2,.v2])
        XCTAssertEqual(legacy.displayLanes,[.v2,.v1,.a1,.a2])
    }

    func testAddingTracksGrowsTheTimelineUpToTheLimit() throws {
        var (p,_) = project()
        XCTAssertEqual(try Editing.addTrack(.video,to:&p),Lane(.video,3))
        XCTAssertEqual(try Editing.addTrack(.audio,to:&p),Lane(.audio,3))
        XCTAssertEqual(p.displayLanes.map(\.rawValue),["V3","V2","V1","A1","A2","A3"])
        while p.videoTrackCount < Project.trackCounts.upperBound { try Editing.addTrack(.video,to:&p) }
        XCTAssertThrowsError(try Editing.addTrack(.video,to:&p))
        XCTAssertEqual(p.videoTrackCount,Project.trackCounts.upperBound)
        // Round trip keeps the counts.
        let reopened = try ProjectFile.decode(ProjectFile.encode(p))
        XCTAssertEqual(reopened.videoTrackCount,p.videoTrackCount); XCTAssertEqual(reopened.audioTrackCount,3)
    }

    func testClipsOnlyLandOnTracksThatExist() throws {
        var (p,media) = project()
        XCTAssertThrowsError(try Editing.add(mediaID:media.id,lane:Lane(.video,3),at:.zero,to:&p))
        var broken = p
        broken.clips = [Clip(name:"Title",kind:.text,lane:Lane(.video,5),start:.zero,duration:.init(seconds:1))]
        XCTAssertThrowsError(try broken.validated())
        broken.videoTrackCount = 99
        XCTAssertThrowsError(try broken.validated())
    }

    func testLinkedAudioFollowsItsVideoToTheSameNumberAddingTheTrack() throws {
        var (p,media) = project()
        try Editing.addTrack(.video,to:&p)                                    // V3, no A3 yet
        let id = try Editing.add(mediaID:media.id,lane:Lane(.video,3),at:.zero,to:&p)
        XCTAssertEqual(p.audioTrackCount,3)
        XCTAssertEqual(Set(p.group(for:id).map(\.lane)),[Lane(.video,3),Lane(.audio,3)])
        // Moving a linked pair up brings its audio along, adding the audio track it needs.
        try Editing.addTrack(.video,to:&p)                                    // V4
        try Editing.move(id,to:.init(seconds:1),lane:Lane(.video,4),in:&p)
        XCTAssertEqual(p.audioTrackCount,4)
        XCTAssertEqual(Set(p.group(for:id).map(\.lane)),[Lane(.video,4),Lane(.audio,4)])
    }

    func testTitlesGoAboveEveryClipTheyOverlap() throws {
        var (p,media) = project()
        _ = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&p)
        let plain = try Editing.addText(at:.init(seconds:2),to:&p)
        XCTAssertEqual(p.clips.first { $0.id == plain }?.lane,.v2)             // as before on a 2+2 timeline
        // A clip on V3 would cover a title on V2: the title goes above it, on a new V4.
        try Editing.addTrack(.video,to:&p)
        _ = try Editing.add(mediaID:media.id,lane:Lane(.video,3),at:.init(seconds:6),to:&p)
        let above = try Editing.addText(at:.init(seconds:7),to:&p)
        XCTAssertEqual(p.clips.first { $0.id == above }?.lane,Lane(.video,4))
        XCTAssertEqual(p.videoTrackCount,4)
        // Busy V2 with free space above: no overlap error any more.
        var (q,qm) = project()
        _ = try Editing.add(mediaID:qm.id,lane:.v2,at:.zero,to:&q)
        let busy = try Editing.addText(at:.init(seconds:1),to:&q)
        XCTAssertEqual(q.clips.first { $0.id == busy }?.lane,Lane(.video,3))
        // Nothing above the top track: refused rather than hidden.
        var (r,rm) = project()
        while r.videoTrackCount < Project.trackCounts.upperBound { try Editing.addTrack(.video,to:&r) }
        let top = Lane(.video,Project.trackCounts.upperBound)
        r.clips.append(Clip(mediaID:rm.id,name:rm.name,kind:.video,lane:top,start:.zero,duration:.init(seconds:10)))
        r = try r.validated()
        XCTAssertThrowsError(try Editing.addText(at:.init(seconds:1),to:&r))
    }
    func testPastingFromATrackThisTimelineLacksBringsTheTrack() throws {
        var (source,media) = project()
        try Editing.addTrack(.video,to:&source)
        let id = try Editing.add(mediaID:media.id,lane:Lane(.video,3),at:.zero,to:&source)
        let copied = try ClipClipboard(copying:id,from:source)
        var destination = Project(); destination.media = [media]
        _ = try Editing.paste(copied,at:.zero,into:&destination)
        XCTAssertEqual(destination.videoTrackCount,3); XCTAssertEqual(destination.audioTrackCount,3)
        XCTAssertTrue(destination.clips.contains { $0.lane == Lane(.video,3) })
    }
}
