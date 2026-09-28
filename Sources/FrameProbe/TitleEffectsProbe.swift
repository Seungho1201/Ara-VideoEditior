import Foundation
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import FrameCore
import FrameMedia

extension FrameProbe {
    /// Outlined and shadowed titles through the real pipeline, in Full HD and in 4K: drawn, in
    /// the same place at both sizes, drawn at 4K rather than enlarged, and exported as snapshotted.
    static func titleEffectsSmoke(fixtures: URL, output: URL) async throws {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let still = fixtures.appendingPathComponent("still.png"), media = try await MediaLibrary().inspect(still)
        var project = Project(); project.name = "Title Effects Validation"; project.media = [media]
        let background = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
        try Editing.trim(background,leading:false,to:.init(seconds:2),in:&project)
        let title = try Editing.addText(at:.zero,to:&project)
        try Editing.trim(title,leading:false,to:.init(seconds:2),in:&project)
        let index = project.clips.firstIndex { $0.id == title }!
        project.clips[index].style.text = "Ara 외곽선 그림자\ngjpqy Title"; project.clips[index].style.fontSize = 110
        let plain = try project.validated()
        project.clips[index].style.outlineWidth = 6; project.clips[index].style.outlineRed = 1
        project.clips[index].style.shadowOpacity = 0.9; project.clips[index].style.shadowDistance = 14
        project.clips[index].style.shadowBlur = 4; project.clips[index].style.shadowBlue = 1
        project = try project.validated()
        let file = output.appendingPathComponent("title-effects.framestudio")
        try ProjectFile.encode(project).write(to:file)
        let reopened = try ProjectFile.decode(Data(contentsOf:file))
        try require(reopened == project && reopened.clips[index].style.hasOutline && reopened.clips[index].style.hasShadow,"outline and shadow survive save and reopen")

        let builder = CompositionBuilder(), snapshots = SnapshotExporter(), at = MediaTime(seconds:1)
        func snapshot(_ p: Project, height: Int, _ name: String) async throws -> CGImage {
            let data = try await snapshots.png(try await builder.build(p,urls:[media.id:still],height:height),at:at)
            try data.write(to:output.appendingPathComponent(name))
            return CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData,nil)!,0,nil)!
        }
        let hd = try await snapshot(reopened,height:1080,"effects-1080.png"), uhd = try await snapshot(reopened,height:2160,"effects-2160.png")
        let bare = try await snapshot(plain,height:1080,"plain-1080.png")
        try require(uhd.width == 3840 && uhd.height == 2160,"a 4K snapshot is 3840×2160")
        let drawn = meanDifference(hd,bare), placed = meanDifference(uhd,hd)
        try require(drawn > 0.003,"the outline and shadow are drawn (difference from the plain title \(drawn))")
        try require(placed < 0.004,"the 4K title sits where the Full HD one does (difference \(placed))")
        // Colours where they belong: red outline, blue shadow below and right of the letters.
        let full = fullPixels(uhd)
        func centroid(_ test: (Int,Int,Int) -> Bool) -> (x: Double, y: Double, n: Int) {
            var sx = 0.0, sy = 0.0, n = 0
            for y in 0..<uhd.height { for x in 0..<uhd.width {
                let i = (y*uhd.width+x)*4
                if test(Int(full[i]),Int(full[i+1]),Int(full[i+2])) { sx += Double(x); sy += Double(y); n += 1 }
            } }
            return (sx/Double(max(n,1)),sy/Double(max(n,1)),n)
        }
        let letters = centroid { $0 > 245 && $1 > 245 && $2 > 245 }, outline = centroid { $0 > 220 && $1 < 40 && $2 < 40 }
        // Blending is in linear light: a 90 % blue shadow over the green still keeps some green.
        let shadow = centroid { $0 < 40 && $2 > 200 && $2 > $1+120 }
        try require(letters.n > 5000 && outline.n > 5000 && shadow.n > 2000,"4K letters (\(letters.n) px), outline (\(outline.n) px) and shadow (\(shadow.n) px) are visible")
        try require(shadow.x > letters.x+5 && shadow.y > letters.y+5,"the shadow falls down and to the right")

        // Sharpness: a title's soft rim is about one pixel wide when drawn at the output's size, so
        // 4K doubles it (twice the edge length); an enlarged 1080 title would quadruple it.
        var lone = Project(); lone.clips = plain.clips.filter { $0.kind == .text }
        lone = try lone.validated()
        let loneHD = try await snapshot(lone,height:1080,"title-1080.png"), loneUHD = try await snapshot(lone,height:2160,"title-2160.png")
        func soft(_ image: CGImage) -> Int { let p = fullPixels(image); return stride(from:0,to:p.count,by:4).filter { p[$0+1] > 20 && p[$0+1] < 235 }.count }
        let ratio = Double(soft(loneUHD))/Double(max(1,soft(loneHD)))
        try require(ratio < 2.6,"the 4K title is drawn at 4K, not enlarged (soft rim ×\(String(format:"%.2f",ratio)) of Full HD)")

        let movie = output.appendingPathComponent("title-effects-4k.mp4")
        try await MovieExporter().export(try await builder.build(reopened,urls:[media.id:still],height:2160),to:movie) { _ in }
        let generator = AVAssetImageGenerator(asset:AVURLAsset(url:movie))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let exported = try await generator.image(at:at.cmTime).image
        let parity = meanDifference(exported,uhd)
        try require(exported.width == 3840 && parity < 0.01,"the 4K export matches the 4K snapshot (difference \(parity))")
        print("PASS title outline and shadow: drawn (\(String(format:"%.4f",drawn))), same place at 4K (\(String(format:"%.4f",placed))), drawn at 4K (rim ×\(String(format:"%.2f",ratio))), 4K export matches snapshot (\(String(format:"%.4f",parity))), survives save")
    }

    /// Every pixel of an image, as sRGB RGBA bytes with the top row first.
    static func fullPixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating:0,count:image.width*image.height*4)
        let context = CGContext(data:&bytes,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        return bytes
    }
}
