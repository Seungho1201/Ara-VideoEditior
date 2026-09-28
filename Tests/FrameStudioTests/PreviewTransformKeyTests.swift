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
}
