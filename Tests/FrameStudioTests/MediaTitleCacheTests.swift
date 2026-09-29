import XCTest
import CoreImage
import FrameCore
@testable import FrameMedia

/// Titles are drawn on every build and on every step of a live style change. A title drawn
/// before comes back as it was, and an outline is worked out once for its letters and width:
/// colour, shadow and rotation changes reuse it. Either way the pixels are exactly those of a
/// fresh drawing.
final class MediaTitleCacheTests: XCTestCase {
    private func style() -> ClipStyle {
        var s = ClipStyle(); s.text = "Ara 외곽선 gjpq"; s.fontSize = 48
        s.outlineWidth = 6; s.outlineRed = 1; s.shadowOpacity = 0.8; s.shadowDistance = 10; s.shadowBlur = 6; s.shadowBlue = 1
        return s
    }
    private func pixels(_ image: CIImage) -> Data {
        let extent = image.extent.integral, width = Int(extent.width), height = Int(extent.height)
        var bytes = [UInt8](repeating:0,count:width*height*4)
        CIContext().render(image,toBitmap:&bytes,rowBytes:width*4,bounds:extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        return Data(bytes)+Data("\(width)x\(height)".utf8)
    }
    private func forget() { FrameRenderer.titles.removeAll(); FrameRenderer.outlines.removeAll() }

    func testKeptTitlesAndOutlinesDrawExactlyAsFreshOnes() throws {
        let changes: [(String,(inout ClipStyle) -> Void)] = [
            ("text colour",{ $0.red = 0.2; $0.green = 0.8 }),
            ("outline colour",{ $0.outlineGreen = 1 }),
            ("shadow distance",{ $0.shadowDistance = 27 }),              // a wider margin around the letters
            ("shadow blur",{ $0.shadowBlur = 19 }),
            ("rotation",{ $0.rotation = 33 }),
        ]
        for scale in [1,4.0/3,2] as [CGFloat] {
            forget()
            let original = style(), first = try FrameRenderer.textImage(original,scale:scale)
            XCTAssertTrue(try FrameRenderer.textImage(original,scale:scale) === first,"the same title again at \(scale)x")
            for (name,change) in changes {
                var changed = original; change(&changed)
                let outlines = FrameRenderer.outlines.lookups
                let kept = try FrameRenderer.textImage(changed,scale:scale)
                // A whole scale reuses the outline whatever the margin; a fractional one while the margin stays.
                if scale.rounded() == scale || !["shadow distance","shadow blur"].contains(name) {
                    XCTAssertEqual(FrameRenderer.outlines.lookups.found,outlines.found+1,"\(name) at \(scale)x reuses the outline")
                }
                forget()
                XCTAssertEqual(pixels(kept),pixels(try FrameRenderer.textImage(changed,scale:scale)),"\(name) at \(scale)x")
                _ = try FrameRenderer.textImage(original,scale:scale)            // the original's outline, kept again
            }
            // A new outline width is a new outline.
            var wider = original; wider.outlineWidth = 9
            let outlines = FrameRenderer.outlines.lookups
            _ = try FrameRenderer.textImage(wider,scale:scale)
            XCTAssertEqual(FrameRenderer.outlines.lookups.missed,outlines.missed+1)
        }
    }
    /// A subtitled timeline: the rebuild after an edit draws no title again.
    func testARebuildDrawsNoTitleAgain() async throws {
        var project = Project()
        project.clips = (0..<20).map { i in
            var clip = Clip(name:"Sub \(i)",kind:.text,lane:.v2,start:.init(seconds:Double(i)*3),duration:.init(seconds:3))
            clip.style.text = "자막 \(i)번 subtitle"; clip.style.fontSize = 60; clip.style.outlineWidth = 4; clip.style.shadowOpacity = 0.6
            return clip
        }
        let folder = try TestMovie.folder("titles"); defer { try? FileManager.default.removeItem(at:folder) }
        let builder = CompositionBuilder(sentinels:SentinelStore { folder })
        let first = try await builder.build(project,urls:[:])
        let before = FrameRenderer.titles.lookups
        project.clips[3].start = .init(seconds:70)                                   // an edit that changes no title
        let second = try await builder.build(project,urls:[:])
        XCTAssertEqual(FrameRenderer.titles.lookups.missed,before.missed)
        XCTAssertEqual(FrameRenderer.titles.lookups.found,before.found+20)
        let images = { (bundle: RenderBundle) in ((bundle.videoComposition.instructions.first as? FrameInstruction)?.layers ?? []).compactMap(\.image) }
        XCTAssertEqual(Set(images(first).map(ObjectIdentifier.init)),Set(images(second).map(ObjectIdentifier.init)))
    }
}
