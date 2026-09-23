import Foundation
@preconcurrency import AVFoundation
import ImageIO
import FrameCore
import FrameMedia

extension FrameProbe {
    static func snapshotSmoke(fixtures:URL, output:URL) async throws {
        let library = MediaLibrary(), builder = CompositionBuilder(), snapshots = SnapshotExporter()
        var project = Project(); project.name = "Ara Snapshot Validation"
        var urls: [UUID:URL] = [:]
        for name in ["base.mp4","overlay.mp4","still.png"] {
            let url = fixtures.appendingPathComponent(name)
            let media = try await library.inspect(url)
            project.media.append(media); urls[media.id] = url
        }
        let base = try Editing.add(mediaID:project.media[0].id,lane:.v1,at:.zero,to:&project)
        try Editing.split(base,at:.init(seconds:3),in:&project)
        try Editing.trim(base,leading:true,to:.init(seconds:1),in:&project)
        try Editing.move(base,to:.zero,lane:.v1,in:&project)
        let overlay = try Editing.add(mediaID:project.media[1].id,lane:.v2,at:.zero,to:&project)
        try Editing.trim(overlay,leading:false,to:.init(seconds:1),in:&project)
        let overlayIndex = project.clips.firstIndex { $0.id == overlay }!
        project.clips[overlayIndex].style.scale = 0.45
        project.clips[overlayIndex].style.x = 0.22
        project.clips[overlayIndex].style.rotation = 12
        project.clips[overlayIndex].style.opacity = 0.75
        project.clips[overlayIndex].style.brightness = 0.1
        let title = try Editing.addText(at:.init(seconds:3),to:&project)
        try Editing.trim(title,leading:false,to:.init(seconds:5),in:&project)
        project.clips[project.clips.firstIndex { $0.id == title }!].style.text = "Ara · Snapshot"
        let still = try Editing.add(mediaID:project.media[2].id,lane:.v2,at:.init(seconds:5),to:&project)
        try Editing.trim(still,leading:false,to:.init(seconds:6),in:&project)
        let original = project
        let bundle = try await builder.build(project,urls:urls)
        let movieURL = output.appendingPathComponent("snapshot-reference.mp4")
        try await MovieExporter().export(bundle,to:movieURL) { _ in }
        let movieFrames = AVAssetImageGenerator(asset:AVURLAsset(url:movieURL))
        movieFrames.requestedTimeToleranceBefore = .zero; movieFrames.requestedTimeToleranceAfter = .zero
        for seconds in [0.0,0.5,1.0,2.0,3.0,4.0,5.0,6.0] {
            let time = project.snapshotTime(at:.init(seconds:seconds))!
            let url = output.appendingPathComponent("snapshot-\(seconds).png")
            try await snapshots.export(bundle,at:time,to:url)
            guard let source = CGImageSourceCreateWithURL(url as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw EditError("Snapshot PNG cannot be read") }
            try require(image.width == 1920 && image.height == 1080,"snapshot resolution")
            let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any]
            try require(properties?[kCGImagePropertyProfileName] != nil,"snapshot embeds color profile")
            let reference = try await movieFrames.image(at:time.cmTime).image
            let difference = meanDifference(image,reference)
            try require(difference < 0.035,"snapshot matches exported frame: \(difference)")
            if seconds == 2 { try require(pixels(image).enumerated().filter { $0.offset%4 != 3 }.allSatisfy { $0.element < 3 },"gap captures black") }
            print("PASS snapshot \(project.frameRate.timecode(time)): 1080p / color profile / MP4 match (\(difference))")
        }
        try require(project == original,"snapshot leaves the edit model unchanged")
        let protected = output.appendingPathComponent("preserved.png")
        let marker = Data("keep-existing-file".utf8); try marker.write(to:protected)
        do {
            try await snapshots.export(bundle,at:bundle.duration,to:protected)
            throw EditError("Unexpected acceptance of exclusive timeline end")
        } catch let error as EditError {
            try require(!error.message.contains("Unexpected"),"invalid capture time rejected")
        }
        try require(try Data(contentsOf:protected) == marker,"failed snapshot preserves existing output")
        let cancelled = Task { try await snapshots.export(bundle,at:.zero,to:protected) }
        cancelled.cancel()
        do { try await cancelled.value; throw EditError("Snapshot cancellation ignored") } catch is CancellationError { }
        try require(try Data(contentsOf:protected) == marker,"cancelled snapshot preserves existing output")
        try FileManager.default.removeItem(at:protected)
        print("PASS snapshot failure / cancellation preserve destination")
        var fractional = Project(); fractional.frameRate = .init(30000,1001)
        fractional.clips = [Clip(name:"One frame",kind:.text,lane:.v2,start:.zero,duration:fractional.frameRate.frame)]
        let oneFrame = try await builder.build(fractional,urls:[:])
        try await snapshots.export(oneFrame,at:fractional.snapshotTime(at:fractional.duration)!,to:output.appendingPathComponent("one-frame-2997.png"))
        print("PASS one-frame 29.97 fps text-only snapshot at project end")
        try ProjectFile.encode(project).write(to:output.appendingPathComponent("Snapshot-Validation.framestudio"),options:.atomic)
        try Data("All snapshot checks passed.\n".utf8).write(to:output.appendingPathComponent("snapshot-result.txt"))
    }
}
