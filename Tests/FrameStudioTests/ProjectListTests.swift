import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

/// Projects found in a dropped folder only take free places on the start screen's list, so a
/// full list leaves some out: the drop says there is no room rather than that none were found.
@MainActor final class ProjectListTests: XCTestCase {
    func testAFullListSaysItHasNoRoom() async throws {
        _ = NSApplication.shared
        let suite = "ara.tests.projectlist.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-project-list-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        for name in ["a","b"] { try Data("{}".utf8).write(to:folder.appendingPathComponent("\(name).framestudio")) }
        let registry = ProjectRegistry(defaults:defaults), store = EditorStore(registry:registry)
        for i in 0..<ProjectHistory.limit-1 { registry.record(URL(fileURLWithPath:"/ara-tests-nowhere/\(i).framestudio")) }
        // Room for one of the two: it is listed and the other is counted, however often it is dropped.
        var result = await registry.add(from:[folder])
        XCTAssertEqual(result.added,1); XCTAssertEqual(result.unlisted,1)
        XCTAssertEqual(registry.history.entries.count,ProjectHistory.limit)
        XCTAssertEqual(registry.history.entries.filter { $0.path.hasPrefix("/ara-tests-nowhere/") }.count,ProjectHistory.limit-1,"none pushed out")
        result = await registry.add(from:[folder])
        XCTAssertEqual(result.added,0); XCTAssertEqual(result.unlisted,1)
        store.addProjects([folder])
        for _ in 0..<300 where store.message == nil { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(store.message,"The start screen lists up to 60 projects and has no room for 1 found here. Remove projects from the list to make room.")
        // Nothing new at all is still said as before.
        store.message = nil
        let empty = folder.appendingPathComponent("empty",isDirectory:true)
        try FileManager.default.createDirectory(at:empty,withIntermediateDirectories:true)
        store.addProjects([empty])
        for _ in 0..<300 where store.message == nil { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(store.message,"No new .framestudio projects were found there.")
    }
}
