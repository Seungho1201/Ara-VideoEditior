import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

final class TimelineDrawingTests: XCTestCase {
    /// Compare actual AppKit drawing, not just the sample-index calculation: a partial repaint
    /// must preserve both the source sample and the subpixel position of every waveform bar.
    @MainActor func testScrubbingPreservesWaveformAcrossPartialRepaints() throws {
        for scale in [1.0, 2.0] {
            for zoom in [37.0, 64.0, 137.25] {
                try withTimeline(zoom:zoom) { store, canvas, waveformArea in
                    store.seek(.init(seconds:1))
                    let incremental = try bitmap(for:canvas,scale:scale)
                    paint(canvas,into:incremental,scale:scale,area:canvas.bounds)
                    // Revisit the same samples from both directions, including fractional
                    // playhead positions and overlapping invalidation strips.
                    for time in [2.13, 4.57, 1.92, 6.21, 2.13, 3.4, 3.43, 1.0] {
                        let oldX = store.playhead.seconds*zoom
                        store.seek(.init(seconds:time))
                        for x in [oldX,store.playhead.seconds*zoom] {
                            let strip = NSRect(x:x-8,y:0,width:16,height:canvas.bounds.height)
                            paint(canvas,into:incremental,scale:scale,area:strip)
                        }
                        let fresh = try bitmap(for:canvas,scale:scale)
                        paint(canvas,into:fresh,scale:scale,area:canvas.bounds)
                        XCTAssertEqual(differingPixels(in:waveformArea,between:incremental,and:fresh,scale:scale),0,
                                       "Waveform changed after scrubbing to \(time)s at zoom \(zoom), \(scale)x backing scale")
                    }
                }
            }
        }
    }

    @MainActor func testWaveformMatchesWhenViewportIsPaintedInTiles() throws {
        for scale in [1.0, 2.0] {
            try withTimeline(zoom:91.25) { _, canvas, waveformArea in
                let fresh = try bitmap(for:canvas,scale:scale)
                paint(canvas,into:fresh,scale:scale,area:canvas.bounds)
                let tiled = try bitmap(for:canvas,scale:scale)
                // AppKit also exposes strips while scrolling. Odd-width tiles must not
                // restart the two-point waveform grid at each exposed edge.
                for x in stride(from:0.0,to:canvas.bounds.width,by:31) {
                    paint(canvas,into:tiled,scale:scale,
                          area:NSRect(x:x,y:0,width:31,height:canvas.bounds.height))
                }
                XCTAssertEqual(differingPixels(in:waveformArea,between:tiled,and:fresh,scale:scale),0,
                               "Tiled drawing changed the waveform at \(scale)x backing scale")
            }
        }
    }

    @MainActor private func withTimeline(zoom:Double, _ check:(EditorStore,TimelineCanvas,NSRect) throws -> Void) throws {
        _ = NSApplication.shared
        let store = EditorStore()
        let media = MediaReference(name:"Waveform fixture",path:"/waveform-fixture.wav",kind:.audio,
                                   duration:.init(seconds:30),hasAudio:true)
        let clips = [
            Clip(mediaID:media.id,name:media.name,kind:.audio,lane:.a1,start:.init(seconds:11.0/60),
                 sourceStart:.init(seconds:3.25),duration:.init(seconds:8),speed:2),
            Clip(mediaID:media.id,name:media.name,kind:.audio,lane:.a2,start:.init(seconds:23.0/60),
                 sourceStart:.init(seconds:1.5),duration:.init(seconds:10),speed:0.5)
        ]
        XCTAssertTrue(store.edit("Waveform fixture") { project in
            project.frameRate = .init(60); project.media = [media]; project.clips = clips
        })
        store.isBuilding = false
        store.selectedClipID = clips[0].id
        store.waveforms[media.id] = (0..<6000).map { Float(($0*37)%101)/100 }
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:340),
                              styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let canvas = TimelineCanvas(frame:NSRect(x:0,y:0,width:800,height:340))
        canvas.store = store; canvas.pixelsPerSecond = zoom
        window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        XCTAssertEqual(canvas.visibleRect,canvas.bounds)
        // The two sounds, each under its video track.
        let rows = [Lane.a1,.a2].compactMap(canvas.trackLayout.row)
        XCTAssertEqual(rows.count,2)
        for row in rows { try check(store,canvas,NSRect(x:0,y:row.top,width:800,height:row.height)) }
    }

    @MainActor private func bitmap(for canvas:TimelineCanvas,scale:Double) throws -> CGContext {
        try XCTUnwrap(CGContext(data:nil,width:Int(canvas.bounds.width*scale),height:Int(canvas.bounds.height*scale),
                               bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                               bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    @MainActor private func paint(_ canvas:TimelineCanvas,into context:CGContext,scale:Double,area:NSRect) {
        // AppKit clips drawing to invalidated device pixels. Keep a single backing image
        // across redraws to reproduce the residue seen during playhead-only invalidation.
        let minX = floor(area.minX*scale)/scale, maxX = ceil(area.maxX*scale)/scale
        let area = NSRect(x:minX,y:area.minY,width:maxX-minX,height:area.height).intersection(canvas.bounds)
        guard !area.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        context.saveGState()
        context.translateBy(x:0,y:Double(context.height)); context.scaleBy(x:scale,y:-scale)
        context.clip(to:area)
        NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true)
        canvas.draw(area)
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func differingPixels(in area:NSRect,between a:CGContext,and b:CGContext,scale:Double) -> Int {
        let bytesA = a.data!.assumingMemoryBound(to:UInt8.self), bytesB = b.data!.assumingMemoryBound(to:UInt8.self)
        var changed = 0
        for y in Int(area.minY*scale)..<Int(area.maxY*scale) {
            for x in Int(area.minX*scale)..<Int(area.maxX*scale) {
                let offset = y*a.bytesPerRow+x*4
                // Quartz can round alpha coverage one 8-bit level differently when stroking
                // a clipped path. Larger differences indicate moved bars or changed samples.
                if (0..<4).contains(where:{ abs(Int(bytesA[offset+$0])-Int(bytesB[offset+$0])) > 1 }) { changed += 1 }
            }
        }
        return changed
    }
}
