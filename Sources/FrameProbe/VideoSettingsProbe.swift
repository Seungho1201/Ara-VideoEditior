import Foundation
@preconcurrency import AVFoundation
import ImageIO
import FrameCore
import FrameMedia

extension FrameProbe {
    static func videoSettingsSmoke(fixtures: URL, output: URL) async throws {
        let source = fixtures.appendingPathComponent("base.mp4")
        let media = try await MediaLibrary().inspect(source)
        var original = Project(); original.frameRate = .init(60); original.media = [media]
        let first = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&original)
        try Editing.trim(first,leading:false,to:.init(seconds:1.1),in:&original)
        try Editing.split(first,at:.init(seconds:0.55),in:&original)
        let title = try Editing.addText(at:.zero,to:&original)
        try Editing.trim(title,leading:false,to:original.frameRate.quantize(.init(seconds:1.1)),in:&original)
        let titleIndex = original.clips.firstIndex { $0.id == title }!
        original.clips[titleIndex].style.text = "Ara"; original.clips[titleIndex].style.fontSize = 100
        original.clips[titleIndex].style.y = -0.2
        let builder = CompositionBuilder(), exporter = MovieExporter()
        let cases: [(VideoAspectRatio,FrameRate,Int)] = [(.landscape,.init(24000,1001),1080),(.portrait,.init(30),1080),(.square,.init(24),1080),(.classic,.init(25),1080),(.social,.init(50),1080),(.portrait,.init(30),2160),
                                                       (.landscape,.init(30),720),(.landscape,.init(30),1152),(.landscape,.init(30),1440),(.social,.init(30),1620)]
        for (ratio,rate,resolution) in cases {
            var project = original
            try Editing.setVideoSettings(aspectRatio:ratio,frameRate:rate,in:&project)
            let stem = "\(ratio.rawValue.replacingOccurrences(of:":",with:"x"))-\(rate.label)-\(resolution)"
            let file = output.appendingPathComponent(stem+".framestudio")
            try ProjectFile.encode(project).write(to:file)
            let restored = try ProjectFile.decode(Data(contentsOf:file))
            try require(restored == project,"settings save/reopen")
            let bundle = try await builder.build(restored,urls:[media.id:source],height:resolution)
            try require(bundle.size == ratio.size(resolution:resolution),"composition dimensions")
            let movie = output.appendingPathComponent(stem+".mp4")
            try await exporter.export(bundle,to:movie) { _ in }
            let asset = AVURLAsset(url:movie)
            guard let video = try await asset.loadTracks(withMediaType:.video).first,
                  let audio = try await asset.loadTracks(withMediaType:.audio).first else { throw EditError("Missing video or audio stream") }
            let size = try await video.load(.naturalSize), fps = try await video.load(.nominalFrameRate)
            let duration = try await asset.load(.duration), audioRange = try await audio.load(.timeRange)
            try require(size == bundle.size,"encoded dimensions \(stem)")
            try require(abs(Double(fps)-rate.value) < 0.001,"encoded frame rate \(stem)")
            try require(abs(duration.seconds-project.duration.seconds) < 0.002,"encoded duration \(stem)")
            try require(abs(audioRange.start.seconds) < 0.002 && abs(audioRange.end.seconds-project.duration.seconds) < rate.frame.seconds,"audio starts and ends with video")
            let snapshot = output.appendingPathComponent(stem+".png")
            let time = rate.quantize(.init(seconds:0.25))
            try await SnapshotExporter().export(bundle,at:time,to:snapshot)
            let imageSource = CGImageSourceCreateWithURL(snapshot as CFURL,nil)!
            let image = CGImageSourceCreateImageAtIndex(imageSource,0,nil)!
            try require(image.width == Int(size.width) && image.height == Int(size.height),"snapshot dimensions")
            let frames = AVAssetImageGenerator(asset:asset)
            frames.requestedTimeToleranceBefore = .zero; frames.requestedTimeToleranceAfter = .zero
            let encoded = try await frames.image(at:time.cmTime).image
            let difference = meanDifference(image,encoded)
            try require(difference < 0.035,"composed snapshot / MP4 parity \(difference)")
            print("PASS \(stem): \(Int(size.width))×\(Int(size.height)), \(fps) fps, \(duration.seconds)s, audio / snapshot / save-reopen; pixel difference \(difference)")
        }
    }
}
