import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

@MainActor private final class SnapTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// A clip dragged onto another's edge by snapping gives one alignment tick.
final class SnapHapticsTests: XCTestCase {
    /// Titles A on V1 1–3 s, B on V2 2–4 s, C on V1 6–8 s; 60 pt per second, snap reach 8 pt.
    @MainActor private func withTimeline(haptics: Bool = true, _ check: (EditorStore, TimelineCanvas, [NSHapticFeedbackManager.FeedbackPattern]) throws -> [NSHapticFeedbackManager.FeedbackPattern]) throws -> [NSHapticFeedbackManager.FeedbackPattern] {
        _ = NSApplication.shared
        let store = EditorStore(), saved = UserDefaults.standard.object(forKey:"timeline.scrubHaptics")
        let restore = unfoldingEverySound(store); defer { restore() }
        store.scrubHaptics = haptics
        store.edit("Fixture") { project in
            project.frameRate = .init(30)
            project.clips = [Clip(name:"A",kind:.text,lane:.v1,start:.init(seconds:1),duration:.init(seconds:2)),
                             Clip(name:"B",kind:.text,lane:.v2,start:.init(seconds:2),duration:.init(seconds:2)),
                             Clip(name:"C",kind:.text,lane:.v1,start:.init(seconds:6),duration:.init(seconds:2))]
        }
        store.isBuilding = false
        let window = SnapTestWindow(contentRect:NSRect(x:0,y:0,width:900,height:400),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let canvas = TimelineCanvas(frame:NSRect(x:0,y:0,width:900,height:400))
        canvas.store = store; canvas.pixelsPerSecond = 60; canvas.pressedMouseButtons = { 0 }
        window.contentView = canvas
        var cues: [NSHapticFeedbackManager.FeedbackPattern] = []
        canvas.performHaptic = { cues.append($0) }
        defer {
            window.contentView = nil; window.close()
            if let saved { UserDefaults.standard.set(saved,forKey:"timeline.scrubHaptics") } else { UserDefaults.standard.removeObject(forKey:"timeline.scrubHaptics") }
        }
        _ = try check(store,canvas,cues)
        return cues
    }
    /// The middle of V1's picture, under V2 and its sound.
    private let v1 = TrackLayout(videoTracks:2,audioTracks:2,folded:[],top:TimelineCanvas.ruler+TimelineCanvas.addBand).row(.v1)!.top+31
    @MainActor private func mouse(_ type: NSEvent.EventType, _ seconds: Double, at time: TimeInterval, _ flags: NSEvent.ModifierFlags = [], on canvas: TimelineCanvas) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:canvas.convert(NSPoint(x:seconds*60,y:v1),to:nil),modifierFlags:flags,timestamp:time,
                           windowNumber:canvas.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }
    /// Grabs A in its middle (2 s) and drags it through these pointer positions (seconds, event time).
    @MainActor private func dragA(_ path: [(Double,TimeInterval)], _ flags: NSEvent.ModifierFlags = [], on canvas: TimelineCanvas) {
        canvas.mouseDown(with:mouse(.leftMouseDown,2,at:0,on:canvas))
        for (x,t) in path { canvas.mouseDragged(with:mouse(.leftMouseDragged,x,at:t,flags,on:canvas)) }
        canvas.mouseUp(with:mouse(.leftMouseUp,path.last?.0 ?? 2,at:(path.last?.1 ?? 0)+0.01,on:canvas))
    }

    @MainActor func testSnappingOntoAnEdgeTicksOnceAndNotForJitter() throws {
        let cues = try withTimeline { store, canvas, _ in
            // Free movement: quiet. Then A's end reaches C's start (6 s): caught, one tick; moving
            // on while still caught: nothing more.
            dragA([(2.5,0.05),(3.2,0.10),(4.95,0.15),(4.97,0.17),(4.93,0.19)],on:canvas)
            XCTAssertEqual(store.project.clips.first { $0.name == "A" }?.start.seconds ?? 0,4,accuracy:1e-9,"snapped")
            return []
        }
        XCTAssertEqual(cues,[.alignment])
        // Off the edge and straight back within 0.18 s is jitter; after that, a new catch.
        let jitter = try withTimeline { _, canvas, _ in
            dragA([(4.95,0.10),(5.6,0.15),(4.95,0.20),(5.6,0.30),(4.95,0.45)],on:canvas); return []
        }
        XCTAssertEqual(jitter,[.alignment,.alignment])
    }

    @MainActor func testNoTickWithoutSnappingOrOnABusySpot() throws {
        // Shift during the drag turns snapping off for it.
        XCTAssertEqual(try withTimeline { _, canvas, _ in dragA([(3,0.05),(4.95,0.10)],.shift,on:canvas); return [] },[])
        // Trackpad Haptics off.
        XCTAssertEqual(try withTimeline(haptics:false) { _, canvas, _ in dragA([(3,0.05),(4.95,0.10)],on:canvas); return [] },[])
        // Caught by C's start (6 s) where A would lie on top of C: it cannot go there, so no tick.
        XCTAssertEqual(try withTimeline { _, canvas, _ in dragA([(4,0.05),(6.97,0.10)],on:canvas); return [] },[])
    }

    @MainActor func testTrimmingOntoAnEdgeTicksToo() throws {
        let cues = try withTimeline { store, canvas, _ in
            // A's end handle (3 s) dragged out to B's end (4 s).
            canvas.mouseDown(with:mouse(.leftMouseDown,2.97,at:0,on:canvas))
            canvas.mouseDragged(with:mouse(.leftMouseDragged,3.5,at:0.05,on:canvas))
            canvas.mouseDragged(with:mouse(.leftMouseDragged,3.95,at:0.10,on:canvas))
            canvas.mouseUp(with:mouse(.leftMouseUp,3.95,at:0.11,on:canvas))
            XCTAssertEqual(store.project.clips.first { $0.name == "A" }?.end.seconds ?? 0,4,accuracy:1e-9)
            return []
        }
        XCTAssertEqual(cues,[.alignment])
    }
}
