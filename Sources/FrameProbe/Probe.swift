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
        // A rotated (portrait) source must render the way its preferred transform shows it, not upside down.
        let rotatedURL = fixtures.appendingPathComponent("rotated.mp4")
        let rotatedMedia = try await library.inspect(rotatedURL)
        try require(rotatedMedia.width < rotatedMedia.height,"rotated fixture imports as portrait")
        var rotatedProject = Project(); rotatedProject.media = [rotatedMedia]
        _ = try Editing.add(mediaID:rotatedMedia.id,lane:.v1,at:.zero,to:&rotatedProject)
        let rotatedBundle = try await builder.build(rotatedProject,urls:[rotatedMedia.id:rotatedURL])
        let at = CMTime(seconds:1,preferredTimescale:600)
        let composed = AVAssetImageGenerator(asset:rotatedBundle.composition); composed.videoComposition = rotatedBundle.videoComposition
        composed.requestedTimeToleranceBefore = .zero; composed.requestedTimeToleranceAfter = .zero
        let upright = AVAssetImageGenerator(asset:AVURLAsset(url:rotatedURL)); upright.appliesPreferredTrackTransform = true
        upright.requestedTimeToleranceBefore = .zero; upright.requestedTimeToleranceAfter = .zero
        let canvasFrame = try await composed.image(at:at).image, reference = try await upright.image(at:at).image
        let fit = min(Double(canvasFrame.width)/Double(reference.width),Double(canvasFrame.height)/Double(reference.height))
        let box = CGRect(x:(Double(canvasFrame.width)-Double(reference.width)*fit)/2,y:(Double(canvasFrame.height)-Double(reference.height)*fit)/2,
                         width:Double(reference.width)*fit,height:Double(reference.height)*fit).integral
        let shown = canvasFrame.cropping(to:box)!
        let turned: CGImage = {
            let c = CGContext(data:nil,width:reference.width,height:reference.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.translateBy(x:CGFloat(reference.width),y:CGFloat(reference.height)); c.rotate(by:.pi)
            c.draw(reference,in:CGRect(x:0,y:0,width:reference.width,height:reference.height)); return c.makeImage()! }()
        let asShown = meanDifference(shown,reference), ifFlipped = meanDifference(shown,turned)
        try require(asShown < 0.02 && asShown < ifFlipped,"rotated source renders upright (difference \(asShown), upside down would be \(ifFlipped))")
        print("PASS rotated portrait source renders upright (difference \(asShown))")
        // Sources above FHD are previewed from a 1080p proxy: same timing, colour tags and
        // orientation, and a preview built from it matches one built from the original.
        try require(!ProxyMaker.wantsProxy(width:1920,height:1080) && !ProxyMaker.wantsProxy(width:1080,height:1920)
                    && ProxyMaker.wantsProxy(width:3840,height:2160) && ProxyMaker.wantsProxy(width:2160,height:3840),"only sources above FHD want a proxy")
        try require(ProxyMaker.proxySize(for:CGSize(width:4096,height:2160)) == CGSize(width:1920,height:1012),"DCI 4K proxies to an even 1920 wide")
        let fhdURL = fixtures.appendingPathComponent("base.mp4")
        try require(try await ProxyMaker.make(from:fhdURL) == nil,"a source within FHD gets no proxy")
        let bigURL = fixtures.appendingPathComponent("hlg4k.mov")
        let bigMedia = try await library.inspect(bigURL)
        try? FileManager.default.removeItem(at:ProxyMaker.url(for:bigURL))
        guard let proxyURL = try await ProxyMaker.make(from:bigURL) else { throw EditError("CHECK FAILED: 4K source made no proxy") }
        let bigTrack = try await AVURLAsset(url:bigURL).loadTracks(withMediaType:.video).first!
        let proxyTrack = try await AVURLAsset(url:proxyURL).loadTracks(withMediaType:.video).first!
        let (bigTransform,bigRange) = try await bigTrack.load(.preferredTransform,.timeRange)
        let (proxySize,proxyTransform,proxyRange,proxyFormats) = try await proxyTrack.load(.naturalSize,.preferredTransform,.timeRange,.formatDescriptions)
        try require(proxySize == CGSize(width:1920,height:1080),"proxy is 1920 × 1080, got \(proxySize)")
        try require(proxyTransform.a == bigTransform.a && proxyTransform.b == bigTransform.b && proxyTransform.c == bigTransform.c && proxyTransform.d == bigTransform.d,"proxy keeps the source orientation")
        try require(abs(proxyRange.start.seconds-bigRange.start.seconds) < 0.05 && abs(proxyRange.end.seconds-bigRange.end.seconds) < 0.1,"proxy spans the source's time range")
        let proxyTransfer = proxyFormats.first.flatMap { CMFormatDescriptionGetExtension($0,extensionKey:kCMFormatDescriptionExtension_TransferFunction) as? String }
        try require(proxyTransfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String),"proxy keeps the HLG transfer, got \(proxyTransfer ?? "nil")")
        // Every picture at exactly the source's timestamp (29.97 fps is off the writer's default
        // 1/600 grid; rounded, the preview would show the neighbouring frame at many frame times).
        var sourceTimes = try await decodedTimes(bigURL), proxyTimes = try await decodedTimes(proxyURL)
        if let first = sourceTimes.first, first > bigRange.start, proxyTimes.first == bigRange.start { proxyTimes.removeFirst() }   // lead-in
        try require(!sourceTimes.isEmpty && proxyTimes == sourceTimes,"proxy frames carry the source's exact timestamps (\(proxyTimes.count) vs \(sourceTimes.count), first mismatch \(zip(proxyTimes,sourceTimes).first(where: { $0 != $1 }).map { "\($0.0.value)/\($0.0.timescale) vs \($0.1.value)/\($0.1.timescale)" } ?? "none"))")
        sourceTimes.removeAll()
        var bigProject = Project(); bigProject.media = [bigMedia]
        let bigClip = try Editing.add(mediaID:bigMedia.id,lane:.v1,at:.zero,to:&bigProject)
        if let i = bigProject.clips.firstIndex(where: { $0.id == bigClip }) { bigProject.clips[i].style.x = 0.12; bigProject.clips[i].style.scale = 1.4; bigProject.clips[i].style.rotation = 9 }
        let fromOriginal = try await builder.build(bigProject,urls:[bigMedia.id:bigURL])
        let fromProxy = try await builder.build(bigProject,urls:[bigMedia.id:bigURL],videoURLs:[bigMedia.id:proxyURL])
        var worstProxy = 0.0
        for seconds in [0.0,0.7,1.4] {
            func still(_ bundle: RenderBundle) async throws -> CGImage {
                let generator = AVAssetImageGenerator(asset:bundle.composition); generator.videoComposition = bundle.videoComposition
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                return try await generator.image(at:CMTime(seconds:seconds,preferredTimescale:600)).image
            }
            worstProxy = max(worstProxy,meanDifference(try await still(fromOriginal),try await still(fromProxy)))
        }
        try require(worstProxy < 0.012,"proxy preview matches the original preview (difference \(worstProxy))")
        // A proxy the system purged from Caches must not break the preview: the original is read instead.
        let purged = MediaPaths.cache.appendingPathComponent("purged-\(UUID().uuidString).mov")
        let fallback = try await builder.build(bigProject,urls:[bigMedia.id:bigURL],videoURLs:[bigMedia.id:purged])
        let fallbackSources = fallback.composition.tracks(withMediaType:.video).flatMap { $0.segments.compactMap(\.sourceURL) }
        try require(fallbackSources.contains(bigURL) && !fallbackSources.contains(purged),"a missing proxy falls back to the original")
        print("PASS 4K HLG source previews from a 1080p proxy (parity difference \(worstProxy))")
        // Phone HEVC often decodes nothing for its first frames, so the first picture arrives after
        // the track starts. The proxy must still have a picture from the very start.
        let leadURL = fixtures.appendingPathComponent("lead4k.mp4")
        let sourceStart = try await firstDecodedTime(leadURL)
        try require(sourceStart > .zero,"lead4k.mp4 decodes late, as phone footage does (else this check proves nothing), first at \(sourceStart.seconds)")
        try? FileManager.default.removeItem(at:ProxyMaker.url(for:leadURL))
        guard let leadProxy = try await ProxyMaker.make(from:leadURL) else { throw EditError("CHECK FAILED: lead4k.mp4 made no proxy") }
        // What matters is the composed preview: an empty span there gets no source frame and goes black.
        let leadMedia = try await library.inspect(leadURL)
        var leadProject = Project(); leadProject.media = [leadMedia]
        _ = try Editing.add(mediaID:leadMedia.id,lane:.v1,at:.zero,to:&leadProject)
        let leadBundle = try await builder.build(leadProject,urls:[leadMedia.id:leadURL],videoURLs:[leadMedia.id:leadProxy])
        let leadGenerator = AVAssetImageGenerator(asset:leadBundle.composition); leadGenerator.videoComposition = leadBundle.videoComposition
        leadGenerator.requestedTimeToleranceBefore = .zero; leadGenerator.requestedTimeToleranceAfter = .zero
        let leadFirst = pixels(try await leadGenerator.image(at:.zero).image)
        let leadLuma = stride(from:0,to:leadFirst.count,by:4).reduce(0.0) { $0 + Double(leadFirst[$1]) + Double(leadFirst[$1+1]) + Double(leadFirst[$1+2]) } / Double(160*90*3)
        try require(leadLuma > 30,"the preview's first frame from the proxy is a picture, not black (mean \(leadLuma))")
        print("PASS proxy of a late-starting source has a picture from its first frame")
        // Sources a plain HEVC proxy cannot stand in for are previewed from the original: colour tags
        // the writer has no constant for (it would raise an uncatchable exception), an alpha
        // channel (the proxy would be opaque), and non-square pixels (it would change the shape).
        for name in ["bt470bg-1440.mp4","alpha-1440.mov","anamorphic-1440.mp4"] {
            let url = fixtures.appendingPathComponent(name)
            let media = try await library.inspect(url)
            try? FileManager.default.removeItem(at:ProxyMaker.url(for:url))
            try require(ProxyMaker.wantsProxy(width:media.width,height:media.height),"\(name) is larger than FHD")
            try require(try await ProxyMaker.make(from:url) == nil,"\(name) gets no proxy and is previewed from the original")
        }
        print("PASS sources a proxy cannot stand in for (BT.470BG tags, alpha, non-square pixels) keep the original")
        for made in [proxyURL,leadProxy] { try? FileManager.default.removeItem(at:made) }   // test proxies stay out of the app's cache
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
        // A retimed clip must leave a valid video composition wherever it starts. A segment rounded
        // a fraction of a nanosecond past the timeline end once made AVFoundation reject the whole
        // video composition: no picture in preview or export.
        let retimeMedia = project.media[0]
        var layouts = 0
        for rate in [FrameRate(60),FrameRate(30000,1001),FrameRate(25)] {
            for leadFrames in [61,83,97] {
                for speed in [3.0,2.9,1.7,0.75,0.25,4.0,1.5] {
                    var retimed = Project(); retimed.frameRate = rate; retimed.media = [retimeMedia]
                    let lead = try Editing.add(mediaID:retimeMedia.id,lane:.v1,at:.zero,to:&retimed)
                    try Editing.trim(lead,leading:false,to:MediaTime(ticks:rate.frame.ticks*Int64(leadFrames)),in:&retimed)
                    let leadEnd = retimed.clips.first(where: { $0.id == lead })!.end
                    let fast = try Editing.add(mediaID:retimeMedia.id,lane:.v1,at:leadEnd,to:&retimed)
                    try Editing.setSpeed(fast,to:speed,in:&retimed)
                    let bundle = try await builder.build(retimed,urls:urls)
                    let valid = bundle.videoComposition.isValid(for:bundle.composition.tracks,assetDuration:bundle.composition.duration,
                                                                timeRange:CMTimeRange(start:.zero,duration:bundle.composition.duration),validationDelegate:nil)
                    try require(valid && bundle.composition.duration == retimed.duration.cmTime,
                                "retimed clip at \(speed)x after \(leadFrames) frames at \(rate.label) fps leaves a valid composition (valid \(valid), composition \(bundle.composition.duration.value)/\(bundle.composition.duration.timescale), timeline \(retimed.duration.cmTime.value)/\(retimed.duration.cmTime.timescale))")
                    layouts += 1
                }
            }
        }
        print("PASS retimed clips leave a valid video composition ending on the timeline end (\(layouts) layouts)")
        // Tracks beyond V2/A2: a higher video track draws over every lower one, and linked audio
        // dropped on V4 lands on an A4 the timeline grows for it.
        var stacked = Project(); stacked.media = [project.media[0],project.media[1],project.media[2]]
        try Editing.addTrack(.video,to:&stacked)
        _ = try Editing.add(mediaID:project.media[0].id,lane:.v1,at:.zero,to:&stacked)                // red
        _ = try Editing.add(mediaID:project.media[1].id,lane:.v2,at:.zero,to:&stacked)                // blue
        let top = try Editing.add(mediaID:project.media[2].id,lane:Lane(.video,3),at:.zero,to:&stacked) // green
        try Editing.addTrack(.video,to:&stacked)
        let fourth = try Editing.add(mediaID:project.media[0].id,lane:Lane(.video,4),at:.init(seconds:2.5),to:&stacked)
        try require(stacked.audioTrackCount == 4 && stacked.group(for:fourth).contains { $0.lane == Lane(.audio,4) },"linked audio on V4 grows the timeline to A4")
        func centre(_ project: Project, at seconds: Double) async throws -> [UInt8] {
            let bundle = try await builder.build(project,urls:urls)
            let generator = AVAssetImageGenerator(asset:bundle.composition); generator.videoComposition = bundle.videoComposition
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let px = pixels(try await generator.image(at:CMTime(seconds:seconds,preferredTimescale:600)).image)
            let i = (45*160+80)*4
            return [px[i],px[i+1],px[i+2]]
        }
        let green = try await centre(stacked,at:0.5)
        try require(green[1] > 150 && green[0] < 60 && green[2] < 180,"V3 draws over V2 and V1, got \(green)")
        if let i = stacked.clips.firstIndex(where: { $0.id == top }) { stacked.clips[i].style.opacity = 0 }
        let blue = try await centre(stacked,at:0.5)
        try require(blue[2] > 150 && blue[0] < 60 && blue[1] < 60,"with V3 hidden, V2 draws over V1, got \(blue)")
        let stackedBundle = try await builder.build(stacked,urls:urls)
        let a4 = stackedBundle.composition.tracks(withMediaType:.audio).contains { track in
            track.segments.contains { !$0.isEmpty && abs($0.timeMapping.target.start.seconds-2.5) < 0.01 }
        }
        try require(a4,"A4's audio is in the composition at 2.5 s")
        print("PASS four video tracks stack in order and A4 audio plays (V3 over V2 over V1)")
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
    /// Presentation times of every decoded picture, in decode-output order.
    static func decodedTimes(_ url: URL) async throws -> [CMTime] {
        let asset = AVURLAsset(url:url)
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { return [] }
        let reader = try AVAssetReader(asset:asset)
        let out = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        out.alwaysCopiesSampleData = false
        reader.add(out); reader.startReading(); defer { reader.cancelReading() }
        var times: [CMTime] = []
        while let sample = out.copyNextSampleBuffer() { if CMSampleBufferGetImageBuffer(sample) != nil { times.append(CMSampleBufferGetPresentationTimeStamp(sample)) } }
        return times
    }
    static func firstDecodedTime(_ url: URL) async throws -> CMTime {
        let asset = AVURLAsset(url:url)
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { return .invalid }
        let reader = try AVAssetReader(asset:asset)
        let out = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(out); reader.startReading(); defer { reader.cancelReading() }
        return out.copyNextSampleBuffer().map(CMSampleBufferGetPresentationTimeStamp) ?? .invalid
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
