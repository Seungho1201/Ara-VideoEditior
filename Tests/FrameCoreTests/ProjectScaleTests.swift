import XCTest
@testable import FrameCore

/// Validation runs on every open, save and edit, and group edits on every drag sample: both
/// must grow with the number of clips, not with its square.
final class ProjectScaleTests: XCTestCase {
    /// `pairs` videos with their linked audio, end to end, from `mediaCount` sources.
    private func project(pairs: Int, mediaCount: Int = 1) -> Project {
        var p = Project()
        p.media = (0..<mediaCount).map { MediaReference(name:"m\($0).mp4",path:"/m\($0).mp4",kind:.video,duration:.init(seconds:3600),hasAudio:true) }
        for i in 0..<pairs {
            let media = p.media[i % mediaCount], link = UUID(), start = MediaTime(seconds:Double(i)*2)
            p.clips.append(Clip(mediaID:media.id,name:media.name,kind:.video,lane:.v1,start:start,duration:.init(seconds:2),linkID:link))
            p.clips.append(Clip(mediaID:media.id,name:media.name,kind:.audio,lane:.a1,start:start,duration:.init(seconds:2),linkID:link))
        }
        return p
    }
    private func seconds(_ block: () throws -> Void) rethrows -> Double {
        let start = CFAbsoluteTimeGetCurrent(); try block(); return CFAbsoluteTimeGetCurrent()-start
    }
    func testValidationAndGroupEditsGrowLinearly() throws {
        let small = try project(pairs:500,mediaCount:50).validated(), large = try project(pairs:4000,mediaCount:400).validated()
        let videos = Set(large.clips.filter { $0.kind == .video }.map(\.id))
        // Eight times the clips: about eight times the work (quadratic was about sixty-four).
        let a = try (0..<3).map { _ in try seconds { _ = try small.validated() } }.min()!
        let b = try (0..<3).map { _ in try seconds { _ = try large.validated() } }.min()!
        XCTAssertLessThan(b,a*24,"validating 8000 clips took \(b) s, 1000 took \(a) s")
        var moved = large, deleted = large
        let move = try seconds { try Editing.move(videos,by:.init(seconds:1),in:&moved) }
        let delete = seconds { Editing.delete(videos,from:&deleted) }
        XCTAssertLessThan(max(move,delete),b*4+0.05,"moving or deleting 8000 linked clips took \(move) / \(delete) s")
        XCTAssertEqual(Set(moved.clips.map(\.start)),Set(large.clips.map { $0.start+MediaTime(seconds:1) }))
        XCTAssertTrue(deleted.clips.isEmpty)
    }
    /// One pass over the clips finds the same groups as asking for each clip's group.
    func testGroupIDsMatchEachClipsGroup() throws {
        var p = project(pairs:20)
        p.clips.append(Clip(name:"Title",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:3)))
        let picked = Set([p.clips[0].id,p.clips[7].id,p.clips[12].id,p.clips.last!.id,UUID()])
        let expected = picked.reduce(into:Set<UUID>()) { $0.formUnion(p.group(for:$1).map(\.id)) }
        XCTAssertEqual(p.groupIDs(for:picked),expected)
        XCTAssertEqual(expected.count,7)
        XCTAssertEqual(p.groupIDs(for:[]),[],"nothing selected (as the timeline asks on every draw)")
    }
}
