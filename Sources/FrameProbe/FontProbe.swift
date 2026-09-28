import Foundation
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import FrameCore
import FrameMedia

extension FrameProbe {
    /// Titles in an added font, through the real pipeline. The font comes from `fonts` (font
    /// files or ZIPs, e.g. a downloaded family), or, with none given, is made from a system font
    /// renamed in place so no Mac has it. Fonts go into a scratch folder, never the app's.
    static func fontSmoke(fonts given: [URL], fixtures: URL, output: URL) async throws {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let folder = output.appendingPathComponent("added-fonts",isDirectory:true)
        try? FileManager.default.removeItem(at:folder)
        let sources = given.isEmpty ? [try probeFont(in:output)] : given
        let imported = try FontLibrary.importFonts(sources,into:folder)
        print("PASS fonts added: \(imported.added.map { "\($0.postScriptName) (\($0.familyDisplayName) · \($0.style))" }.joined(separator:", "))")
        try require(FontLibrary.addedFaces(in:folder).count == imported.added.count,"added faces are registered")
        let face = imported.added.max { abs($0.weight-0.4) > abs($1.weight-0.4) }!          // the boldest-looking face
        try require(FontLibrary.closestFace(inFamily:face.family,toWeight:0.4)?.postScriptName == face.postScriptName,"closest weight picks \(face.postScriptName)")

        let still = fixtures.appendingPathComponent("still.png"), media = try await MediaLibrary().inspect(still)
        var project = Project(); project.name = "Font Validation"; project.media = [media]
        let background = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
        try Editing.trim(background,leading:false,to:.init(seconds:2),in:&project)
        let title = try Editing.addText(at:.zero,to:&project)
        try Editing.trim(title,leading:false,to:.init(seconds:2),in:&project)
        let index = project.clips.firstIndex { $0.id == title }!
        project.clips[index].style.text = "G마켓 산스 Ara 2026\ngjpqy 한글"; project.clips[index].style.fontSize = 120
        project.clips[index].style.fontName = face.postScriptName
        project = try project.validated()
        let file = output.appendingPathComponent("font-title.framestudio")
        try ProjectFile.encode(project).write(to:file)
        let reopened = try ProjectFile.decode(Data(contentsOf:file))
        try require(reopened == project && reopened.clips[index].style.fontName == face.postScriptName,"the title's font survives save and reopen")

        // Descenders and swashes can reach past a font's line metrics: none may be cut off at the
        // edge of the title's image.
        let raster = try FrameRenderer.textImage(project.clips[index].style)
        let edgeInk = try edgeAlpha(raster)
        try require(edgeInk == 0,"the title in \(face.postScriptName) is not clipped at its image edge (edge alpha \(edgeInk))")
        let builder = CompositionBuilder(), snapshots = SnapshotExporter(), exporter = MovieExporter()
        let at = MediaTime(seconds:1)
        func snapshot(_ p: Project, _ name: String) async throws -> CGImage {
            let data = try await snapshots.png(try await builder.build(p,urls:[media.id:still]),at:at)
            try data.write(to:output.appendingPathComponent(name))
            return CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData,nil)!,0,nil)!
        }
        let added = try await snapshot(reopened,"font-title.png")
        var plain = reopened; plain.clips[index].style.fontName = ClipStyle.defaultFontName
        let standard = try await snapshot(plain,"font-default.png")
        var missing = reopened; missing.clips[index].style.fontName = "NoSuchFont-Bold"
        let fallback = try await snapshot(missing,"font-missing.png")
        let changed = meanDifference(added,standard), fell = meanDifference(fallback,standard)
        try require(changed > 0.002,"the added font is drawn, not the default (difference \(changed))")
        try require(fell < 0.0005,"a missing font falls back to the default font (difference \(fell))")
        // Export draws the same title as the snapshot.
        let movie = output.appendingPathComponent("font-title.mp4")
        try await exporter.export(try await builder.build(reopened,urls:[media.id:still]),to:movie) { _ in }
        let generator = AVAssetImageGenerator(asset:AVURLAsset(url:movie))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let exported = try await generator.image(at:at.cmTime).image
        let parity = meanDifference(exported,added)
        try require(parity < 0.01,"the exported title matches the snapshot (difference \(parity))")
        print("PASS title in \(face.postScriptName): drawn (vs default \(changed)), missing font falls back (\(fell)), export matches snapshot (\(parity)), survives save")
    }

    /// Summed alpha of the outermost rows and columns of an image.
    static func edgeAlpha(_ image: CIImage) throws -> Int {
        let extent = image.extent.integral, width = Int(extent.width), height = Int(extent.height)
        var bytes = [UInt8](repeating:0,count:width*height*4)
        CIContext().render(image,toBitmap:&bytes,rowBytes:width*4,bounds:extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        var sum = 0
        for x in 0..<width { sum += Int(bytes[x*4+3])+Int(bytes[((height-1)*width+x)*4+3]) }
        for y in 0..<height { sum += Int(bytes[(y*width)*4+3])+Int(bytes[(y*width+width-1)*4+3]) }
        return sum
    }
    /// Georgia Bold renamed "Aratype" in place (same-length names, so no table moves): a real,
    /// valid font that no Mac has installed, made fresh for each run and never distributed.
    static func probeFont(in folder: URL) throws -> URL {
        var data = try Data(contentsOf:URL(fileURLWithPath:"/System/Library/Fonts/Supplemental/Georgia Bold.ttf"))
        for (from,to) in [("Georgia".data(using:.ascii)!,"Aratype".data(using:.ascii)!),
                          ("Georgia".data(using:.utf16BigEndian)!,"Aratype".data(using:.utf16BigEndian)!)] {
            var range = data.range(of:from)
            while let found = range {
                data.replaceSubrange(found,with:to)
                range = data.range(of:from,in:found.lowerBound+to.count..<data.count)
            }
        }
        let file = folder.appendingPathComponent("AratypeBold.ttf")
        try data.write(to:file)
        return file
    }
}
