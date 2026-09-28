import XCTest
@testable import FrameCore

/// Several clips at once: copied, pasted, moved and deleted as one.
final class MultipleSelectionTests: XCTestCase {
    /// A video with linked audio on V1/A1 at 1 s, a title on V2 at 2 s, a second video on V1 at 6 s.
    private func fixture() throws -> (Project, video: UUID, title: UUID, second: UUID) {
        var project = Project(); project.frameRate = .init(30)
        let media = MediaReference(name:"Source",path:"/fixture.mov",bookmark:Data([1]),kind:.video,
                                   duration:.init(seconds:20),width:1920,height:1080,frameRate:30,hasAudio:true)
        project.media = [media]
        let video = try Editing.add(mediaID:media.id,lane:.v1,at:.init(seconds:1),to:&project)
        try Editing.trim(video,leading:false,to:.init(seconds:4),in:&project)
        let title = try Editing.addText(at:.init(seconds:2),to:&project)
        let second = try Editing.add(mediaID:media.id,lane:.v1,at:.init(seconds:6),to:&project)
        try Editing.trim(second,leading:false,to:.init(seconds:8),in:&project)
        return (project,video,title,second)
    }

    func testSeveralClipsCopyWithTheirPartnersAndPasteAtTheirDistances() throws {
        var (project,video,title,second) = try fixture()
        let payload = try ClipClipboard.decode(ClipClipboard(copying:[title,second,video],from:project).encoded())
        XCTAssertEqual(payload.version,2)
        XCTAssertEqual(payload.clips.count,5,"both videos bring their linked audio")
        XCTAssertEqual(payload.selectedID,video,"the earliest clip is the anchor")
        let before = project.clips.count
        let pasted = try Editing.pasteAll(payload,at:.init(seconds:20),into:&project)
        XCTAssertEqual(pasted.clips.count,5); XCTAssertEqual(project.clips.count,before+5)
        XCTAssertEqual(pasted.clips.first,pasted.anchor)
        let copies = project.clips.filter { pasted.clips.contains($0.id) }
        // Same tracks and distances, the earliest at the paste point.
        let original = project.clips.filter { [video,title,second].flatMap { id in project.group(for:id).map(\.id) }.contains($0.id) }
        XCTAssertEqual(copies.map(\.start).min(),.init(seconds:20))
        func layout(_ clips: [Clip], from start: MediaTime) -> [String] {
            clips.map { "\($0.lane.rawValue) \($0.kind.rawValue) \(($0.start-start).ticks) \($0.duration.ticks)" }.sorted()
        }
        XCTAssertEqual(layout(copies,from:.init(seconds:20)),layout(original,from:.init(seconds:1)))
        // Fresh identities, links kept inside each pair.
        XCTAssertTrue(Set(copies.map(\.id)).isDisjoint(with:original.map(\.id)))
        XCTAssertEqual(Set(copies.compactMap(\.linkID)).count,2)
        XCTAssertTrue(Set(copies.compactMap(\.linkID)).isDisjoint(with:original.compactMap(\.linkID)))
        // Where any of them would land on a clip, they all go up together to free tracks,
        // keeping their layout and each video's audio on the same number.
        let again = try Editing.pasteAll(payload,at:.init(seconds:21),into:&project)
        XCTAssertEqual(again.raised,2,"V1/A1 and V2 are in use from 21 s: up two, to V3–V4 and A3")
        let raised = project.clips.filter { again.clips.contains($0.id) }
        XCTAssertEqual(layout(raised.map { var c = $0; c.lane = Lane(c.lane.kind,c.lane.number-2); return c },from:.init(seconds:21)),
                       layout(original,from:.init(seconds:1)))
        for clip in raised where clip.linkID != nil {
            XCTAssertEqual(Set(project.group(for:clip.id).map(\.lane.number)).count,1,"a video and its audio stay on one number")
        }
    }

    func testOneClipStillCopiesAsVersionOneAndBrokenGroupsAreRefused() throws {
        let (project,video,title,_) = try fixture()
        // One clip and its partner, through the several-clips path: the version every Ara reads.
        let single = try ClipClipboard(copying:[video],from:project)
        XCTAssertEqual(single.version,1); XCTAssertEqual(single.clips.count,2)
        XCTAssertEqual(try ClipClipboard.decode(single.encoded()),single)
        // A version 2 copy missing one half of a linked pair is not accepted.
        let several = try ClipClipboard(copying:[video,title],from:project)
        var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(several)) as! [String:Any]
        var clips = json["clips"] as! [[String:Any]]
        clips.removeAll { ($0["kind"] as? String) == "audio" }
        json["clips"] = clips
        XCTAssertThrowsError(try ClipClipboard.decode(JSONSerialization.data(withJSONObject:json)))
        // Version 1 holds one group only.
        json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(several)) as! [String:Any]
        json["version"] = 1
        XCTAssertThrowsError(try ClipClipboard.decode(JSONSerialization.data(withJSONObject:json)))
    }

    func testSeveralClipsMoveAndDeleteTogether() throws {
        var (project,video,title,second) = try fixture()
        let before = project
        try Editing.move([video,title],by:.init(seconds:0.5),in:&project)
        for id in [video,title] + project.group(for:video).map(\.id) {
            XCTAssertEqual(project.clips.first { $0.id == id }!.start,before.clips.first { $0.id == id }!.start+MediaTime(seconds:0.5))
        }
        XCTAssertEqual(project.clips.first { $0.id == second }!.start,.init(seconds:6),"a clip not selected stays")
        // Never before the start: the earliest stops at zero, the rest keep their distances.
        try Editing.move([video,title],by:.init(seconds:-10),in:&project)
        XCTAssertEqual(project.clips.first { $0.id == video }!.start,.zero)
        XCTAssertEqual(project.clips.first { $0.id == title }!.start,.init(seconds:1))
        // Onto a busy spot: nothing moves.
        let placed = project
        XCTAssertThrowsError(try Editing.move([video],by:.init(seconds:5.5),in:&project))
        XCTAssertEqual(project,placed)
        Editing.delete([video,second],from:&project)
        XCTAssertEqual(project.clips.map(\.id),[title],"both videos go with their linked audio")
    }

    func testACopyTooBigToPasteIsNeverMade() throws {
        var project = Project(); project.frameRate = .init(30)
        var ids: [UUID] = []
        for n in 0..<60 {                                            // 60 stills, each with a large bookmark
            let still = MediaReference(name:"Still \(n)",path:"/still-\(n).png",bookmark:Data(repeating:7,count:40_000),kind:.image,
                                       duration:.init(seconds:5),width:640,height:360,frameRate:0,hasAudio:false)
            project.media.append(still)
            ids.append(try Editing.add(mediaID:still.id,lane:.v1,at:.init(seconds:Double(n)*5),to:&project))
        }
        let payload = try ClipClipboard(copying:ids,from:project)
        XCTAssertThrowsError(try payload.encoded(),"more than paste would take")
        XCTAssertNoThrow(try ClipClipboard(copying:Array(ids.prefix(5)),from:project).encoded())
    }

    /// Titles A 0–3 s and B 3–6 s meeting on V1: A fades in (dip to black, 0.5 s), dissolves
    /// into B (1 s), and B fades out (push, 0.5 s).
    private func transitionFixture() throws -> (Project, a: UUID, b: UUID) {
        var project = Project(); project.frameRate = .init(30)
        let a = Clip(name:"A",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3))
        let b = Clip(name:"B",kind:.text,lane:.v1,start:.init(seconds:3),duration:.init(seconds:3))
        project.clips = [a,b]
        try Editing.setTransition(.dipToBlack,duration:.init(seconds:0.5),from:nil,to:a.id,in:&project)
        try Editing.setTransition(.crossDissolve,duration:.init(seconds:1),from:a.id,to:b.id,in:&project)
        try Editing.setTransition(.push,direction:.up,duration:.init(seconds:0.5),from:b.id,to:nil,in:&project)
        return (project,a.id,b.id)
    }
    private func summary(_ project: Project, _ ids: [UUID]) -> [String] {
        project.transitions.filter { t in [t.from,t.to].contains { $0.map(ids.contains) == true } }.map { t in
            let from = t.from.flatMap { id in ids.firstIndex(of:id) }.map(String.init) ?? "-"
            let to = t.to.flatMap { id in ids.firstIndex(of:id) }.map(String.init) ?? "-"
            return "\(from)>\(to) \(t.kind.rawValue) \(t.direction.rawValue) \(t.duration.ticks)"
        }.sorted()
    }

    func testCopiedClipsBringTheirTransitions() throws {
        var (project,a,b) = try transitionFixture()
        let before = project.transitions
        let payload = try ClipClipboard.decode(ClipClipboard(copying:[a,b],from:project).encoded())
        XCTAssertEqual(payload.transitions.count,3)
        let pasted = try Editing.pasteAll(payload,at:.init(seconds:10),into:&project)
        let copies = pasted.clips.sorted { project.clip($0)!.start < project.clip($1)!.start }
        XCTAssertEqual(summary(project,copies),summary(project,[a,b]),"fade in, dissolve between them, fade out")
        XCTAssertEqual(project.transitions.count,6)
        XCTAssertTrue(Set(project.transitions.map(\.id)).isSuperset(of:before.map(\.id)),"the originals are untouched")
        XCTAssertEqual(Set(project.transitions.map(\.id)).count,6,"fresh identities")
    }

    func testATransitionToAClipLeftBehindBecomesAFade() throws {
        var (project,a,b) = try transitionFixture()
        // A alone: its fade in, and its dissolve into B as a fade out of the same kind.
        let onlyA = try ClipClipboard(copying:a,from:project)
        XCTAssertEqual(onlyA.version,1)
        let copyA = try Editing.paste(onlyA,at:.init(seconds:10),into:&project)
        // The dissolve's part inside A (half of its 1 s) becomes the fade out.
        XCTAssertEqual(summary(project,[copyA]),["->0 dipToBlack left 300000","0>- crossDissolve left 300000"].sorted())
        // B alone: the dissolve from A becomes its fade in; its own fade out comes as it is.
        let copyB = try Editing.paste(ClipClipboard(copying:b,from:project),at:.init(seconds:20),into:&project)
        XCTAssertEqual(summary(project,[copyB]),["->0 crossDissolve left 300000","0>- push up 300000"].sorted())
    }

    func testAConvertedCutNeverShortensTheClipsOwnFade() throws {
        // A 0–2 s with a 1 s fade in, and a 2 s dissolve into B that takes A's other second.
        var project = Project(); project.frameRate = .init(30)
        let a = Clip(name:"A",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:2))
        let b = Clip(name:"B",kind:.text,lane:.v1,start:.init(seconds:2),duration:.init(seconds:2))
        project.clips = [a,b]
        try Editing.setTransition(.dipToBlack,duration:.init(seconds:1),from:nil,to:a.id,in:&project)
        try Editing.setTransition(.crossDissolve,duration:.init(seconds:2),from:a.id,to:b.id,in:&project)
        let copy = try Editing.paste(ClipClipboard(copying:a.id,from:project),at:.init(seconds:10),into:&project)
        XCTAssertEqual(summary(project,[copy]),["->0 dipToBlack left 600000","0>- crossDissolve left 600000"].sorted(),"the fade in stays 1 s")
        // A cut that no longer plays (its other clip deleted without validating) is not copied.
        var stale = project
        Editing.delete(b.id,from:&stale)
        XCTAssertEqual(try ClipClipboard(copying:a.id,from:stale).transitions.map(\.kind),[.dipToBlack])
    }

    func testADamagedTransitionLengthIsRefusedNotACrash() throws {
        let (project,a,_) = try transitionFixture()
        for ticks: Int64 in [.max,.min,-1] {
            var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(ClipClipboard(copying:a,from:project))) as! [String:Any]
            var transitions = json["transitions"] as! [[String:Any]]
            transitions[0]["duration"] = ["ticks":NSNumber(value:ticks)]
            json["transitions"] = transitions
            XCTAssertThrowsError(try ClipClipboard.decode(JSONSerialization.data(withJSONObject:json)),"\(ticks)")
        }
        // A project file with one is fitted to the longest transition, at every frame rate.
        for rate in [FrameRate(24),FrameRate(30),FrameRate(60),FrameRate(30000,1001)] {
            var damaged = Project(); damaged.frameRate = rate
            let clip = Clip(name:"T",kind:.text,lane:.v1,start:.zero,duration:.init(ticks:rate.frame.ticks*300))
            damaged.clips = [clip]
            damaged.transitions = [Transition(kind:.crossDissolve,duration:.init(ticks:.max),from:nil,to:clip.id)]
            XCTAssertLessThanOrEqual(try damaged.validated().transitions.first?.duration ?? .zero,Transition.longest)
        }
    }

    func testOlderClipboardsWithoutTransitionsStillPasteAndStrayOnesAreRefused() throws {
        var (project,a,_) = try transitionFixture()
        var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(ClipClipboard(copying:a,from:project))) as! [String:Any]
        json.removeValue(forKey:"transitions")                     // what an older Ara writes
        let older = try ClipClipboard.decode(JSONSerialization.data(withJSONObject:json))
        XCTAssertTrue(older.transitions.isEmpty)
        let copy = try Editing.paste(older,at:.init(seconds:10),into:&project)
        XCTAssertTrue(summary(project,[copy]).isEmpty)
        // A transition naming a clip that is not in the copy is not accepted.
        var stray = try JSONSerialization.jsonObject(with:JSONEncoder().encode(ClipClipboard(copying:a,from:project))) as! [String:Any]
        var transitions = stray["transitions"] as! [[String:Any]]
        transitions[0]["to"] = UUID().uuidString; transitions[0]["from"] = UUID().uuidString
        stray["transitions"] = transitions
        XCTAssertThrowsError(try ClipClipboard.decode(JSONSerialization.data(withJSONObject:stray)))
    }
}
