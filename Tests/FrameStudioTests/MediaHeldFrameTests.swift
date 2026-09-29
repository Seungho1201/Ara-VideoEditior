import XCTest
@preconcurrency import AVFoundation
import CoreImage
import FrameCore
@testable import FrameMedia

/// Every video clip's stand-in first frame (and a transition's held frames) is decoded when a
/// composition is built. They are decoded a few at a time, and a later build (the rebuild after
/// an edit, a snapshot, an export) finds the ones an earlier build decoded.
final class MediaHeldFrameTests: XCTestCase {
    private var folder: URL!
    override func setUp() async throws { folder = try TestMovie.folder("held") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at:folder) }
    private func bytes(_ image: CIImage) -> [UInt8] {
        let extent = image.extent.integral
        var bytes = [UInt8](repeating:0,count:Int(extent.width)*Int(extent.height)*4)
        CIContext().render(image,toBitmap:&bytes,rowBytes:Int(extent.width)*4,bounds:extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        return bytes
    }

    func testHeldFramesMatchSingleDecodesAndAreKeptUntilTheFileChanges() async throws {
        let url = folder.appendingPathComponent("steps.mov")
        try await TestMovie.write(to:url,frames:30,audio:false) { (UInt8($0*8),0,255) }            // a different red in every frame
        let times = [0,7,7,12,29,3].map { CMTime(value:Int64($0),timescale:30) }
        let first = await SourceFrameConverter.heldFrames(times.map { (url,$0) })
        XCTAssertEqual(first.count,5,"each frame decoded once")
        for time in times {
            let decoded = await SourceFrameConverter.heldFrame(of:url,at:time)
            let single = try XCTUnwrap(decoded)
            XCTAssertEqual(bytes(try XCTUnwrap(first[HeldFrameRequest(url,time)])),bytes(CIImage(cvPixelBuffer:single)),"frame at \(time.seconds) s")
        }
        let before = SourceFrameConverter.held.lookups
        let again = await SourceFrameConverter.heldFrames(times.map { (url,$0) })
        XCTAssertEqual(SourceFrameConverter.held.lookups.found-before.found,5)
        for (request,image) in first { XCTAssertTrue(again[request] === image,"kept from the first call") }
        // The file replaced by another at the same path: read again.
        try await Task.sleep(for:.milliseconds(20))                                            // a new modification date
        try await TestMovie.write(to:url,frames:30,audio:false) { _ in (0,255,0) }
        let replaced = await SourceFrameConverter.heldFrames([(url,times[1])])
        let green = try XCTUnwrap(replaced[HeldFrameRequest(url,times[1])])
        XCTAssertFalse(green === first[HeldFrameRequest(url,times[1])])
        let pixel = bytes(green)
        XCTAssertTrue(pixel[1] > 200 && pixel[0] < 60,"the new file's frame, got \(pixel.prefix(4))")
    }
    /// A second build of the same timeline shows the first build's stand-ins without decoding.
    func testARebuildReusesTheStandIns() async throws {
        let url = folder.appendingPathComponent("clip.mov")
        try await TestMovie.write(to:url,frames:60) { (UInt8($0*4),80,200) }
        let media = try await MediaLibrary().inspect(url)
        var project = Project(); project.media = [media]
        for i in 0..<6 {
            let id = try Editing.add(mediaID:media.id,lane:.v1,at:project.duration,to:&project)
            try Editing.trim(id,leading:true,to:project.clip(id)!.start+MediaTime(ticks:project.frameRate.frame.ticks*Int64(i*7)),in:&project)
            try Editing.move(id,to:project.clips.filter { $0.id != id && $0.kind == .video }.map(\.end).max() ?? .zero,lane:.v1,in:&project)
        }
        let builder = CompositionBuilder(sentinels:SentinelStore { [folder] in folder!.appendingPathComponent("cache") })
        func standIns(_ bundle: RenderBundle) -> [CIImage] { ((bundle.videoComposition.instructions.first as? FrameInstruction)?.layers ?? []).compactMap(\.fallbackImage) }
        let first = try await builder.build(project,urls:[media.id:url])
        let before = SourceFrameConverter.held.lookups
        let second = try await builder.build(project,urls:[media.id:url])
        XCTAssertEqual(standIns(first).count,6)
        XCTAssertEqual(SourceFrameConverter.held.lookups.missed,before.missed,"nothing decoded again")
        for (a,b) in zip(standIns(first),standIns(second)) { XCTAssertTrue(a === b) }
    }
}
