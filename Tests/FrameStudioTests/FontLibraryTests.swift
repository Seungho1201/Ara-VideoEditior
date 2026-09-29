import AppKit
import CoreImage
import CoreText
import XCTest
import FrameCore
import FrameMedia
@testable import FrameStudio

/// A font no Mac has installed, made at test time from a system font by renaming it in place
/// (same-length names, so no table moves). Nothing is added to the user's font folder: every
/// test imports into its own temporary folder, and registration is for this process only.
enum TestFont {
    static let source = URL(fileURLWithPath:"/System/Library/Fonts/Supplemental/Georgia Bold.ttf")
    /// A seven-letter family (the length of "Georgia") unique to this run, e.g. "AraQxzk".
    static func uniqueFamily() -> String {
        "Ara"+String((0..<4).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
    }
    static func make(family: String, in folder: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath:source.path) else { throw XCTSkip("Georgia Bold is not on this Mac") }
        var data = try Data(contentsOf:source)
        for (from,to) in [("Georgia".data(using:.ascii)!,family.data(using:.ascii)!),
                          ("Georgia".data(using:.utf16BigEndian)!,family.data(using:.utf16BigEndian)!)] {
            var range = data.range(of:from)
            while let found = range {
                data.replaceSubrange(found,with:to)
                range = data.range(of:from,in:found.lowerBound+to.count..<data.count)
            }
        }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let file = folder.appendingPathComponent("\(family)Bold.ttf")
        try data.write(to:file)
        return file
    }
    static func zip(_ folder: URL, to archive: URL) throws {
        let ditto = Process(); ditto.executableURL = URL(fileURLWithPath:"/usr/bin/ditto")
        ditto.arguments = ["-c","-k","--sequesterRsrc",folder.path,archive.path]
        try ditto.run(); ditto.waitUntilExit()
    }
}

final class FontLibraryTests: XCTestCase {
    private var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ara-font-tests-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:scratch) }

    func testAddedFontIsKeptRegisteredListedAndDrawn() throws {
        let family = TestFont.uniqueFamily(), folder = scratch.appendingPathComponent("Fonts")
        let original = try TestFont.make(family:family,in:scratch.appendingPathComponent("Downloads"))
        XCTAssertFalse(FontLibrary.isAvailable("\(family)-Bold"))
        let result = try FontLibrary.importFonts([original],into:folder)
        XCTAssertEqual(result.added.map(\.postScriptName),["\(family)-Bold"])
        XCTAssertEqual(result.added.first?.family,family)
        // Ara keeps its own copy: the download can go.
        try FileManager.default.removeItem(at:original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:folder.path),["\(family)Bold.ttf"])
        XCTAssertTrue(FontLibrary.isAvailable("\(family)-Bold"))
        XCTAssertTrue(FontLibrary.families().contains { $0.name == family })
        XCTAssertEqual(FontLibrary.faces(ofFamily:family).map(\.postScriptName),["\(family)-Bold"])
        XCTAssertEqual(FontLibrary.closestFace(inFamily:family,toWeight:0)?.postScriptName,"\(family)-Bold")
        XCTAssertEqual(FontLibrary.addedFaces(in:folder).map(\.postScriptName),["\(family)-Bold"])
        // A title in the added font is drawn in it, not in the default font.
        var style = ClipStyle(); style.text = "Ara 한글 Title"
        let plain = try pixels(FrameRenderer.textImage(style))
        style.fontName = "\(family)-Bold"
        XCTAssertNotEqual(try pixels(FrameRenderer.textImage(style)),plain)
    }

    func testZipArchivesAreUnpackedWithoutMacLitter() throws {
        let family = TestFont.uniqueFamily(), packed = scratch.appendingPathComponent("pack")
        _ = try TestFont.make(family:family,in:packed.appendingPathComponent("Fonts OTF"))
        try Data("x".utf8).write(to:packed.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at:packed.appendingPathComponent("__MACOSX"),withIntermediateDirectories:true)
        try Data("resource fork".utf8).write(to:packed.appendingPathComponent("__MACOSX/._\(family)Bold.ttf"))
        let archive = scratch.appendingPathComponent("\(family).zip")
        try TestFont.zip(packed,to:archive)
        let folder = scratch.appendingPathComponent("Fonts")
        let result = try FontLibrary.importFonts([archive],into:folder)
        XCTAssertEqual(result.added.map(\.postScriptName),["\(family)-Bold"])
        XCTAssertEqual(result.skipped,[])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:folder.path),["\(family)Bold.ttf"])
    }

    func testRepeatsInstalledFontsAndNonFontsAreNotAdded() throws {
        let family = TestFont.uniqueFamily(), folder = scratch.appendingPathComponent("Fonts")
        let file = try TestFont.make(family:family,in:scratch)
        _ = try FontLibrary.importFonts([file],into:folder)
        // The same file again, a font the Mac already has, and something that is not a font.
        XCTAssertThrowsError(try FontLibrary.importFonts([file],into:folder)) { XCTAssertTrue("\($0)".contains("already added")) }
        XCTAssertThrowsError(try FontLibrary.importFonts([TestFont.source],into:folder)) { XCTAssertTrue("\($0)".contains("already available")) }
        let fake = scratch.appendingPathComponent("Fake.ttf"); try Data("not a font".utf8).write(to:fake)
        XCTAssertThrowsError(try FontLibrary.importFonts([fake],into:folder))
        let empty = scratch.appendingPathComponent("empty"); try FileManager.default.createDirectory(at:empty,withIntermediateDirectories:true)
        try Data("x".utf8).write(to:empty.appendingPathComponent("readme.txt"))
        let archive = scratch.appendingPathComponent("empty.zip"); try TestFont.zip(empty,to:archive)
        XCTAssertThrowsError(try FontLibrary.importFonts([archive],into:folder)) { XCTAssertTrue("\($0)".contains("no fonts")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:folder.path),["\(family)Bold.ttf"])
    }

    func testMissingFontFallsBackToTheDefaultFont() throws {
        var style = ClipStyle(); style.text = "Fallback 한글"
        let plain = try pixels(FrameRenderer.textImage(style))
        style.fontName = "NoSuchFont-Bold"
        XCTAssertFalse(FontLibrary.isAvailable("NoSuchFont-Bold"))
        XCTAssertNil(FontLibrary.face("NoSuchFont-Bold"))
        XCTAssertEqual(try pixels(FrameRenderer.textImage(style)),plain)
    }

    @MainActor func testTitleFontIsOneUndoStepAndDroppedFontsGoToTheLibrary() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        store.fontFolder = scratch.appendingPathComponent("Fonts")
        let title = Clip(name:"Title",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3))
        store.edit("Fixture") { $0.clips = [title] }
        store.selectedClipID = title.id
        store.applyFont("Georgia-Bold")
        XCTAssertEqual(store.project.clips.first?.style.fontName,"Georgia-Bold")
        XCTAssertEqual(store.history.undoName,"Font")
        store.undo()
        XCTAssertEqual(store.project.clips.first?.style.fontName,ClipStyle.defaultFontName)
        // A dropped font file is added to the library; it never becomes media.
        let family = TestFont.uniqueFamily(), file = try TestFont.make(family:family,in:scratch)
        let revision = store.fontsRevision, media = store.project.media
        store.importFiles([file])
        XCTAssertFalse(store.isImporting)
        for _ in 0..<300 where store.isAddingFonts { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertGreaterThan(store.fontsRevision,revision)            // font menus refresh
        XCTAssertEqual(store.project.media,media)
        XCTAssertTrue(FontLibrary.isAvailable("\(family)-Bold"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:store.fontFolder.appendingPathComponent("\(family)Bold.ttf").path))
        XCTAssertTrue(FontLibrary.accepts(URL(fileURLWithPath:"/a/B.OTF")) && FontLibrary.accepts(URL(fileURLWithPath:"/a/b.zip")))
        XCTAssertFalse(FontLibrary.accepts(URL(fileURLWithPath:"/a/b.mp4")))
    }

    func testChoosingAFamilyKeepsTheTitleUprightWhateverTheLanguage() {
        // Style names come back in the user's language ("볼드 이탤릭체"); slant is read from traits.
        XCTAssertEqual(FontLibrary.closestFace(inFamily:"Georgia",toWeight:0.4)?.postScriptName,"Georgia-Bold")
        XCTAssertEqual(FontLibrary.closestFace(inFamily:"Georgia",toWeight:0)?.postScriptName,"Georgia")
        XCTAssertEqual(FontLibrary.closestFace(inFamily:"Helvetica",toWeight:0.4)?.postScriptName,"Helvetica-Bold")
        XCTAssertEqual(FontLibrary.closestFace(inFamily:"Georgia",toWeight:0.4,italic:true)?.postScriptName,"Georgia-BoldItalic")
        XCTAssertEqual(FontLibrary.face("Georgia-BoldItalic")?.isItalic,true)
        XCTAssertEqual(FontLibrary.face("Georgia-Bold")?.isItalic,false)
    }

    func testALinkedFontIsCopiedNotLinked() throws {
        let family = TestFont.uniqueFamily(), folder = scratch.appendingPathComponent("Fonts")
        let file = try TestFont.make(family:family,in:scratch.appendingPathComponent("real"))
        let link = scratch.appendingPathComponent("link.ttf")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        _ = try FontLibrary.importFonts([link],into:folder)
        let copy = folder.appendingPathComponent("\(family)Bold.ttf")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath:copy.path))
        XCTAssertEqual(try Data(contentsOf:copy),try Data(contentsOf:file))
    }

    func testTitlesKeepTheirRasterAndFancyFontsAreNotClipped() throws {
        // The default font draws exactly as before the ink-aware margin (12 px all round).
        for (text,size) in [("Your story starts here",72.0),("Two\nlines 한글 gjpqy",100),("A",8),("Wide title that wraps across the frame width at this size",300)] {
            var style = ClipStyle(); style.text = text; style.fontSize = size
            XCTAssertEqual(try pixels(FrameRenderer.textImage(style)),try pixels(legacyTextImage(style)),"\(text) at \(size)")
        }
        // Zapfino's swashes reach far outside its line metrics: nothing may touch the image edge.
        guard FontLibrary.isAvailable("Zapfino") else { throw XCTSkip("Zapfino is not on this Mac") }
        var style = ClipStyle(); style.text = "gjpqy Ara"; style.fontSize = 120; style.fontName = "Zapfino"
        let image = try FrameRenderer.textImage(style)
        let extent = image.extent.integral, width = Int(extent.width), height = Int(extent.height)
        var bytes = [UInt8](repeating:0,count:width*height*4)
        CIContext().render(image,toBitmap:&bytes,rowBytes:width*4,bounds:extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        var edge = 0
        for x in 0..<width { edge += Int(bytes[x*4+3])+Int(bytes[((height-1)*width+x)*4+3]) }
        for y in 0..<height { edge += Int(bytes[(y*width)*4+3])+Int(bytes[(y*width+width-1)*4+3]) }
        XCTAssertEqual(edge,0,"ink on the edge of the title image")
    }

    @MainActor func testAddingATitlesMissingFontRedrawsThePreview() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        store.fontFolder = scratch.appendingPathComponent("Fonts")
        let family = TestFont.uniqueFamily(), file = try TestFont.make(family:family,in:scratch)
        var title = Clip(name:"Title",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3))
        title.style.text = "Restored 한글"; title.style.fontName = "\(family)-Bold"
        store.edit("Fixture") { $0.clips = [title] }
        XCTAssertEqual(store.missingFonts,["\(family)-Bold"])
        for _ in 0..<1000 where store.isBuilding || store.player.currentItem == nil { try await Task.sleep(for:.milliseconds(10)) }
        let fallback = try XCTUnwrap(store.previewLayerImage(for:title))
        store.addFonts([file],applyToSelection:false)
        // Redrawn off the main actor, then put in the preview.
        for _ in 0..<1000 where store.isAddingFonts || store.isBuilding || store.isDrawingTitles { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(store.missingFonts,[])
        let redrawn = try XCTUnwrap(store.previewLayerImage(for:title))
        XCTAssertNotEqual(pixels(redrawn),pixels(fallback))
        XCTAssertEqual(pixels(redrawn),try pixels(FrameRenderer.textImage(title.style)))
        XCTAssertEqual(store.project.clips.first?.style.fontName,"\(family)-Bold")      // the title itself is unchanged
    }

    /// textImage as it was before fonts could draw past their metrics: a fixed 12 px margin.
    private func legacyTextImage(_ style: ClipStyle) throws -> CIImage {
        let font = CTFontCreateWithName(style.fontName as CFString,style.fontSize,nil)
        let color = CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[style.red,style.green,style.blue,1])!
        let text = NSAttributedString(string:style.text.isEmpty ? " " : style.text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):color])
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter,CFRange(location:0,length:0),nil,CGSize(width:1700,height:4000),nil)
        let width = max(8,Int(ceil(suggested.width))+24), height = max(8,Int(ceil(suggested.height))+24)
        let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        CTFrameDraw(CTFramesetterCreateFrame(framesetter,CFRange(location:0,length:0),CGPath(rect:CGRect(x:12,y:12,width:width-24,height:height-24),transform:nil),nil),context)
        return CIImage(cgImage:context.makeImage()!)
    }

    private func pixels(_ image: CIImage) -> Data {
        let extent = image.extent.integral, width = Int(extent.width), height = Int(extent.height)
        var bytes = [UInt8](repeating:0,count:width*height*4)
        CIContext().render(image,toBitmap:&bytes,rowBytes:width*4,bounds:extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        return Data(bytes)+Data("\(width)x\(height)".utf8)
    }
}
