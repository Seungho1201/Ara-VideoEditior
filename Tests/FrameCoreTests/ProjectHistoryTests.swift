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
    /// Files found in a dropped folder only take free places: projects the user opened stay listed
    /// however many newer files the folder holds.
    func testDiscoveredFilesNeverPushOutOpenedProjects() {
        var history = ProjectHistory()
        for i in 0..<10 { history.record("/opened/\(i).framestudio", at: t0 + Double(i)) }            // a week ago
        let found = (0..<60).map { (path: "/dropped/\($0).framestudio", date: t0 + 7 * 86400 + Double($0)) }
        XCTAssertEqual(history.add(discovered: found), ProjectHistory.limit - 10)
        XCTAssertEqual(history.entries.count, ProjectHistory.limit)
        XCTAssertEqual(history.entries.filter { $0.path.hasPrefix("/opened/") }.count, 10)
        // The newest found files took the free places, and the list is still newest first.
        XCTAssertTrue(history.entries.contains { $0.path == "/dropped/59.framestudio" })
        XCTAssertFalse(history.entries.contains { $0.path == "/dropped/0.framestudio" })
        XCTAssertEqual(history.entries.map(\.lastOpened), history.entries.map(\.lastOpened).sorted(by: >))
        // A full list takes no more, and loses nothing.
        let full = history
        XCTAssertEqual(history.add(discovered: [(path: "/late/new.framestudio", date: t0 + 99 * 86400)]), 0)
        XCTAssertEqual(history, full)
    }
    /// Once a dropped folder has filled the list, each project opened later pushes off a file that
    /// was only found (the oldest), never one the user opened. A found file opened is an opened one.
    func testOpeningProjectsAfterADropPushesOffFoundFilesFirst() throws {
        var history = ProjectHistory()
        for i in 0..<10 { history.record("/opened/\(i).framestudio", at: t0 + Double(i)) }            // a week ago
        history.add(discovered: (0..<60).map { (path: "/dropped/\($0).framestudio", date: t0 + 7 * 86400 + Double($0)) })
        history.record("/dropped/59.framestudio", at: t0 + 8 * 86400)                                  // one of them opened
        for i in 0..<12 { history.record("/new/\(i).framestudio", at: t0 + 8 * 86400 + 1 + Double(i)) }
        XCTAssertEqual(history.entries.count, ProjectHistory.limit)
        XCTAssertEqual(history.entries.filter { $0.path.hasPrefix("/opened/") }.count, 10)
        XCTAssertEqual(history.entries.filter { $0.path.hasPrefix("/new/") }.count, 12)
        XCTAssertTrue(history.entries.contains { $0.path == "/dropped/59.framestudio" && $0.discovered == nil })
        XCTAssertFalse(history.entries.contains { $0.path == "/dropped/10.framestudio" }, "the oldest found files went first")
        XCTAssertTrue(history.entries.contains { $0.path == "/dropped/58.framestudio" })
        // With no found file left, the project opened longest ago goes, as before.
        for i in 0..<37 { history.record("/later/\(i).framestudio", at: t0 + 9 * 86400 + Double(i)) }
        XCTAssertFalse(history.entries.contains { $0.discovered == true })
        XCTAssertEqual(history.entries.filter { $0.path.hasPrefix("/opened/") }.count, 10)
        history.record("/last.framestudio", at: t0 + 10 * 86400)
        XCTAssertFalse(history.entries.contains { $0.path == "/opened/0.framestudio" })
        // Lists saved before the mark count every project as opened, and keep the mark once saved.
        let old = try JSONDecoder().decode(ProjectHistory.self, from: Data(#"{"entries":[{"path":"/p/a.framestudio","lastOpened":0}]}"#.utf8))
        XCTAssertEqual(old.entries.map(\.discovered), [nil])
        XCTAssertEqual(try JSONDecoder().decode(ProjectHistory.self, from: JSONEncoder().encode(history)), history)
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
