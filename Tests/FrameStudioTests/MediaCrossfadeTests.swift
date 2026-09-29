import XCTest
@preconcurrency import AVFoundation
import FrameCore
@testable import FrameMedia

/// Linked sound across a dissolve: two different sounds cross with constant power, but the two
/// halves of a split clip play the same sound in step there, which adds up as amplitude, so they
/// cross with constant gain and the level holds.
final class MediaCrossfadeTests: XCTestCase {
    private var folder: URL!, builder: CompositionBuilder!, media: MediaReference!, url: URL!
    override func setUp() async throws {
        folder = try TestMovie.folder("crossfade")
        builder = CompositionBuilder(sentinels:SentinelStore { [folder] in folder!.appendingPathComponent("cache") })
        url = folder.appendingPathComponent("tone.mov")
        try await TestMovie.write(to:url,frames:180,amplitude:0.5) { _ in (255,0,0) }            // 6 s of a steady tone
        media = try await MediaLibrary().inspect(url)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at:folder) }

    /// The gains of the two sounds at `seconds` (the outgoing one first).
    private func gains(_ bundle: RenderBundle, at seconds: Double) -> [Float] {
        let time = CMTime(seconds:seconds,preferredTimescale:600)
        return bundle.audioMix.inputParameters.compactMap { parameters in
            var start: Float = 0, end: Float = 0, range = CMTimeRange.zero
            guard parameters.getVolumeRamp(for:time,startVolume:&start,endVolume:&end,timeRange:&range), start != end, range.duration.seconds > 0 else { return nil }
            return start+(end-start)*Float((time-range.start).seconds/range.duration.seconds)
        }.sorted(by:>)
    }
    /// The mixed level at the middle of the dissolve against before it, in decibels.
    private func swell(_ bundle: RenderBundle) throws -> Double {
        let sound = try TestMovie.mixedSound(bundle)
        return 20*log10(TestMovie.level(sound,from:2.9,to:3.1)/TestMovie.level(sound,from:1,to:2))
    }

    func testASplitClipsDissolveKeepsItsLevel() async throws {
        var project = Project(); project.media = [media]
        let left = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
        try Editing.split(left,at:.init(seconds:3),in:&project)
        let right = try XCTUnwrap(project.clips.first { $0.kind == .video && $0.start == .init(seconds:3) }).id
        try Editing.setTransition(.crossDissolve,duration:.init(seconds:1),from:left,to:right,in:&project)
        let bundle = try await builder.build(project,urls:[media.id:url])
        let middle = gains(bundle,at:3), quarter = gains(bundle,at:2.75)
        XCTAssertEqual(middle.count,2); XCTAssertEqual(middle.reduce(0,+),1,accuracy:0.01,"gains at the cut: \(middle)")
        XCTAssertEqual(quarter.reduce(0,+),1,accuracy:0.01,"gains a quarter in: \(quarter)")
        XCTAssertEqual(try swell(bundle),0,accuracy:0.5,"the level in the middle of the dissolve")
        // The exported movie as well (AAC): no swell where the halves cross.
        let movie = folder.appendingPathComponent("split-dissolve.mp4")
        try await MovieExporter().export(bundle,to:movie) { _ in }
        let sound = try await TestMovie.sound(of:movie)
        let exported = 20*log10(TestMovie.level(sound,from:2.9,to:3.1)/TestMovie.level(sound,from:1,to:2))
        XCTAssertEqual(exported,0,accuracy:0.5,"the exported level in the middle of the dissolve")
    }
    /// Different stretches of the source (not in step): the constant-power curves, as before.
    func testDifferentSoundsKeepTheConstantPowerCrossfade() async throws {
        var project = Project(); project.media = [media]
        let first = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
        try Editing.trim(first,leading:false,to:.init(seconds:3),in:&project)
        let second = try Editing.add(mediaID:media.id,lane:.v1,at:.init(seconds:3),to:&project)
        try Editing.trim(second,leading:true,to:.init(seconds:4),in:&project)                    // source from 1 s
        try Editing.move(second,to:.init(seconds:3),lane:.v1,in:&project)
        try Editing.setTransition(.crossDissolve,duration:.init(seconds:1),from:first,to:second,in:&project)
        let bundle = try await builder.build(project,urls:[media.id:url])
        let middle = gains(bundle,at:3)
        XCTAssertEqual(middle.count,2)
        for gain in middle { XCTAssertEqual(gain,Float(0.5).squareRoot(),accuracy:0.03,"gains at the cut: \(middle)") }
    }
}
