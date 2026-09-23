import Foundation
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import FrameCore
import FrameMedia

extension FrameProbe {
    /// Midtones reveal transfer-curve mistakes that saturated red/blue fixtures miss.
    static func snapshotColorChart(output:URL) throws -> URL {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let context = CGContext(data:nil,width:1920,height:1080,bitsPerComponent:8,bytesPerRow:0,
                                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        for row in 0..<6 {
            for column in 0..<16 {
                let gray = CGFloat(column+1)/17
                let r = row == 0 ? gray : gray*CGFloat(row+1)/6
                let g = row == 0 ? gray : gray*CGFloat(7-row)/7
                let b = row == 0 ? gray : gray*0.7
                context.setFillColor(red:r,green:g,blue:b,alpha:1)
                context.fill(CGRect(x:column*120,y:row*180,width:120,height:180))
            }
        }
        let url = output.appendingPathComponent("midtone-chart.png")
        try png(context.makeImage()!,to:url)
        return url
    }

    static func snapshotRoundTrip(source:URL, output:URL) async throws {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let library = MediaLibrary(), builder = CompositionBuilder(), snapshots = SnapshotExporter()
        var project = Project()
        let media = try await library.inspect(source)
        project.media = [media]
        _ = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
        var bundle = try await builder.build(project,urls:[media.id:source])
        var time = media.kind == .video ? project.snapshotTime(at:.init(seconds:1.6))! : .zero
        let generator = AVAssetImageGenerator(asset:bundle.composition)
        generator.videoComposition = bundle.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let original = try await generator.image(at:time.cmTime).image
        try png(original,to:output.appendingPathComponent("original.png"))
        try require(original.colorSpace == FrameRenderer.outputColorSpace,"rendered frame profile agrees with compositor output space")
        var differences: [Double] = []
        for generation in 1...3 {
            let url = output.appendingPathComponent("snapshot-generation-\(generation).png")
            try await snapshots.export(bundle,at:time,to:url)
            guard let input = CIImage(contentsOf:url) else { throw EditError("Cannot load captured PNG") }
            try require(input.colorSpace == CGColorSpace(name:CGColorSpace.sRGB),"snapshot is converted to sRGB")
            let still = try await library.inspect(url)
            var next = Project(); next.media = [still]
            let clipID = try Editing.add(mediaID:still.id,lane:.v1,at:.zero,to:&next)
            try Editing.trim(clipID,leading:false,to:.init(seconds:1),in:&next)
            bundle = try await builder.build(next,urls:[still.id:url]); time = .zero
            let frame = AVAssetImageGenerator(asset:bundle.composition); frame.videoComposition = bundle.videoComposition
            frame.requestedTimeToleranceBefore = .zero; frame.requestedTimeToleranceAfter = .zero
            let result = try await frame.image(at:.zero).image
            try png(result,to:output.appendingPathComponent("reimported-generation-\(generation).png"))
            let difference = meanDifference(original,result)
            differences.append(difference)
            let channelErrors = zip(pixels(original),pixels(result)).enumerated().filter { $0.offset%4 != 3 }
                .map { abs(Int($0.element.0)-Int($0.element.1)) }.sorted()
            let p99 = channelErrors[channelErrors.count*99/100]
            try require(p99 <= 2,"round-trip 99th percentile channel error: \(p99)/255")
            print("PASS round trip \(generation): mean sRGB difference = \(difference), p99 error = \(p99)/255")
            if generation == 1 {
                let movie = output.appendingPathComponent("reimported.mp4")
                try await MovieExporter().export(bundle,to:movie) { _ in }
                let encoded = AVAssetImageGenerator(asset:AVURLAsset(url:movie))
                let encodedFrame = try await encoded.image(at:.zero).image
                let difference = meanDifference(original,encodedFrame)
                try require(difference < 0.006,"reimported snapshot MP4 preserves color: \(difference)")
                print("PASS reimported snapshot MP4: mean sRGB difference = \(difference)")
            }
        }
        try require(differences.allSatisfy { $0 < 0.0015 },"snapshot reimport should preserve colors: \(differences)")
        try Data("Three generations and MP4 passed. Differences: \(differences)\n".utf8).write(to:output.appendingPathComponent("roundtrip-result.txt"))
    }
}
