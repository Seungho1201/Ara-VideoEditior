import XCTest
@preconcurrency import AVFoundation
import FrameCore
@testable import FrameMedia

/// Whole clips appended back to back keep their last frames when the frame rate changes: the
/// cut goes to the nearest frame, and a clip whose source ends before it (by less than a frame)
/// holds its last frame there, never a black or empty frame.
final class MediaFrameRateChangeTests: XCTestCase {
    private var folder: URL!
    private var builder: CompositionBuilder!
    override func setUp() async throws {
        folder = try TestMovie.folder("rates")
        builder = CompositionBuilder(sentinels:SentinelStore { [folder] in folder!.appendingPathComponent("cache") })
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at:folder) }

    private func isBlue(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.b > 180 && c.r < 70 && c.g < 70 }
    private func isRed(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 180 && c.g < 70 && c.b < 70 }

    /// Two whole 6 s clips at 30 fps (red, their last ten frames blue), then every other rate.
    func testTheFrameBeforeEachCutIsTheClipsOwnLastFrames() async throws {
        let url = folder.appendingPathComponent("six.mov")
        try await TestMovie.write(to:url,frames:180) { $0 < 170 ? (255,0,0) : (0,0,255) }
        try await check(url)
    }
    /// A picture that stops before its sound (179 frames, 6 s of audio): the clip runs as long as
    /// its sound, and its last picture is held to the cut at every rate.
    func testAPictureShorterThanItsSoundHoldsItsLastFrame() async throws {
        let url = folder.appendingPathComponent("short-picture.mov")
        try await TestMovie.write(to:url,frames:179,audioSeconds:6) { $0 < 170 ? (255,0,0) : (0,0,255) }
        try await check(url)
    }
    private func check(_ url: URL) async throws {
        let media = try await MediaLibrary().inspect(url)
        var project = Project(); project.media = [media]
        let first = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
        let second = try Editing.add(mediaID:media.id,lane:.v1,at:project.duration,to:&project)
        XCTAssertEqual(project.clip(first)?.end,.init(seconds:6))
        for rate in [FrameRate(30000,1001),.init(24000,1001),.init(60000,1001),.init(24),.init(25),.init(50),.init(60)] {
            var converted = project
            try Editing.setVideoSettings(aspectRatio:.landscape,frameRate:rate,in:&converted)
            let cut = try XCTUnwrap(converted.clip(first)).end, end = converted.duration
            XCTAssertLessThanOrEqual(abs(cut.ticks-MediaTime(seconds:6).ticks),rate.frame.ticks/2,"\(rate.label): the cut moved more than half a frame")
            XCTAssertEqual(converted.clip(second)?.start,cut)
            let bundle = try await builder.build(converted,urls:[media.id:url])
            for (name,time) in [("before the cut",cut-rate.frame),("at the end",end-rate.frame)] {
                let colour = TestMovie.centre(try await TestMovie.frame(bundle,at:time))
                XCTAssertTrue(isBlue(colour),"\(rate.label) fps, the frame \(name) (\(time.seconds) s) shows \(colour), not the clip's last frames")
            }
            let first = TestMovie.centre(try await TestMovie.frame(bundle,at:cut))
            XCTAssertTrue(isRed(first),"\(rate.label) fps: the second clip starts on its first frame, got \(first)")
        }
        // The exported movie as well: same frames, the timeline's length, sound to the end.
        var converted = project
        try Editing.setVideoSettings(aspectRatio:.landscape,frameRate:.init(30000,1001),in:&converted)
        let movie = folder.appendingPathComponent("export-2997.mp4")
        try await MovieExporter().export(try await builder.build(converted,urls:[media.id:url]),to:movie) { _ in }
        let cut = try XCTUnwrap(converted.clip(first)).end
        let beforeCut = TestMovie.centre(try await TestMovie.frame(of:movie,at:cut-converted.frameRate.frame))
        let last = TestMovie.centre(try await TestMovie.frame(of:movie,at:converted.duration-converted.frameRate.frame))
        XCTAssertTrue(isBlue(beforeCut) && isBlue(last),"exported frames before the cut and at the end: \(beforeCut) \(last)")
        let asset = AVURLAsset(url:movie)
        let duration = try await asset.load(.duration), audio = try await asset.loadTracks(withMediaType:.audio)
        XCTAssertEqual(duration.seconds,converted.duration.seconds,accuracy:0.002)
        let sound = try await XCTUnwrap(audio.first).load(.timeRange)
        XCTAssertEqual(sound.end.seconds,converted.duration.seconds,accuracy:converted.frameRate.frame.seconds)
    }
}
