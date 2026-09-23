import XCTest
@testable import FrameCore

final class ProjectHistoryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecordPutsMostRecentFirstWithoutDuplicates() {
        var history = ProjectHistory()
        history.record("/p/a.framestudio", at: t0)
        history.record("/p/b.framestudio", at: t0 + 10)
        history.record("/p/a.framestudio", at: t0 + 20)          // reopened: moves to the front
        XCTAssertEqual(history.entries.map(\.path), ["/p/a.framestudio", "/p/b.framestudio"])
        XCTAssertEqual(history.entries.first?.lastOpened, t0 + 20)
    }
    func testDifferentSpellingsOfOnePathAreOneEntry() {
        var history = ProjectHistory()
        history.record("/p/./a.framestudio", at: t0)
        history.record("/p/x/../a.framestudio", at: t0 + 1)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.path, "/p/a.framestudio")
    }
    func testReRecordingKeepsAKnownBookmark() {
        var history = ProjectHistory()
        history.record("/p/a.framestudio", at: t0, bookmark: Data([1, 2]))
        history.record("/p/a.framestudio", at: t0 + 1)             // save without a fresh bookmark
        XCTAssertEqual(history.entries.first?.bookmark, Data([1, 2]))
    }
    func testListIsBounded() {
        var history = ProjectHistory()
        for i in 0..<(ProjectHistory.limit + 15) { history.record("/p/\(i).framestudio", at: t0 + Double(i)) }
        XCTAssertEqual(history.entries.count, ProjectHistory.limit)
        XCTAssertEqual(history.entries.first?.path, "/p/\(ProjectHistory.limit + 14).framestudio")
    }
    func testRemoveAndRelocateKeepOrder() {
        var history = ProjectHistory()
        history.record("/p/c.framestudio", at: t0)
        history.record("/p/b.framestudio", at: t0 + 1)
        history.record("/p/a.framestudio", at: t0 + 2)
        history.relocate("/p/b.framestudio", to: "/moved/b.framestudio", bookmark: Data([9]))
        XCTAssertEqual(history.entries.map(\.path), ["/p/a.framestudio", "/moved/b.framestudio", "/p/c.framestudio"])
        XCTAssertEqual(history.entries[1].bookmark, Data([9]))
        history.remove("/p/a.framestudio")
        XCTAssertEqual(history.entries.map(\.path), ["/moved/b.framestudio", "/p/c.framestudio"])
    }
    func testDiscoveredFilesMergeByDateWithoutDuplicatingOrReorderingKnownOnes() {
        var history = ProjectHistory()
        history.record("/p/recent.framestudio", at: t0 + 100)
        history.add(discovered: [
            (path: "/p/old.framestudio", date: t0),
            (path: "/p/recent.framestudio", date: t0 - 999),   // already listed: keeps its own date
            (path: "/p/newer.framestudio", date: t0 + 50),
        ])
        XCTAssertEqual(history.entries.map(\.path), ["/p/recent.framestudio", "/p/newer.framestudio", "/p/old.framestudio"])
        XCTAssertEqual(history.entries.first?.lastOpened, t0 + 100)
    }
    func testLateBookmarkAttachesWithoutReordering() {
        var history = ProjectHistory()
        history.record("/p/b.framestudio", at: t0)
        history.record("/p/a.framestudio", at: t0 + 1)
        history.setBookmark(Data([4]), for: "/p/./b.framestudio")
        XCTAssertEqual(history.entries.map(\.path), ["/p/a.framestudio", "/p/b.framestudio"])
        XCTAssertEqual(history.entries[1].bookmark, Data([4]))
        history.setBookmark(Data([5]), for: "/p/unknown.framestudio")         // not listed: ignored
        XCTAssertEqual(history.entries.count, 2)
    }
    func testHistorySurvivesAJSONRoundTrip() throws {
        var history = ProjectHistory()
        history.record("/p/a.framestudio", at: t0, bookmark: Data([7]))
        let decoded = try JSONDecoder().decode(ProjectHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(decoded, history)
    }
    func testSummaryCountsVisibleClipsAndPicksAPoster() throws {
        var p = Project(); p.frameRate = .init(60)
        let video = MediaReference(name: "a.mov", path: "/m/a.mov", kind: .video, duration: .init(seconds: 10), hasAudio: true)
        let still = MediaReference(name: "s.png", path: "/m/s.png", kind: .image, duration: .init(seconds: 5))
        p.media = [still, video]
        _ = try Editing.add(mediaID: video.id, lane: .v1, at: .zero, to: &p)       // V1 + linked A1
        _ = try Editing.add(mediaID: still.id, lane: .v2, at: .init(seconds: 2), to: &p)
        _ = try Editing.addText(at: .init(seconds: 20), to: &p)
        let summary = ProjectSummary(p)
        XCTAssertEqual(summary.clipCount, 3)                                     // linked audio is not a second clip
        XCTAssertEqual(summary.mediaCount, 2)
        XCTAssertEqual(summary.duration, .init(seconds: 23))
        XCTAssertEqual(summary.frameRate, .init(60))
        XCTAssertEqual(summary.posterMediaPath, "/m/a.mov")                        // earliest on the picture lanes
    }
    func testSummaryOfAnEmptyProjectHasNoPoster() {
        let summary = ProjectSummary(Project())
        XCTAssertEqual(summary.clipCount, 0)
        XCTAssertNil(summary.posterMediaPath)
    }
}
