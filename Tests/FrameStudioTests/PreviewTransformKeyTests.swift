import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

/// A hidden window: real responder methods, without taking the user's input focus.
@MainActor private final class KeyTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// Return (or Enter) finishes a transform in the preview and keeps it; Esc still cancels a drag.
final class PreviewTransformKeyTests: XCTestCase {
    @MainActor private func withOverlay(_ check: (EditorStore, PreviewTransformOverlay, Clip) async throws -> Void) async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        var title = Clip(name:"Title",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:5)); title.style.text = "Return"
        store.edit("Fixture") { $0.clips = [title] }
        for _ in 0..<1000 where store.isBuilding || store.player.currentItem == nil { try await Task.sleep(for:.milliseconds(10)) }
        let window = KeyTestWindow(contentRect:NSRect(x:0,y:0,width:800,height:450),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let overlay = PreviewTransformOverlay(store:store)
        overlay.frame = NSRect(x:0,y:0,width:800,height:450)
        window.contentView = overlay
        defer { window.contentView = nil; window.close() }
        store.selectedClipID = title.id; store.previewTransformID = title.id
        try await check(store,overlay,title)
    }
    @MainActor private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in view: NSView) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:view.window?.windowNumber ?? 0,
                         context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
    }
    @MainActor private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                           windowNumber:view.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }

    @MainActor func testReturnAndEnterFinishTheTransformAndKeepIt() async throws {
        try await withOverlay { store, overlay, title in
            let before = store.project
            overlay.keyDown(with:key(36,"\r",in:overlay))
            XCTAssertNil(store.previewTransformID,"Return finishes")
            XCTAssertEqual(store.project,before,"and changes nothing by itself")
            store.previewTransformID = title.id
            overlay.keyDown(with:key(76,"\u{3}",in:overlay))
            XCTAssertNil(store.previewTransformID,"so does the keypad's Enter")
            // With a modifier it is not this command.
            store.previewTransformID = title.id
            overlay.keyDown(with:key(36,"\r",.command,in:overlay))
            XCTAssertEqual(store.previewTransformID,title.id)
        }
    }

    @MainActor func testReturnKeepsADragInProgressWhereEscCancelsIt() async throws {
        try await withOverlay { store, overlay, title in
            for (code,characters,keeps) in [(UInt16(36),"\r",true),(UInt16(53),"\u{1b}",false)] {
                store.previewTransformID = title.id
                let before = store.project.clips[0].style
                let centre = CGPoint(x:800*(0.5+before.x),y:450*(0.5+before.y))   // wherever the title is now
                overlay.mouseDown(with:mouse(.leftMouseDown,centre,in:overlay))
                overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:centre.x+80,y:centre.y),in:overlay))
                XCTAssertNotEqual(store.project.clips[0].style.x,before.x,"the drag moves the title")
                overlay.keyDown(with:key(code,characters,in:overlay))
                XCTAssertNil(store.previewTransformID)
                if keeps { XCTAssertGreaterThan(store.project.clips[0].style.x,before.x,"Return keeps the move"); XCTAssertEqual(store.undoName,"Adjust clip") }
                else { XCTAssertEqual(store.project.clips[0].style,before,"Esc puts it back") }
                overlay.mouseUp(with:mouse(.leftMouseUp,centre,in:overlay))
            }
            store.undo()
            XCTAssertEqual(store.project.clips[0].style.x,0,accuracy:1e-9,"the kept move is one undo step")
        }
    }

    /// Return set for a command (as an earlier Ara let Snapping have it) still finishes the
    /// transform first, as in the timeline; with nothing to finish it is that command. The preview
    /// goes by the store's shortcuts.
    @MainActor func testTheFixedKeysComeBeforeTheShortcutsSetInSettings() async throws {
        try await withOverlay { store, overlay, title in
            let suite = "ara.tests.preview-keys.\(UUID().uuidString)", saved = UserDefaults.standard.object(forKey:"timeline.snapping")
            defer {
                UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
                if let saved { UserDefaults.standard.set(saved,forKey:"timeline.snapping") } else { UserDefaults.standard.removeObject(forKey:"timeline.snapping") }
            }
            store.shortcuts = ShortcutSettings(defaults:UserDefaults(suiteName:suite)!)
            store.shortcuts.set(Shortcut("return"),for:.snapping)
            let snapping = store.snapping
            overlay.keyDown(with:key(36,"\r",in:overlay))
            XCTAssertNil(store.previewTransformID,"Return finishes"); XCTAssertEqual(store.snapping,snapping,"and toggles nothing")
            overlay.keyDown(with:key(36,"\r",in:overlay))
            XCTAssertNotEqual(store.snapping,snapping,"with nothing to finish it is the shortcut")
            // Esc cancels, whatever it is set for.
            store.shortcuts.set(Shortcut("escape"),for:.snapping)
            store.previewTransformID = title.id; let now = store.snapping
            overlay.keyDown(with:key(53,"\u{1b}",in:overlay))
            XCTAssertNil(store.previewTransformID); XCTAssertEqual(store.snapping,now)
        }
    }

    @MainActor func testReturnInTheTimelineFinishesTheTransformToo() async throws {
        try await withOverlay { store, overlay, title in
            let canvas = TimelineCanvas(frame:NSRect(x:0,y:0,width:800,height:300))
            canvas.store = store
            overlay.window?.contentView?.addSubview(canvas)
            canvas.keyDown(with:key(36,"\r",in:canvas))
            XCTAssertNil(store.previewTransformID)
            canvas.removeFromSuperview()
        }
    }

    @MainActor func testMovingLinesTheCentreUpWithAGuideAndATick() async throws {
        try await withOverlay { store, overlay, title in
            // A second title B, showing too, with its centre at (560, 360) on the 800×450 frame.
            var other = Clip(name:"B",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:5)); other.style.text = "B"
            other.style.x = 0.2; other.style.y = 0.3
            store.edit("B") { $0.clips.append(other) }
            for _ in 0..<1000 where store.isBuilding { try await Task.sleep(for:.milliseconds(10)) }
            store.selectedClipID = title.id; store.previewTransformID = title.id
            var ticks: [NSHapticFeedbackManager.FeedbackPattern] = []
            overlay.performHaptic = { ticks.append($0) }
            let saved = UserDefaults.standard.object(forKey:"timeline.scrubHaptics"); store.scrubHaptics = true
            defer { if let saved { UserDefaults.standard.set(saved,forKey:"timeline.scrubHaptics") } else { UserDefaults.standard.removeObject(forKey:"timeline.scrubHaptics") } }
            // The title starts in the middle; dragged to (558, 228): B's centre across, the frame's down.
            overlay.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:400,y:225),in:overlay))
            overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:480,y:300),in:overlay))
            overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:558,y:228),in:overlay))
            XCTAssertEqual(overlay.guides.vertical,560); XCTAssertEqual(overlay.guides.horizontal,225)
            let style = try XCTUnwrap(store.project.clips.first { $0.id == title.id }?.style)
            XCTAssertEqual(style.x,0.2,accuracy:1e-9,"exactly on B's centre across")
            XCTAssertEqual(style.y,0,accuracy:1e-9,"and on the frame's centre down")
            XCTAssertEqual(ticks,[.alignment],"one tick for lining up (the first sample was on no guide)")
            // Moving on along the guide keeps it, without another tick.
            overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:559,y:229),in:overlay))
            XCTAssertEqual(ticks,[.alignment])
            overlay.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:559,y:229),in:overlay))
            XCTAssertNil(overlay.guides.vertical,"no guide once let go")
            // With Shift held during the drag, nothing lines up.
            store.previewTransformID = title.id
            overlay.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:560,y:225),in:overlay))
            overlay.mouseDragged(with:NSEvent.mouseEvent(with:.leftMouseDragged,location:overlay.convert(CGPoint(x:402,y:227),to:nil),modifierFlags:.shift,timestamp:ProcessInfo.processInfo.systemUptime,
                                                         windowNumber:overlay.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!)
            XCTAssertNil(overlay.guides.vertical); XCTAssertNil(overlay.guides.horizontal)
            XCTAssertNotEqual(store.project.clips.first { $0.id == title.id }?.style.x ?? 0,0,"not pulled to the middle")
            overlay.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:402,y:227),in:overlay))
        }
    }

    @MainActor func testTheAlignmentPointIsPlacedWithAClickAndCatchesACorner() async throws {
        try await withOverlay { store, overlay, title in
            store.editAnchor(title)
            XCTAssertEqual(store.anchorEditID,title.id); XCTAssertEqual(store.previewTransformID,title.id)
            var ticks: [NSHapticFeedbackManager.FeedbackPattern] = []
            overlay.performHaptic = { ticks.append($0) }
            let saved = UserDefaults.standard.object(forKey:"timeline.scrubHaptics"); store.scrubHaptics = true
            defer { if let saved { UserDefaults.standard.set(saved,forKey:"timeline.scrubHaptics") } else { UserDefaults.standard.removeObject(forKey:"timeline.scrubHaptics") } }
            let before = store.project.clips[0].style
            // The title's top-left corner, in the 800×450 overlay (the canvas fills it).
            let size = try XCTUnwrap(store.previewSourceSize(for:title))
            let corner = VisualGeometry(sourceSize:size,canvasSize:CGSize(width:800,height:450),style:before,isText:true).corners[0]
            overlay.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:corner.x+4,y:corner.y+3),in:overlay))
            overlay.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:corner.x+4,y:corner.y+3),in:overlay))
            let placed = store.project.clips[0].style
            XCTAssertEqual(placed.anchorX,-0.5); XCTAssertEqual(placed.anchorY,-0.5)
            XCTAssertEqual(placed.x,before.x); XCTAssertEqual(placed.y,before.y,"the title stays put")
            XCTAssertEqual(ticks,[.alignment],"a tick for catching the corner")
            store.undo(); XCTAssertFalse(store.project.clips[0].style.hasAnchor,"one undo step")
            // Still placing the point; Return ends that but keeps the transform.
            XCTAssertEqual(store.anchorEditID,title.id)
            overlay.keyDown(with:key(36,"\r",in:overlay))
            XCTAssertNil(store.anchorEditID); XCTAssertEqual(store.previewTransformID,title.id)
        }
    }
}
