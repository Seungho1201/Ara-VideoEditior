import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

/// Hidden AppKit views exercise real responder methods without taking the user's input focus.
@MainActor private final class SkimmingTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

final class SkimmingInputTests: XCTestCase {
    @MainActor private func withTimeline(_ check: (EditorStore, TimelineCanvas, NSWindow) throws -> Void) rethrows {
        _ = NSApplication.shared
        let store = EditorStore()
        let oldHaptics = store.scrubHaptics
        store.scrubHaptics = false
        store.edit("Fixture") { project in
            project.frameRate = .init(30)
            project.clips = [Clip(name:"Title",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:10))]
        }
        // This test only navigates a model; the asynchronous AV composition is not needed.
        store.isBuilding = false
        let window = SkimmingTestWindow(contentRect:NSRect(x:0,y:0,width:800,height:400),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let canvas = TimelineCanvas(frame:NSRect(x:0,y:0,width:800,height:400))
        canvas.store = store; canvas.pixelsPerSecond = 60
        canvas.pressedMouseButtons = { 0 }          // not the real mouse: someone may be using it
        window.contentView = canvas
        defer {
            window.contentView = nil; window.close()
            store.scrubHaptics = oldHaptics
        }
        try check(store,canvas,window)
    }

    @MainActor private func event(_ type: NSEvent.EventType, x: Double, y: Double = 10, modifiers: NSEvent.ModifierFlags = [], on canvas: TimelineCanvas) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:canvas.convert(NSPoint(x:x,y:y),to:nil),modifierFlags:modifiers,
                           timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:canvas.window!.windowNumber,
                           context:nil,eventNumber:0,clickCount:1,pressure:0)!
    }

    @MainActor func testHoverKeepsPositionEvenWithLegacySkimmingPreferenceEnabled() {
        let defaults = UserDefaults.standard, key = "timeline.skimming"
        let previous = defaults.object(forKey:key)
        defaults.set(true,forKey:key)
        defer {
            if let previous { defaults.set(previous,forKey:key) } else { defaults.removeObject(forKey:key) }
        }
        withTimeline { store, canvas, _ in
            let before = store.project
            store.seek(.init(seconds:3))
            for y in [10.0,80,canvas.trackLayout.row(.v1)!.top+31] { // Ruler, empty V2, and a clip on V1.
                canvas.mouseMoved(with:event(.mouseMoved,x:120,y:y,on:canvas))
                XCTAssertEqual(store.playhead,.init(seconds:3))
            }
            XCTAssertEqual(store.project,before)
        }
    }

    @MainActor func testRulerDragSeeksAndStopsOnMouseUp() {
        withTimeline { store, canvas, _ in
            let before = store.project
            canvas.mouseDown(with:event(.leftMouseDown,x:60,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:1))
            canvas.mouseDragged(with:event(.leftMouseDragged,x:120,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:2))
            canvas.mouseUp(with:event(.leftMouseUp,x:150,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:2.5))
            canvas.mouseMoved(with:event(.mouseMoved,x:240,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:2.5))
            XCTAssertEqual(store.project,before)
        }
    }

    @MainActor func testEmptyTrackDragSnapsToClipEndAndShiftBypassesIt() {
        withTimeline { store, canvas, _ in
            let before = store.project
            canvas.mouseDown(with:event(.leftMouseDown,x:60,y:80,on:canvas))
            // At 30 fps and 60 points/second, 592 is four frames before the end.
            canvas.mouseDragged(with:event(.leftMouseDragged,x:592,y:80,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:10))
            canvas.mouseDragged(with:event(.leftMouseDragged,x:592,y:80,modifiers:.shift,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:296.0/30))
            canvas.mouseUp(with:event(.leftMouseUp,x:592,y:80,modifiers:.shift,on:canvas))
            canvas.mouseMoved(with:event(.mouseMoved,x:120,y:80,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:296.0/30))
            XCTAssertEqual(store.project,before)
        }
    }

    @MainActor func testMissingScrubMouseUpCancelsInsteadOfFollowingHover() {
        withTimeline { store, canvas, _ in
            canvas.mouseDown(with:event(.leftMouseDown,x:60,on:canvas))
            // A menu/window activation can interrupt tracking before mouseUp reaches the view.
            // Button-free movement must cancel the gesture without moving the playhead.
            canvas.mouseMoved(with:event(.mouseMoved,x:120,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:1))
            canvas.mouseUp(with:event(.leftMouseUp,x:180,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:1))
            canvas.mouseDown(with:event(.leftMouseDown,x:120,on:canvas))
            canvas.mouseDragged(with:event(.leftMouseDragged,x:240,on:canvas))
            canvas.mouseUp(with:event(.leftMouseUp,x:240,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:4))
        }
    }

    @MainActor func testInterruptedClipDragDiscardsGhostWithoutEditingTheProject() {
        withTimeline { store, canvas, _ in
            let before = store.project
            store.seek(.init(seconds:3))
            let v1 = canvas.trackLayout.row(.v1)!.top+31
            canvas.mouseDown(with:event(.leftMouseDown,x:100,y:v1,on:canvas))
            canvas.mouseDragged(with:event(.leftMouseDragged,x:160,y:v1,on:canvas))
            canvas.mouseMoved(with:event(.mouseMoved,x:240,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:3))
            XCTAssertEqual(store.project,before)
            // A late mouseUp must not commit the old, interrupted drag candidate.
            canvas.mouseUp(with:event(.leftMouseUp,x:240,on:canvas))
            XCTAssertEqual(store.project,before)
        }
    }

    @MainActor func testPlaybackStartedMidScrubIgnoresTheRestOfTheGesture() {
        withTimeline { store, canvas, _ in
            let before = store.project
            canvas.mouseDown(with:event(.leftMouseDown,x:60,on:canvas))
            canvas.mouseDragged(with:event(.leftMouseDragged,x:120,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:2))
            // Space while the button is still down; playback then moves the playhead on.
            store.isPlaying = true
            store.seek(.init(seconds:2.5))
            // More drag samples and a late release (three-finger drag lifts late) must not
            // throw the playhead back to the pointer.
            canvas.mouseDragged(with:event(.leftMouseDragged,x:126,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:2.5))
            canvas.mouseUp(with:event(.leftMouseUp,x:126,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:2.5))
            // Paused again, a new press on the ruler scrubs as usual.
            store.isPlaying = false
            canvas.mouseDown(with:event(.leftMouseDown,x:240,on:canvas))
            canvas.mouseUp(with:event(.leftMouseUp,x:240,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:4))
            XCTAssertEqual(store.project,before)
        }
    }

    @MainActor func testHoverDuringPlaybackKeepsPosition() {
        withTimeline { store, canvas, _ in
            store.seek(.init(seconds:3))
            store.isPlaying = true
            canvas.mouseMoved(with:event(.mouseMoved,x:120,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:3))
            store.isPlaying = false
            canvas.mouseMoved(with:event(.mouseMoved,x:240,on:canvas))
            XCTAssertEqual(store.playhead,.init(seconds:3))
        }
    }
}
