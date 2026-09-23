import Foundation
@preconcurrency import AVFoundation
import CoreImage
import FrameCore

/// Generates the composed frame, independent of viewer size, playback or screen capture.
public actor SnapshotExporter {
    private let context = FrameRenderer.makeContext()
    public init() {}

    public func png(_ bundle: RenderBundle, at time: MediaTime) async throws -> Data {
        guard time >= .zero, time < bundle.duration,
              bundle.frameRate.quantize(time) == time else { throw EditError("Choose a frame inside the timeline to capture.") }
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset:bundle.composition)
        generator.videoComposition = bundle.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        defer { generator.cancelAllCGImageGeneration() }
        let result = try await generator.image(at:time.cmTime)
        try Task.checkCancellation()
        // Convert the pixels from the generator's video profile to sRGB, then embed
        // that profile. Merely assigning an sRGB tag would change the colors.
        guard let data = context.pngRepresentation(of:CIImage(cgImage:result.image),format:.RGBA8,
                                                   colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) else {
            throw EditError("Cannot encode the snapshot as PNG.")
        }
        try Task.checkCancellation()
        return data
    }

    public func export(_ bundle: RenderBundle, at time: MediaTime, to url: URL) async throws {
        let data = try await png(bundle,at:time)
        try Task.checkCancellation()
        try data.write(to:url,options:.atomic)
    }
}
