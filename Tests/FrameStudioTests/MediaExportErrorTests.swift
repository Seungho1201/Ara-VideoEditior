import XCTest
@preconcurrency import AVFoundation
import FrameCore
@testable import FrameMedia

/// An export that fails says why in terms of what the user chose: the destination folder (never
/// Ara's hidden work folder inside it) or the source file that could not be read. It leaves no
/// partial movie and no work folder behind.
final class MediaExportErrorTests: XCTestCase {
    private var folder: URL!, builder: CompositionBuilder!
    override func setUp() async throws {
        folder = try TestMovie.folder("export-errors")
        builder = CompositionBuilder(sentinels:SentinelStore { [folder] in folder!.appendingPathComponent("cache") })
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at:folder) }
    private func message(_ work: () async throws -> Void) async -> String {
        do { try await work(); return "succeeded" } catch { return error.localizedDescription }
    }
    private func leftovers(_ url: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath:url.path)) ?? []).filter { $0.hasPrefix(".frame-") } }
    private func movie(_ name: String) async throws -> (RenderBundle,URL) {
        let url = folder.appendingPathComponent(name)
        try await TestMovie.write(to:url,frames:30) { _ in (255,0,0) }
        let media = try await MediaLibrary().inspect(url)
        var project = Project(); project.media = [media]
        _ = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
        return (try await builder.build(project,urls:[media.id:url]),url)
    }

    func testAFolderThatCannotBeWrittenIsNamed() async throws {
        let (bundle,_) = try await movie("source.mov")
        let locked = folder.appendingPathComponent("Locked Folder")
        try FileManager.default.createDirectory(at:locked,withIntermediateDirectories:true)
        try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:locked.path) }
        let text = await message { try await MovieExporter().export(bundle,to:locked.appendingPathComponent("movie.mp4")) { _ in } }
        XCTAssertTrue(text.contains("“Locked Folder”"),text)
        XCTAssertFalse(text.contains(".frame-") || text.contains(".work"),text)
        XCTAssertEqual(leftovers(locked),[])
    }
    /// A file cut short under the reader (a failing disk) after the composition was built.
    func testASourceCutShortIsNamed() async throws {
        let (bundle,source) = try await movie("cut.mov")
        XCTAssertTrue(MovieExporter.unreadable(bundle).message.hasPrefix("A source file could not be read"),"nothing has changed yet")
        let handle = try FileHandle(forWritingTo:source); try handle.truncate(atOffset:4096); try handle.close()
        let destination = folder.appendingPathComponent("out.mp4")
        let text = await message { try await MovieExporter().export(bundle,to:destination) { _ in } }
        XCTAssertTrue(text.contains("“cut.mov”"),text)
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        XCTAssertEqual(leftovers(folder),[])
    }
    func testADestinationThatCannotBeReplacedIsNamed() async throws {
        let (bundle,_) = try await movie("source.mov")
        let taken = folder.appendingPathComponent("taken.mp4",isDirectory:true)
        try FileManager.default.createDirectory(at:taken.appendingPathComponent("inside"),withIntermediateDirectories:true)
        let text = await message { try await MovieExporter().export(bundle,to:taken) { _ in } }
        XCTAssertTrue(text.contains("“taken.mp4”"),text)
        XCTAssertTrue(FileManager.default.fileExists(atPath:taken.appendingPathComponent("inside").path))
        XCTAssertEqual(leftovers(folder),[])
    }
}
