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
        // Where any of them would land on a busy spot, nothing is pasted.
        let busy = project
        XCTAssertThrowsError(try Editing.pasteAll(payload,at:.init(seconds:5),into:&project))
        XCTAssertEqual(project,busy)
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
}
