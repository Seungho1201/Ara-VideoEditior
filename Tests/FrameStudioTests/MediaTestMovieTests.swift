import XCTest
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import FrameCore
@testable import FrameMedia

/// Small movies written for a test, in a folder of its own: solid-colour frames (the colour of
/// each frame chosen by the test) and a steady 440 Hz tone, so pictures and sound can be read
/// back and checked.
enum TestMovie {
    static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ara-\(name)-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    /// `frames` pictures at `fps`, each filled with `colour(index)` (RGB); with `audio`, a sine
    /// at `amplitude` in both channels lasting `audioSeconds` (the video's length by default).
    static func write(to url: URL, frames: Int, fps: Int32 = 30, size: (Int,Int) = (160,90), audio: Bool = true,
                      audioSeconds: Double? = nil, amplitude: Double = 0.5, colour: (Int) -> (UInt8,UInt8,UInt8)) async throws {
        try? FileManager.default.removeItem(at:url)
        let writer = try AVAssetWriter(outputURL:url,fileType:.mov)
        let video = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:size.0,AVVideoHeightKey:size.1,
                                                                        AVVideoCompressionPropertiesKey:[AVVideoMaxKeyFrameIntervalKey:1,AVVideoAllowFrameReorderingKey:false]])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:video,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
                                                                                                             kCVPixelBufferWidthKey as String:size.0,kCVPixelBufferHeightKey as String:size.1])
        writer.add(video)
        var sound: AVAssetWriterInput?
        if audio {
            let input = AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:192000])
            input.expectsMediaDataInRealTime = false
            writer.add(input); sound = input
        }
        guard writer.startWriting() else { throw writer.error ?? EditError(verbatim:"cannot write \(url.lastPathComponent)") }
        writer.startSession(atSourceTime:.zero)
        let totalSamples = Int(((audioSeconds ?? Double(frames)/Double(fps))*48000).rounded())
        let pictures = (0..<frames).map(colour)
        // Each stream fed on its own queue whenever the writer wants more, so it can interleave them.
        let pending = DispatchGroup(), state = Unchecked(Progress())
        // Each input is used only on its own queue once it is handed over.
        let picture = Unchecked((video,adaptor))
        pending.enter()
        video.requestMediaDataWhenReady(on:DispatchQueue(label:"test.movie.video")) {
            let (video,adaptor) = picture.value
            while video.isReadyForMoreMediaData, !state.value.videoDone {
                let index = state.value.frame
                guard index < frames else { state.value.videoDone = true; video.markAsFinished(); pending.leave(); return }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer)
                let pixels = buffer!, (r,g,b) = pictures[index]
                CVPixelBufferLockBaseAddress(pixels,[])
                let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to:UInt8.self), row = CVPixelBufferGetBytesPerRow(pixels)
                for y in 0..<size.1 { for x in 0..<size.0 { let i = y*row+x*4; base[i] = b; base[i+1] = g; base[i+2] = r; base[i+3] = 255 } }
                CVPixelBufferUnlockBaseAddress(pixels,[])
                _ = adaptor.append(pixels,withPresentationTime:CMTime(value:Int64(index),timescale:fps))
                state.value.frame += 1
            }
        }
        if let sound {
            let audio = Unchecked(sound)
            pending.enter()
            sound.requestMediaDataWhenReady(on:DispatchQueue(label:"test.movie.audio")) {
                let sound = audio.value
                while sound.isReadyForMoreMediaData, !state.value.audioDone {
                    let from = state.value.sample
                    guard from < totalSamples, let chunk = try? tone(from:from,count:min(4800,totalSamples-from),amplitude:amplitude) else {
                        state.value.audioDone = true; sound.markAsFinished(); pending.leave(); return
                    }
                    _ = sound.append(chunk)
                    state.value.sample += min(4800,totalSamples-from)
                }
            }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void,Never>) in pending.notify(queue:.global()) { done.resume() } }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? EditError(verbatim:"cannot finish \(url.lastPathComponent)") }
    }
    private final class Progress { var frame = 0, sample = 0, videoDone = false, audioDone = false }
    private struct Unchecked<Value>: @unchecked Sendable { let value: Value; init(_ value: Value) { self.value = value } }
    /// Interleaved stereo float samples of a 440 Hz sine, continuing from sample `start`.
    private static func tone(from start: Int, count: Int, amplitude: Double) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kLinearPCMFormatFlagIsFloat|kLinearPCMFormatFlagIsPacked,
                                                      mBytesPerPacket:8,mFramesPerPacket:1,mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator:nil,asbd:&description,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format)
        var samples = [Float](repeating:0,count:count*2)
        for i in 0..<count {
            let value = Float(amplitude*sin(2*Double.pi*440*Double(start+i)/48000))
            samples[2*i] = value; samples[2*i+1] = value
        }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator:nil,memoryBlock:nil,blockLength:count*8,blockAllocator:nil,customBlockSource:nil,offsetToData:0,dataLength:count*8,flags:0,blockBufferOut:&block)
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block!,offsetIntoDestination:0,dataLength:count*8) }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator:nil,dataBuffer:block!,formatDescription:format!,sampleCount:count,
                                                             presentationTimeStamp:CMTime(value:Int64(start),timescale:48000),packetDescriptions:nil,sampleBufferOut:&buffer)
        guard let buffer else { throw EditError(verbatim:"cannot make audio") }
        return buffer
    }

    /// The composed frame at `time`, as a snapshot takes it.
    static func frame(_ bundle: RenderBundle, at time: MediaTime) async throws -> CGImage {
        let png = try await SnapshotExporter().png(bundle,at:time)
        return CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData,nil)!,0,nil)!
    }
    /// The frame at `time` of a movie file.
    static func frame(of movie: URL, at time: MediaTime) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset:AVURLAsset(url:movie))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at:time.cmTime).image
    }
    /// The colour at the middle of an image (sRGB, 0–255).
    static func centre(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        var pixel = [UInt8](repeating:0,count:4)
        let context = CGContext(data:&pixel,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image,in:CGRect(x:-CGFloat(image.width)/2+0.5,y:-CGFloat(image.height)/2+0.5,width:CGFloat(image.width),height:CGFloat(image.height)))
        return (Int(pixel[0]),Int(pixel[1]),Int(pixel[2]))
    }
    private static var monoFloat: [String:Any] { [AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false,AVSampleRateKey:48000,AVNumberOfChannelsKey:1] }
    /// A composition's mixed sound as mono samples at 48 kHz, as the exporter reads it.
    static func mixedSound(_ bundle: RenderBundle) throws -> [Float] {
        let reader = try AVAssetReader(asset:bundle.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks:bundle.composition.tracks(withMediaType:.audio),audioSettings:monoFloat)
        output.audioMix = bundle.audioMix
        reader.add(output)
        return try samples(reader,output)
    }
    /// A movie file's sound as mono samples at 48 kHz.
    static func sound(of movie: URL) async throws -> [Float] {
        let asset = AVURLAsset(url:movie)
        guard let track = try await asset.loadTracks(withMediaType:.audio).first else { throw EditError(verbatim:"no sound in \(movie.lastPathComponent)") }
        let reader = try AVAssetReader(asset:asset), output = AVAssetReaderTrackOutput(track:track,outputSettings:monoFloat)
        reader.add(output)
        return try samples(reader,output)
    }
    private static func samples(_ reader: AVAssetReader, _ output: AVAssetReaderOutput) throws -> [Float] {
        guard reader.startReading() else { throw reader.error! }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating:0,count:length/4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:length,destination:$0.baseAddress!) }
            samples += chunk
        }
        return samples
    }
    /// Root mean square of `samples` between two times (seconds).
    static func level(_ samples: [Float], from start: Double, to end: Double) -> Double {
        let a = Int(start*48000), b = min(samples.count,Int(end*48000))
        guard b > a else { return 0 }
        return (samples[a..<b].reduce(0.0) { $0+Double($1*$1) }/Double(b-a)).squareRoot()
    }
}

final class MediaTestMovieTests: XCTestCase {
    /// The helper writes what it is asked for: the tests below rely on its frames and tone.
    func testWrittenMoviesHaveTheirFramesAndSound() async throws {
        let folder = try TestMovie.folder("movie"); defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("two-colours.mov")
        try await TestMovie.write(to:url,frames:30) { $0 < 15 ? (255,0,0) : (0,0,255) }
        let media = try await MediaLibrary().inspect(url)
        XCTAssertEqual(media.duration.seconds,1,accuracy:0.01); XCTAssertTrue(media.hasAudio)
        let early = TestMovie.centre(try await TestMovie.frame(of:url,at:.init(seconds:0.2)))
        let late = TestMovie.centre(try await TestMovie.frame(of:url,at:.init(seconds:0.9)))
        XCTAssertTrue(early.r > 200 && early.b < 60,"\(early)"); XCTAssertTrue(late.b > 200 && late.r < 60,"\(late)")
    }
}
