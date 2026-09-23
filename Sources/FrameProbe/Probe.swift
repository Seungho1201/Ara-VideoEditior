import Foundation
import FrameCore
import FrameMedia
@preconcurrency import AVFoundation
import CoreImage
import ImageIO

actor ProgressFlag {
    var started = false
    func mark(_ value:Double) { if value > 0.005 { started = true } }
}

@main struct FrameProbe {
    static func require(_ condition:Bool,_ message:String) throws { if !condition { throw EditError("CHECK FAILED: "+message) } }
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count >= 4, args[1] == "snapshot-roundtrip" {
            let output = URL(fileURLWithPath:args[3],isDirectory:true)
            let source = args[2] == "--chart" ? try snapshotColorChart(output:output) : URL(fileURLWithPath:args[2])
            try await snapshotRoundTrip(source:source,output:output); return
        }
        guard args.count >= 4, ["smoke","snapshot"].contains(args[1]) else {
            print("Usage: FrameProbe <smoke|snapshot> <fixture-directory> <output-directory>\n       FrameProbe snapshot-roundtrip <media-file|--chart> <output-directory>"); return
        }
        let fixtures = URL(fileURLWithPath:args[2],isDirectory:true), output = URL(fileURLWithPath:args[3],isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        if args[1] == "snapshot" { try await snapshotSmoke(fixtures:fixtures,output:output); return }
        let library = MediaLibrary(), builder = CompositionBuilder(), exporter = MovieExporter()
        var project = Project(); project.name = "Frame Studio Validation"
        var urls: [UUID:URL] = [:]
        for name in ["base.mp4","overlay.mp4","still.png","tone.wav"] {
            let url = fixtures.appendingPathComponent(name), media = try await library.inspect(url)
            project.media.append(media); urls[media.id] = url
            let analysis = try await library.analyze(media,at:url)
            try require(media.kind == .audio || analysis.thumbnail != nil,"thumbnail \(name)")
            try require(!media.hasAudio || !analysis.peaks.isEmpty,"waveform \(name)")
            try require(media.bookmark != nil,"bookmark \(name)")
            try require(MediaPaths.resolve(media).url.standardizedFileURL == url.standardizedFileURL,"bookmark resolution")
            try require(!MediaPaths.resolve(media).needsRelink,"own bookmark retains access")
            var unscoped = media; unscoped.bookmark = Data([1,2,3])
            try require(MediaPaths.resolve(unscoped).needsRelink,"invalid bookmark requires relinking")
            print("PASS import / analysis / bookmark: \(name)")
        }
        let base = try Editing.add(mediaID:project.media[0].id,lane:.v1,at:.zero,to:&project)
        for i in project.clips.indices { project.clips[i].style.volume = 0.25 }
        try Editing.split(base,at:.init(seconds:3),in:&project)
        let right = project.clips.first { $0.kind == .video && $0.start == .init(seconds:3) }!
        try Editing.trim(right.id,leading:true,to:.init(seconds:3.5),in:&project)
        try Editing.move(right.id,to:.init(seconds:4),lane:.v1,in:&project)
        let overlay = try Editing.add(mediaID:project.media[1].id,lane:.v2,at:.init(seconds:1),to:&project)
        for i in project.clips.indices where project.clips[i].linkID == project.clips.first(where:{$0.id == overlay})!.linkID {
            project.clips[i].style.scale = 0.5; project.clips[i].style.x = 0.2; project.clips[i].style.rotation = 12
            project.clips[i].style.opacity = 0.75; project.clips[i].style.brightness = 0.05
            project.clips[i].style.contrast = 1.1; project.clips[i].style.saturation = 0.7; project.clips[i].style.muted = true
        }
        let title = try Editing.addText(at:.init(seconds:3),to:&project)
        let titleIndex = project.clips.firstIndex { $0.id == title }!
        project.clips[titleIndex].style.text = "FRAME STUDIO"; project.clips[titleIndex].style.fontSize = 100
        project.clips[titleIndex].style.y = 0.25; project.clips[titleIndex].style.red = 0.4; project.clips[titleIndex].style.green = 1; project.clips[titleIndex].style.blue = 0.75
        let still = try Editing.add(mediaID:project.media[2].id,lane:.v2,at:.init(seconds:6),to:&project)
        try Editing.trim(still,leading:false,to:.init(seconds:6.5),in:&project)
        let file = output.appendingPathComponent("Validation.framestudio")
        try ProjectFile.encode(project).write(to:file,options:.atomic)
        let reopened = try ProjectFile.decode(Data(contentsOf:file)); try require(project == reopened,"save / reopen equality")
        let bundle = try await builder.build(reopened,urls:urls)
        let movie = output.appendingPathComponent("validation-1080.mp4")
        try await exporter.export(bundle,to:movie) { value in if value == 1 { print("PASS 1080p export completed") } }
        let asset = AVURLAsset(url:movie)
        let outputDuration = try await asset.load(.duration)
        let outputTrack = try await asset.loadTracks(withMediaType:.video).first!
        let size = try await outputTrack.load(.naturalSize), fps = try await outputTrack.load(.nominalFrameRate)
        try require(size == CGSize(width:1920,height:1080),"1080p resolution")
        try require(abs(outputDuration.seconds-6.5)<0.04,"duration: \(outputDuration.seconds)")
        try require(abs(fps-30)<0.01,"frame rate: \(fps)")
        try require(!(try await asset.loadTracks(withMediaType:.audio)).isEmpty,"AAC audio stream")
        for second in [0.5,1.5,3.5,4.5,6.25] {
            let preview = AVAssetImageGenerator(asset:bundle.composition); preview.videoComposition = bundle.videoComposition
            preview.requestedTimeToleranceBefore = .zero; preview.requestedTimeToleranceAfter = .zero
            let encoded = AVAssetImageGenerator(asset:asset); encoded.requestedTimeToleranceBefore = .zero; encoded.requestedTimeToleranceAfter = .zero
            let time = project.frameRate.quantize(.init(seconds:second)).cmTime
            let first = try await preview.image(at:time).image, secondImage = try await encoded.image(at:time).image
            let difference = meanDifference(first,secondImage)
            try require(difference < 0.035,"preview / output difference \(difference) at \(second)")
            try png(secondImage,to:output.appendingPathComponent("frame-\(second).png"))
            print("PASS preview/export frame \(second)s, mean normalized difference \(difference)")
        }
        do { _ = try await builder.build(project,urls:[:]); throw EditError("Missing-media validation did not fail") }
        catch let error as EditError { try require(error.message.contains("Missing media"),"missing-media diagnostic") }
        print("PASS missing media fails explicitly")
        // Undecodable media must still be refused, and for the stated reason rather than any error.
        do { _ = try await library.inspect(fixtures.appendingPathComponent("invalid.mov")); throw EditError("Unexpected acceptance of invalid.mov") }
        catch let error as EditError {
            try require(!error.message.contains("Unexpected acceptance"),"invalid.mov must be refused")
            try require(error.message.contains("Unsupported or protected media"),"invalid.mov diagnostic: \(error.message)")
            print("PASS rejected invalid.mov: \(error.message)")
        }
        // HDR is accepted and tone-mapped to SDR Rec.709 instead of refused.
        let hdrURL = fixtures.appendingPathComponent("hdr.mp4")
        let hdrMedia = try await library.inspect(hdrURL)
        try require(hdrMedia.kind == .video,"hdr.mp4 imports as video")
        var hdrProject = Project(); hdrProject.media = [hdrMedia]
        let hdrClip = try Editing.add(mediaID:hdrMedia.id,lane:.v1,at:.zero,to:&hdrProject)
        try Editing.trim(hdrClip,leading:false,to:.init(seconds:1),in:&hdrProject)
        let hdrBundle = try await builder.build(hdrProject,urls:[hdrMedia.id:hdrURL])
        let hdrMovie = output.appendingPathComponent("validation-hdr.mp4")
        try await exporter.export(hdrBundle,to:hdrMovie) { _ in }
        let hdrAsset = AVURLAsset(url:hdrMovie)
        let hdrTrack = try await hdrAsset.loadTracks(withMediaType:.video).first!
        for format in try await hdrTrack.load(.formatDescriptions) {
            let transfer = CMFormatDescriptionGetExtension(format,extensionKey:kCMFormatDescriptionExtension_TransferFunction) as? String
            try require(transfer == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String),"HDR export is tagged Rec.709, got \(transfer ?? "nil")")
        }
        // The decoder primes for a few frames on an HDR source; the clip's first frame must still
        // carry picture rather than going black or aborting the render.
        let hdrGen = AVAssetImageGenerator(asset:hdrAsset)
        hdrGen.requestedTimeToleranceBefore = .zero; hdrGen.requestedTimeToleranceAfter = .zero
        let firstHDR = pixels(try await hdrGen.image(at:.zero).image)
        let firstLuma = stride(from:0,to:firstHDR.count,by:4).reduce(0.0) { $0 + Double(firstHDR[$1]) + Double(firstHDR[$1+1]) + Double(firstHDR[$1+2]) } / Double(160*90*3)
        try require(firstLuma > 8,"HDR first frame is not black, mean \(firstLuma)")
        print("PASS HDR import tone-mapped to SDR Rec.709, first frame mean \(Int(firstLuma))")
        var imageProject = Project(); imageProject.media = [project.media[2]]
        let imageID = try Editing.add(mediaID:project.media[2].id,lane:.v1,at:.zero,to:&imageProject)
        try Editing.trim(imageID,leading:false,to:.init(seconds:1),in:&imageProject)
        _ = try Editing.addText(at:.zero,to:&imageProject)
        let text = imageProject.clips.first { $0.kind == .text }!
        try Editing.trim(text.id,leading:false,to:.init(seconds:1),in:&imageProject)
        let fourK = try await builder.build(imageProject,urls:urls,height:2160)
        try await exporter.export(fourK,to:output.appendingPathComponent("validation-4k.mp4")) { _ in }
        print("PASS 4K image + text + silent AAC export")
        var audioProject = Project(); audioProject.media = [project.media[3]]
        let audioID = try Editing.add(mediaID:project.media[3].id,lane:.a1,at:.zero,to:&audioProject)
        try Editing.trim(audioID,leading:false,to:.init(seconds:1),in:&audioProject)
        let audioBundle = try await builder.build(audioProject,urls:urls)
        try await exporter.export(audioBundle,to:output.appendingPathComponent("validation-audio-only.mp4")) { _ in }
        print("PASS audio-only timeline export")
        var fractional = Project(); fractional.frameRate = .init(30000,1001); fractional.media = [project.media[2]]
        let fractionalID = try Editing.add(mediaID:project.media[2].id,lane:.v1,at:.zero,to:&fractional)
        try Editing.trim(fractionalID,leading:false,to:.init(ticks:fractional.frameRate.frame.ticks*31),in:&fractional)
        let fractionalBundle = try await builder.build(fractional,urls:urls)
        try await exporter.export(fractionalBundle,to:output.appendingPathComponent("validation-2997.mp4")) { _ in }
        print("PASS 30000/1001 fps, 31-frame export")
        let blockedDestination = output.appendingPathComponent("blocked.mp4",isDirectory:true)
        try FileManager.default.createDirectory(at:blockedDestination,withIntermediateDirectories:true)
        let sentinel = blockedDestination.appendingPathComponent("keep.txt")
        try Data("preserve".utf8).write(to:sentinel)
        do {
            try await exporter.export(audioBundle,to:blockedDestination) { _ in }
            throw EditError("Unexpected success replacing a directory")
        } catch is POSIXError { }
        try require(try String(contentsOf:sentinel,encoding:.utf8) == "preserve","failed export preserves destination")
        try FileManager.default.removeItem(at:blockedDestination)
        print("PASS failed export preserves destination and removes working files")
        try Editing.trim(imageID,leading:false,to:.init(seconds:60),in:&imageProject)
        let longBundle = try await builder.build(imageProject,urls:urls)
        let cancellationURL = output.appendingPathComponent("cancelled.mp4")
        let flag = ProgressFlag()
        let task = Task { try await exporter.export(longBundle,to:cancellationURL) { value in await flag.mark(value) } }
        for _ in 0..<500 { if await flag.started { break }; try await Task.sleep(for:.milliseconds(10)) }
        try require(await flag.started,"export began before cancellation")
        task.cancel()
        do { try await task.value; throw EditError("Cancellation did not stop export") } catch is CancellationError {}
        try require(!FileManager.default.fileExists(atPath:cancellationURL.path),"cancelled final file removed")
        try require(!(try FileManager.default.contentsOfDirectory(atPath:output.path)).contains(where:{$0.contains("partial") || $0.hasSuffix(".work")}),"temporary files removed")
        print("PASS running export cancellation and cleanup")
        try Data("All media smoke checks passed.\n".utf8).write(to:output.appendingPathComponent("smoke-result.txt"))
    }
    static func png(_ image:CGImage,to url:URL) throws {
        guard let target = CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil) else { throw EditError("Cannot write PNG") }
        CGImageDestinationAddImage(target,image,nil); try require(CGImageDestinationFinalize(target),"PNG saved")
    }
    static func pixels(_ image:CGImage) -> [UInt8] {
        var data = [UInt8](repeating:0,count:160*90*4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data:bytes.baseAddress,width:160,height:90,bitsPerComponent:8,bytesPerRow:160*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image,in:CGRect(x:0,y:0,width:160,height:90))
        }
        return data
    }
    static func meanDifference(_ a:CGImage,_ b:CGImage) -> Double {
        let first = pixels(a), second = pixels(b)
        return zip(first,second).enumerated().filter { $0.offset%4 != 3 }.reduce(0.0) { $0+Double(abs(Int($1.element.0)-Int($1.element.1))) } / Double(160*90*3*255)
    }
}
