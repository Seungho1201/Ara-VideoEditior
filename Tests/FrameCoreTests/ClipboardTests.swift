import XCTest
@testable import FrameCore

final class ClipboardTests: XCTestCase {
    private func fixture(rate: FrameRate = .init(30)) throws -> (Project, UUID) {
        var project = Project(); project.frameRate = rate
        let media = MediaReference(name:"Source",path:"/fixture.mov",bookmark:Data([1,2,3]),kind:.video,
                                   duration:.init(seconds:20),width:1920,height:1080,frameRate:30,hasAudio:true)
        project.media = [media]
        let id = try Editing.add(mediaID:media.id,lane:.v2,at:.zero,to:&project)
        let frame = rate.frame.ticks
        try Editing.trim(id,leading:true,to:.init(ticks:frame*30),in:&project)
        try Editing.trim(id,leading:false,to:.init(ticks:frame*90),in:&project)
        try Editing.move(id,to:.init(ticks:frame*120),lane:.v2,in:&project)
        for i in project.clips.indices {
            project.clips[i].style.brightness = 0.2
            project.clips[i].style.scale = 1.3
            project.clips[i].style.volume = 0.35
            project.clips[i].style.muted = true
        }
        return (project,id)
    }

    func testLinkedCopiesPreserveEditsWithIndependentIdentities() throws {
        var (project,id) = try fixture()
        let original = project
        let payload = try ClipClipboard.decode(ClipClipboard(copying:id,from:project).encoded())
        XCTAssertEqual(payload.clips,original.group(for:id))
        let firstID = try Editing.paste(payload,at:project.duration,into:&project)
        let secondID = try Editing.paste(payload,at:project.duration,into:&project)
        for copyID in [firstID,secondID] {
            let group = project.group(for:copyID)
            XCTAssertEqual(group.count,2)
            XCTAssertEqual(Set(group.map(\.lane)),[.v2,.a2])
            XCTAssertEqual(Set(group.map(\.sourceStart)),[.init(seconds:1)])
            XCTAssertEqual(Set(group.map(\.duration)),[.init(seconds:2)])
            for clip in group {
                XCTAssertEqual(clip.style,original.clips[0].style)
                XCTAssertEqual(clip.mediaID,original.media[0].id)
            }
        }
        XCTAssertEqual(Set(project.clips.map(\.id)).count,6)
        XCTAssertEqual(Set(project.clips.compactMap(\.linkID)).count,3)
        XCTAssertEqual(project.group(for:id),original.clips)
        XCTAssertEqual(project.media,original.media)
        XCTAssertEqual(project.clips.first { $0.id == firstID }?.start,original.duration)
        XCTAssertEqual(project.clips.first { $0.id == secondID }?.start,.init(seconds:8))
    }

    func testCopiedAudioSelectsAudioAndSurvivesSourceDeletion() throws {
        var (project,id) = try fixture()
        let audio = try XCTUnwrap(project.group(for:id).first { $0.kind == .audio })
        let payload = try ClipClipboard(copying:audio.id,from:project)
        Editing.delete(id,from:&project)
        project.media.removeAll()
        let copyID = try Editing.paste(payload,at:.zero,into:&project)
        XCTAssertEqual(project.clips.first { $0.id == copyID }?.kind,.audio)
        XCTAssertEqual(project.group(for:copyID).count,2)
        XCTAssertEqual(project.media,payload.media)
        XCTAssertEqual(project.media[0].bookmark,Data([1,2,3]))
    }

    func testSingleClipsPreserveTextImageAndAudioProperties() throws {
        for kind: MediaKind in [.text,.image,.audio] {
            var project = Project()
            let id: UUID
            if kind == .text { id = try Editing.addText(at:.zero,to:&project) }
            else {
                let media = MediaReference(name:"Still or audio",path:"/fixture",kind:kind,duration:.init(seconds:5))
                project.media = [media]
                id = try Editing.add(mediaID:media.id,lane:kind == .audio ? .a1 : .v1,at:.zero,to:&project)
            }
            project.clips[0].style.text = "Ara 한글 자막"
            project.clips[0].style.fontSize = 110
            project.clips[0].style.red = 0.4
            project.clips[0].style.opacity = 0.6
            let original = project.clips[0]
            let payload = try ClipClipboard.decode(ClipClipboard(copying:id,from:project).encoded())
            let pastedID = try Editing.paste(payload,at:project.duration,into:&project)
            let pasted = try XCTUnwrap(project.clips.first { $0.id == pastedID })
            XCTAssertEqual(pasted.style,original.style)
            XCTAssertEqual(pasted.kind,kind)
            XCTAssertEqual(pasted.lane,original.lane)
            XCTAssertEqual(pasted.duration,original.duration)
            XCTAssertNil(pasted.linkID)
        }
    }

    func testRelinkedMediaIdentifierDoesNotReplaceCopiedSource() throws {
        let (source,id) = try fixture()
        let payload = try ClipClipboard(copying:id,from:source)
        var destination = Project()
        var relinked = source.media[0]; relinked.path = "/different.mov"
        destination.media = [relinked]
        let first = try Editing.paste(payload,at:.zero,into:&destination)
        let copiedMedia = try XCTUnwrap(destination.media(for:destination.group(for:first)[0]))
        XCTAssertNotEqual(copiedMedia.id,relinked.id)
        XCTAssertEqual(copiedMedia.path,source.media[0].path)
        XCTAssertEqual(copiedMedia.bookmark,source.media[0].bookmark)
        _ = try Editing.paste(payload,at:destination.duration,into:&destination)
        XCTAssertEqual(destination.media.count,2)
        XCTAssertEqual(destination.media[0],relinked)
    }

    func testOccupiedLinkedAudioRejectsEntirePasteAndMediaInsertion() throws {
        let (source,id) = try fixture()
        let payload = try ClipClipboard(copying:id,from:source)
        var destination = Project()
        let audio = MediaReference(name:"Occupied",path:"/audio.wav",kind:.audio,duration:.init(seconds:10))
        destination.media = [audio]
        _ = try Editing.add(mediaID:audio.id,lane:.a2,at:.zero,to:&destination)
        let before = destination
        XCTAssertThrowsError(try Editing.paste(payload,at:.zero,into:&destination))
        XCTAssertEqual(destination,before)
        XCTAssertEqual(destination.clips.count,1)
    }

    func testEveryFrameRateQuantizesPasteAndHistoryPersists() throws {
        for rate in FrameRate.supported {
            var (project,id) = try fixture(rate:rate)
            let payload = try ClipClipboard(copying:id,from:project)
            let before = project
            var history = EditHistory()
            let at = MediaTime(ticks:project.duration.ticks + rate.frame.ticks / 3)
            let copyID = try Editing.paste(payload,at:at,into:&project)
            history.record(before,name:"Paste clip")
            XCTAssertEqual(project.clips.first { $0.id == copyID }?.start,before.duration)
            let pasted = project
            project = try XCTUnwrap(history.undo(project)); XCTAssertEqual(project,before)
            project = try XCTUnwrap(history.redo(project)); XCTAssertEqual(project,pasted)
            XCTAssertEqual(try ProjectFile.decode(ProjectFile.encode(project)),pasted)
        }
    }

    func testInvalidRatePositionAndClipboardLeaveDestinationUntouched() throws {
        let (source,id) = try fixture()
        var payload = try ClipClipboard(copying:id,from:source)
        var destination = Project(); destination.frameRate = .init(24)
        let incompatible = destination
        XCTAssertThrowsError(try Editing.paste(payload,at:.zero,into:&destination))
        XCTAssertEqual(destination,incompatible)
        destination = source
        for ticks in [Int64(-1),Int64.max,7 * 86400 * MediaTime.scale] {
            XCTAssertThrowsError(try Editing.paste(payload,at:.init(ticks:ticks),into:&destination))
            XCTAssertEqual(destination,source)
        }
        payload.version = 999
        XCTAssertThrowsError(try ClipClipboard.decode(JSONEncoder().encode(payload)))
        XCTAssertThrowsError(try Editing.paste(payload,at:source.duration,into:&destination))
        XCTAssertEqual(destination,source)
        XCTAssertThrowsError(try ClipClipboard.decode(Data(repeating:0,count:2_000_001)))
        XCTAssertThrowsError(try ClipClipboard(copying:UUID(),from:source))
    }

    func testMalformedClipboardCannotBreakLinkedSyncOrMediaReferences() throws {
        let (source,id) = try fixture()
        let bytes = try ClipClipboard(copying:id,from:source).encoded()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        var missingMedia = original; missingMedia["media"] = []
        XCTAssertThrowsError(try ClipClipboard.decode(JSONSerialization.data(withJSONObject:missingMedia)))
        var brokenLink = original
        var clips = try XCTUnwrap(original["clips"] as? [[String:Any]])
        clips[0]["sourceStart"] = ["ticks":40_000]
        brokenLink["clips"] = clips
        XCTAssertThrowsError(try ClipClipboard.decode(JSONSerialization.data(withJSONObject:brokenLink)))
    }
}
