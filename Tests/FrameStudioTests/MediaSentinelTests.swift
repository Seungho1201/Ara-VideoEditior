import XCTest
import FrameCore
@testable import FrameMedia

/// Every composition plays over a small clock video and a second of silence kept in the cache
/// folder. Emptying that folder while Ara runs must not break the builds that follow.
final class MediaSentinelTests: XCTestCase {
    private var folder: URL!
    override func setUp() async throws { folder = try TestMovie.folder("sentinels") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at:folder) }
    private var title: Project {
        var project = Project()
        project.clips = [Clip(name:"Title",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:1))]
        return project
    }
    private func names(_ url: URL) -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath:url.path)) ?? []) }

    func testBuildsSnapshotsAndExportsAfterTheFilesAreDeleted() async throws {
        let cache = folder.appendingPathComponent("cache")
        let builder = CompositionBuilder(sentinels:SentinelStore { cache })
        _ = try await builder.build(title,urls:[:])
        XCTAssertEqual(names(cache),["clock-v1.mov","silence-v1.caf"])
        // The whole folder emptied (and gone), as a cleaner app leaves it.
        try FileManager.default.removeItem(at:cache)
        let bundle = try await builder.build(title,urls:[:])
        XCTAssertEqual(names(cache),["clock-v1.mov","silence-v1.caf"])
        _ = try await SnapshotExporter().png(bundle,at:.zero)
        try await MovieExporter().export(bundle,to:folder.appendingPathComponent("after.mp4")) { _ in }
        // Only one of the two.
        try FileManager.default.removeItem(at:cache.appendingPathComponent("silence-v1.caf"))
        _ = try await builder.build(title,urls:[:])
        XCTAssertEqual(names(cache),["clock-v1.mov","silence-v1.caf"])
    }
    /// Builds that start together after a purge all succeed, with the files made once.
    func testBuildsTogetherAfterAPurge() async throws {
        let cache = folder.appendingPathComponent("cache"), store = SentinelStore { cache }
        _ = try await CompositionBuilder(sentinels:store).build(title,urls:[:])
        try FileManager.default.removeItem(at:cache)
        let project = title
        try await withThrowingTaskGroup(of:Void.self) { group in
            for _ in 0..<4 { group.addTask { _ = try await CompositionBuilder(sentinels:store).build(project,urls:[:]) } }
            try await group.waitForAll()
        }
        XCTAssertEqual(names(cache),["clock-v1.mov","silence-v1.caf"])
    }
    /// The app's own store, with the cache emptied for real. Only where the cache folder is not
    /// the user's: run with CFFIXED_USER_HOME pointing at a scratch folder.
    func testTheAppsStoreRecoversWhenItsCacheIsEmptied() async throws {
        let cache = MediaPaths.cache, home = String(cString:getpwuid(getuid())!.pointee.pw_dir)
        guard !cache.standardizedFileURL.path.hasPrefix(home+"/Library/") else { throw XCTSkip("the cache folder is the user's own: \(cache.path)") }
        _ = try await CompositionBuilder().build(title,urls:[:])
        for name in ["clock-v1.mov","silence-v1.caf"] { try FileManager.default.removeItem(at:cache.appendingPathComponent(name)) }
        let bundle = try await CompositionBuilder().build(title,urls:[:])
        _ = try await SnapshotExporter().png(bundle,at:.zero)
        try await MovieExporter().export(bundle,to:folder.appendingPathComponent("app-store.mp4")) { _ in }
    }
}
