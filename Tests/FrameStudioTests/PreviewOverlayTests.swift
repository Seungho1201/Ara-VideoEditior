import AppKit
import SwiftUI
import XCTest
import FrameCore
@testable import FrameStudio

/// A hidden window: real responder methods, without taking the user's input focus.
@MainActor private final class OverlayTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
@MainActor private final class FlippedBackdrop: NSView {
    override var isFlipped: Bool { true }
}
/// Records the cursor rects handed to it, standing in for the transform chrome.
@MainActor private final class CursorRecorder: NSView {
    var rects: [(rect: CGRect, cursor: NSCursor)] = []
    override var isFlipped: Bool { true }
    override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) { rects.append((rect,object)); super.addCursorRect(rect,cursor:object) }
}
/// Records the keys a view passes on up the responder chain.
@MainActor private final class PassedKeys: NSResponder {
    var keys: [UInt16] = []
    override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
}

/// The preview's transform overlay: placing the alignment point (the keys, a double-click, a
/// pinch, the pointer), a drag the project changed under, its words, and help mode.
@MainActor final class PreviewOverlayTests: XCTestCase {
    private static let keys = ["timeline.snapping","timeline.scrubHaptics","haptics.off","haptics.skimStrength"]
    private func title(_ name: String, _ text: String, lane: Lane = .v1, _ change: (inout ClipStyle) -> Void = { _ in }) -> Clip {
        var clip = Clip(name:name,kind:.text,lane:lane,start:.zero,duration:.init(seconds:5))
        clip.style.text = text; change(&clip.style); return clip
    }
    private func settle(_ store: EditorStore) async throws {
        for _ in 0..<1500 where store.isBuilding || store.player.currentItem == nil { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertFalse(store.isBuilding)
    }
    /// A built store with these clips, a private pasteboard, and the app's timeline settings put back afterwards.
    private func withStore(_ clips: [Clip], _ check: @MainActor (EditorStore) async throws -> Void) async throws {
        _ = NSApplication.shared
        let saved = Self.keys.reduce(into:[String:Any]()) { values, key in values[key] = UserDefaults.standard.object(forKey:key) }
        let store = EditorStore()
        store.pasteboard = NSPasteboard(name:.init("ara-preview-overlay-\(UUID().uuidString)"))
        store.runAlert = { alert in XCTFail("Unexpected question: \(alert.messageText)"); return .alertSecondButtonReturn }
        defer {
            store.pause(); store.pasteboard.releaseGlobally()
            for key in Self.keys {
                if let value = saved[key] { UserDefaults.standard.set(value,forKey:key) } else { UserDefaults.standard.removeObject(forKey:key) }
            }
        }
        XCTAssertTrue(store.edit("Fixture") { $0.clips = clips },store.message ?? "")
        try await settle(store)
        store.snapping = true; store.scrubHaptics = true; store.hapticsOff = []
        try await check(store)
    }
    /// The first clip selected and transforming in an 800 × 450 overlay (the canvas fills it).
    private func withOverlay(_ clips: [Clip], _ check: @MainActor (EditorStore, PreviewTransformOverlay) async throws -> Void) async throws {
        try await withStore(clips) { store in
            let window = OverlayTestWindow(contentRect:NSRect(x:0,y:0,width:800,height:450),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            let overlay = PreviewTransformOverlay(store:store)
            overlay.frame = NSRect(x:0,y:0,width:800,height:450)
            overlay.performHaptic = { _ in }
            window.contentView = overlay
            defer { overlay.finishDrag(); window.contentView = nil; window.close() }
            if let first = clips.first { store.selectedClipID = first.id; store.previewTransformID = first.id }
            try await check(store,overlay)
        }
    }
    /// The whole preview (its chrome in the window above it), 800 × 450 at (150, 120) in a
    /// 1100 × 700 backdrop, with the first clip selected and transforming.
    private func withPreview(_ clips: [Clip], _ check: @MainActor (EditorStore, PreviewEditorView, NSView) async throws -> Void) async throws {
        try await withStore(clips) { store in
            let window = OverlayTestWindow(contentRect:NSRect(x:0,y:0,width:1100,height:700),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            let backdrop = FlippedBackdrop(frame:NSRect(x:0,y:0,width:1100,height:700))
            window.contentView = backdrop
            let preview = PreviewEditorView(store:store)
            preview.frame = CGRect(x:150,y:120,width:800,height:450)
            backdrop.addSubview(preview); preview.layoutSubtreeIfNeeded()
            preview.overlay.performHaptic = { _ in }
            defer { preview.overlay.finishDrag(); preview.chrome.removeFromSuperview(); window.contentView = nil; window.close() }
            if let first = clips.first { store.selectedClipID = first.id; store.previewTransformID = first.id; preview.overlay.refresh() }
            try await check(store,preview,backdrop)
        }
    }
    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in view: NSView) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:view.window?.windowNumber ?? 0,
                         context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
    }
    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                           windowNumber:view.window!.windowNumber,context:nil,eventNumber:0,clickCount:clicks,pressure:1)!
    }
    private func doubleClick(_ point: CGPoint, in view: NSView) {
        for clicks in [1,2] {
            view.mouseDown(with:mouse(.leftMouseDown,point,clicks:clicks,in:view)); view.mouseUp(with:mouse(.leftMouseUp,point,clicks:clicks,in:view))
        }
    }
    /// A trackpad ⌥-scroll over `point` (precise deltas).
    private func optionScroll(_ dy: Int32, at point: CGPoint, in view: NSView) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:dy,wheel2:0,wheel3:0)!
        event.flags = .maskAlternate
        let screen = view.window!.convertPoint(toScreen:view.convert(point,to:nil))
        event.location = CGPoint(x:screen.x,y:(NSScreen.screens.first?.frame.height ?? 0)-screen.y)
        return NSEvent(cgEvent:event)!
    }
    private func clip(_ store: EditorStore, _ id: UUID) -> Clip { store.project.clips.first { $0.id == id }! }
    private func style(_ store: EditorStore, _ id: UUID) -> ClipStyle { clip(store,id).style }
    /// Where the clip is drawn in an 800 × 450 canvas.
    private func geometry(_ store: EditorStore, _ id: UUID) -> VisualGeometry {
        let clip = clip(store,id)
        return VisualGeometry(sourceSize:store.previewSourceSize(for:clip)!,canvasSize:CGSize(width:800,height:450),style:clip.style,isText:true)
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews { if let hit = find(type,in:sub) { return hit } }
        return nil
    }
    /// Lets SwiftUI catch up with the store (it updates on the run loop): until `done`, or for a second.
    private func catchUp(_ host: NSView, until done: () -> Bool = { false }) async throws {
        for _ in 0..<100 where !done() { host.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(10)) }
    }

    // MARK: placing the alignment point

    func testStartingToPlaceThePointGivesThePreviewTheKeys() async throws {
        let a = title("A","Keys")
        try await withStore([a]) { store in
            // The preview as the editor has it, and the timeline, where the clip was picked.
            let window = OverlayTestWindow(contentRect:NSRect(x:0,y:0,width:800,height:750),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            let content = NSView(frame:NSRect(x:0,y:0,width:800,height:750))
            let host = NSHostingView(rootView:PreviewSurface(store:store).frame(width:800,height:450))
            host.frame = NSRect(x:0,y:300,width:800,height:450)
            let canvas = TimelineCanvas(frame:NSRect(x:0,y:0,width:800,height:300)); canvas.store = store
            content.addSubview(host); content.addSubview(canvas)
            window.contentView = content
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            let overlay = try XCTUnwrap(find(PreviewEditorView.self,in:host)).overlay
            store.selectedClipID = a.id
            XCTAssertTrue(window.makeFirstResponder(canvas))
            try await catchUp(host)
            XCTAssertTrue(window.firstResponder === canvas,"a selection moves no keys")
            store.editAnchor(clip(store,a.id))                         // the inspector's Adjust alignment point
            try await catchUp(host) { window.firstResponder === overlay }
            XCTAssertTrue(window.firstResponder === overlay,"the preview takes the keys")
            window.firstResponder?.keyDown(with:key(36,"\r",in:overlay))
            XCTAssertNil(store.anchorEditID,"Return ends the placing")
            XCTAssertEqual(store.previewTransformID,a.id,"and keeps the transform")
            // Starting again takes them again; Done (the same button) leaves them where they are.
            XCTAssertTrue(window.makeFirstResponder(canvas))
            store.editAnchor(clip(store,a.id))
            try await catchUp(host) { window.firstResponder === overlay }
            XCTAssertTrue(window.firstResponder === overlay)
            XCTAssertTrue(window.makeFirstResponder(canvas))
            store.editAnchor(clip(store,a.id))
            XCTAssertNil(store.anchorEditID)
            try await catchUp(host)
            XCTAssertTrue(window.firstResponder === canvas)
            // A preview made later does not take them for a request it never saw.
            let later = NSHostingView(rootView:PreviewSurface(store:store).frame(width:800,height:450))
            later.frame = host.frame; host.removeFromSuperview(); content.addSubview(later)
            try await catchUp(later)
            XCTAssertNotNil(find(PreviewEditorView.self,in:later))
            XCTAssertTrue(window.firstResponder === canvas)
            XCTAssertEqual(PreviewEditorView(store:store).overlay.focusRequest,store.previewFocusRequest,"whenever SwiftUI first updates it")
        }
    }

    func testADoubleClickWhilePlacingOnlyPlacesThePoint() async throws {
        let a = title("A","Placing"), b = title("B","B",lane:.v2) { $0.x = -0.3 }
        try await withOverlay([a,b]) { store, overlay in
            store.editAnchor(clip(store,a.id))
            // Beside the clip, on nothing: the point goes there, and the transform stays.
            doubleClick(geometry(store,a.id).point(atShare:CGPoint(x:1.2,y:0)),in:overlay)
            XCTAssertEqual(store.anchorEditID,a.id); XCTAssertEqual(store.previewTransformID,a.id)
            XCTAssertEqual(style(store,a.id).anchorX,1.2,accuracy:0.002); XCTAssertEqual(style(store,a.id).anchorY,0,accuracy:0.002)
            XCTAssertTrue(store.status.hasPrefix("Alignment point"),"not the transform's hint: \(store.status)")
            // On another clip showing there: it is not picked; the point goes onto its centre.
            let other = geometry(store,b.id).center
            doubleClick(other,in:overlay)
            XCTAssertEqual(store.selectedClipID,a.id); XCTAssertEqual(store.previewTransformID,a.id); XCTAssertEqual(store.anchorEditID,a.id)
            let anchor = geometry(store,a.id).anchor
            XCTAssertLessThan(hypot(anchor.x-other.x,anchor.y-other.y),1)
            // Once the placing is over, a double-click picks a clip again.
            overlay.keyDown(with:key(36,"\r",in:overlay))
            doubleClick(other,in:overlay)
            XCTAssertEqual(store.selectedClipID,b.id); XCTAssertEqual(store.previewTransformID,b.id)
        }
    }

    func testPinchAndOptionScrollResizeNothingWhilePlacing() async throws {
        let a = title("A","Zoom")
        try await withOverlay([a]) { store, overlay in
            let middle = CGPoint(x:400,y:225)
            // Transforming: ⌥-scroll resizes, and Esc during it puts it back.
            overlay.scrollWheel(with:optionScroll(30,at:middle,in:overlay))
            XCTAssertGreaterThan(style(store,a.id).scale,1.01)
            overlay.keyDown(with:key(53,"\u{1b}",in:overlay))
            XCTAssertEqual(style(store,a.id).scale,1); XCTAssertNil(store.previewTransformID)
            // Placing the point: nothing is resized, and Esc ends only the placing.
            store.editAnchor(clip(store,a.id))
            let before = store.project
            overlay.scrollWheel(with:optionScroll(30,at:middle,in:overlay))
            overlay.scrollWheel(with:optionScroll(-40,at:middle,in:overlay))
            XCTAssertEqual(store.project,before); XCTAssertFalse(overlay.isDragging)
            overlay.keyDown(with:key(53,"\u{1b}",in:overlay))
            XCTAssertNil(store.anchorEditID); XCTAssertEqual(store.previewTransformID,a.id); XCTAssertEqual(store.project,before)
            // Placing over, it resizes again.
            overlay.scrollWheel(with:optionScroll(30,at:middle,in:overlay))
            XCTAssertGreaterThan(style(store,a.id).scale,1.01)
        }
    }

    func testWhilePlacingTheChromeOffersOnlyTheCrosshairAndTheHiddenKnobTakesNothing() async throws {
        let a = title("A","Near the top")
        try await withPreview([a]) { store, preview, backdrop in
            let recorder = CursorRecorder(frame:backdrop.bounds)
            backdrop.addSubview(recorder,positioned:.below,relativeTo:nil)
            let overlay = preview.overlay
            // The title's top edge 10 pt below the top of the viewer: its knob sits above the viewer.
            let corners = geometry(store,a.id).corners
            var raised = style(store,a.id); raised.y = (10-225+(corners[3].y-corners[0].y)/2)/450
            store.updatePreviewTransform(a.id,style:raised); overlay.refresh()
            let handle = try XCTUnwrap(overlay.activeRotationHandle())
            XCTAssertFalse(overlay.bounds.contains(handle.knob),"the knob is outside the viewer")
            let knob = overlay.convert(handle.knob,to:backdrop), body = overlay.convert(geometry(store,a.id).center,to:backdrop)
            @MainActor func registered() -> [(rect: CGRect, cursor: NSCursor)] { recorder.rects = []; overlay.addChromeCursorRects(to:recorder); return recorder.rects }
            @MainActor func drawn() -> [(rect: CGRect, cursor: NSCursor)] {
                recorder.rects = []
                guard let bitmap = recorder.bitmapImageRepForCachingDisplay(in:recorder.bounds) else { XCTFail("no bitmap"); return [] }
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
                overlay.drawChrome(in:recorder)
                NSGraphicsContext.restoreGraphicsState()
                return recorder.rects
            }
            // Transforming: the hand over the clip, the turning arrow on the knob, which takes a click.
            let transforming = registered()
            XCTAssertTrue(transforming.contains { $0.cursor == .openHand && $0.rect.contains(body) })
            XCTAssertTrue(transforming.contains { $0.cursor === PreviewTransformOverlay.rotateCursor && $0.rect.contains(knob) })
            XCTAssertTrue(preview.chrome.hitTest(knob) === preview.chrome)
            XCTAssertTrue(drawn().isEmpty,"drawing adds no cursor rects")
            // Placing the point: the crosshair only, and the hidden knob neither shows an arrow nor takes a click.
            store.editAnchor(clip(store,a.id)); overlay.refresh()
            let placing = registered()
            XCTAssertFalse(placing.isEmpty)
            XCTAssertTrue(placing.allSatisfy { $0.cursor == .crosshair },"\(placing.map(\.cursor))")
            XCTAssertTrue(placing.contains { $0.rect.contains(body) })
            XCTAssertFalse(placing.contains { $0.rect.contains(knob) })
            XCTAssertNil(preview.chrome.hitTest(knob))
            XCTAssertTrue(preview.chrome.hitTest(body) === preview.chrome,"the clip still takes the click that places the point")
            XCTAssertTrue(drawn().isEmpty,"drawing adds no cursor rects")
            // Done: as before.
            store.editAnchor(clip(store,a.id)); overlay.refresh()
            XCTAssertTrue(registered().contains { $0.cursor === PreviewTransformOverlay.rotateCursor && $0.rect.contains(knob) })
            XCTAssertTrue(preview.chrome.hitTest(knob) === preview.chrome)
        }
    }

    // MARK: a drag the project changed under

    func testUndoInTheMiddleOfADragEndsTheDrag() async throws {
        let a = title("A","Undo mid drag")
        try await withOverlay([a]) { store, overlay in
            store.updateStyleLive(a.id,name:"Adjust clip",closesWhenIdle:false) { $0.y = 0.1 }; store.endLiveEdit()   // an earlier step
            let earlier = store.project
            let centre = geometry(store,a.id).center
            overlay.mouseDown(with:mouse(.leftMouseDown,centre,in:overlay))
            overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:centre.x+40,y:centre.y),in:overlay))
            XCTAssertGreaterThan(style(store,a.id).x,0)
            let moved = store.project
            store.undo()                                                    // ⌘Z with the button still held
            XCTAssertEqual(store.project,earlier,"the drag so far is its own step, undone")
            // The rest of the drag, during the rebuild and after it, changes nothing.
            overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:centre.x+50,y:centre.y),in:overlay))
            XCTAssertFalse(overlay.isDragging)
            try await settle(store)
            overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:centre.x+80,y:centre.y),in:overlay))
            overlay.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:centre.x+80,y:centre.y),in:overlay))
            XCTAssertEqual(store.project,earlier)
            // The next ⌘Z takes back the earlier step alone; ⌘⇧Z brings back the move made before the undo.
            store.undo(); try await settle(store)
            XCTAssertEqual(style(store,a.id).y,0); XCTAssertEqual(style(store,a.id).x,0)
            store.redo(); try await settle(store)
            XCTAssertEqual(store.project,earlier)
            store.redo(); try await settle(store)
            XCTAssertEqual(store.project,moved)
            // SwiftUI's update after an undo ends a drag at once, and its centre guide with it.
            let now = geometry(store,a.id).center
            overlay.mouseDown(with:mouse(.leftMouseDown,now,in:overlay))
            overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:402,y:now.y),in:overlay))
            XCTAssertEqual(overlay.guides.vertical,400)
            store.undo(); overlay.refresh()
            XCTAssertFalse(overlay.isDragging); XCTAssertNil(overlay.guides.vertical)
            overlay.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:402,y:now.y),in:overlay))
            XCTAssertEqual(store.project,moved)
        }
    }

    func testEscAfterAnUndoMidDragPutsNothingBack() async throws {
        let a = title("A","Esc after undo")
        try await withOverlay([a]) { store, overlay in
            store.updateStyleLive(a.id,name:"Adjust clip",closesWhenIdle:false) { $0.y = 0.1 }; store.endLiveEdit()
            let centre = geometry(store,a.id).center
            overlay.mouseDown(with:mouse(.leftMouseDown,centre,in:overlay))
            overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:centre.x+40,y:centre.y),in:overlay))
            // ⌘Z twice with the button held (the drag, then the earlier step), and Esc before SwiftUI updates the preview.
            store.undo(); try await settle(store); store.undo(); try await settle(store)
            let undone = store.project
            XCTAssertEqual(style(store,a.id).y,0)
            overlay.keyDown(with:key(53,"\u{1b}",in:overlay))
            XCTAssertEqual(store.project,undone,"the style the drag started from is not put back")
            overlay.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:centre.x+40,y:centre.y),in:overlay))
            XCTAssertEqual(store.project,undone)
            XCTAssertEqual(store.history.redoName,"Adjust clip")
        }
    }

    func testAPinchGoingOnAfterAnUndoIsAStepOfItsOwn() async throws {
        let a = title("A","Undo mid pinch")
        try await withOverlay([a]) { store, overlay in
            store.updateStyleLive(a.id,name:"Adjust clip",closesWhenIdle:false) { $0.y = 0.1 }; store.endLiveEdit()
            let earlier = store.project, middle = CGPoint(x:400,y:270)
            overlay.scrollWheel(with:optionScroll(30,at:middle,in:overlay))
            XCTAssertGreaterThan(style(store,a.id).scale,1.01)
            store.undo()                                                    // ⌘Z mid-pinch
            XCTAssertEqual(store.project,earlier)
            overlay.scrollWheel(with:optionScroll(30,at:middle,in:overlay))   // the pinch goes on during the rebuild
            XCTAssertFalse(overlay.isDragging,"the pinch from before the undo is over"); XCTAssertEqual(store.project,earlier)
            try await settle(store)
            overlay.scrollWheel(with:optionScroll(30,at:middle,in:overlay))   // and after it
            XCTAssertGreaterThan(style(store,a.id).scale,1.01)
            overlay.finishDrag()                                            // the pause that ends it
            XCTAssertEqual(store.undoName,"Adjust clip")
            store.undo(); try await settle(store)
            XCTAssertEqual(store.project,earlier,"one undo takes back what came after the first")
        }
    }

    // MARK: words and help mode

    func testThePreviewsWordsHaveKoreanEntries() async throws {
        let strings = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ko.lproj/Localizable.strings")
        let korean = try XCTUnwrap(NSDictionary(contentsOf:strings) as? [String:String])
        func specifiers(_ text: String) -> [String] {
            let pattern = try! NSRegularExpression(pattern:"%(\\d+\\$)?(\\.\\d+)?(lld|ld|d|f|@|%)")
            return pattern.matches(in:text,range:NSRange(text.startIndex...,in:text)).map { match in
                (text as NSString).substring(with:match.range).replacingOccurrences(of:"\\d+\\$",with:"",options:.regularExpression)
            }.sorted()
        }
        let a = title("Qz","Words")
        try await withOverlay([a]) { store, overlay in
            // The overlay's words as the string table has them: the clip's name back to its placeholder.
            @MainActor func value() -> String { (overlay.accessibilityValue() as? String ?? "").replacingOccurrences(of:"Qz",with:"%@") }
            var shown = [overlay.accessibilityLabel() ?? "",overlay.toolTip ?? ""]
            store.previewTransformID = nil; overlay.refresh(); shown.append(value())
            store.previewTransformID = a.id; overlay.refresh(); shown.append(value())
            store.editAnchor(clip(store,a.id)); overlay.refresh(); shown.append(value())
            XCTAssertEqual(Set(shown).count,5,"\(shown)")
            for key in shown {
                let translated = try XCTUnwrap(korean[key],"no Korean for “\(key)”")
                XCTAssertEqual(specifiers(translated),specifiers(key),key)
            }
            XCTAssertTrue(overlay.toolTip?.contains("alignment point") == true,"the tooltip names the alignment point")
            XCTAssertTrue(shown[4].hasPrefix("Placing the alignment point"),"placing is said while it is on")
        }
    }

    func testHelpModeKeepsKeysFromThePreviewAndEscClosesIt() async throws {
        let a = title("A","Help")
        try await withOverlay([a]) { store, overlay in
            let passed = PassedKeys(); passed.nextResponder = overlay.nextResponder; overlay.nextResponder = passed
            store.editAnchor(clip(store,a.id))
            store.showHelp = true
            let before = store.project, snapping = store.snapping
            overlay.keyDown(with:key(45,"n",in:overlay)); overlay.keyDown(with:key(36,"\r",in:overlay)); overlay.keyDown(with:key(76,"\u{3}",in:overlay))
            XCTAssertEqual(store.snapping,snapping,"N"); XCTAssertEqual(store.anchorEditID,a.id,"Return ends no placing behind the tips")
            XCTAssertEqual(passed.keys,[45,36,76],"they go on, as the timeline's do")
            overlay.keyDown(with:key(53,"\u{1b}",in:overlay))
            XCTAssertFalse(store.showHelp,"Esc closes help mode")
            XCTAssertEqual(store.anchorEditID,a.id,"and does nothing else"); XCTAssertEqual(store.previewTransformID,a.id)
            XCTAssertEqual(store.project,before)
            overlay.keyDown(with:key(36,"\r",in:overlay))
            XCTAssertNil(store.anchorEditID,"keys work again"); XCTAssertEqual(store.previewTransformID,a.id)
        }
    }

    func testHelpModeCoversTheTransformChromeToo() async throws {
        let a = title("A","Under the tips")
        try await withPreview([a]) { store, preview, backdrop in
            let chrome = preview.chrome, body = preview.overlay.convert(geometry(store,a.id).center,to:backdrop)
            XCTAssertFalse(chrome.isHidden); XCTAssertTrue(chrome.hitTest(body) === chrome)
            // The chrome sits above the whole window, the tips included: while they show it is not
            // drawn and takes no click, so a click on the clip reaches the tips and closes them.
            store.showHelp = true; preview.overlay.refresh()                 // as SwiftUI updates it
            XCTAssertTrue(chrome.isHidden); XCTAssertNil(chrome.hitTest(body))
            store.showHelp = false; preview.overlay.refresh()
            XCTAssertFalse(chrome.isHidden); XCTAssertTrue(chrome.hitTest(body) === chrome)
            XCTAssertTrue(backdrop.subviews.last === chrome,"back on top")
        }
    }
}

/// Media imported while a clip is dragged in the preview: the drag goes on, and the import is an
/// undo step of its own before the drag's, so undoing the drag keeps the media.
final class PreviewImportDuringADragTests: ProjectTestCase {
    func testAnImportLandingMidDragKeepsTheDragAndItsMedia() async throws {
        let still = try makeStill("Imported.png",width:64,height:36)
        let store = makeStore()
        store.pasteboard = NSPasteboard(name:.init("ara-preview-import-\(UUID().uuidString)"))
        let saved = UserDefaults.standard.object(forKey:"timeline.snapping")
        defer {
            store.pause(); store.pasteboard.releaseGlobally()
            if let saved { UserDefaults.standard.set(saved,forKey:"timeline.snapping") } else { UserDefaults.standard.removeObject(forKey:"timeline.snapping") }
        }
        var a = Clip(name:"A",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:5)); a.style.text = "A"
        XCTAssertTrue(store.edit("Fixture") { $0.clips = [a] })
        let built = await eventually { !store.isBuilding && store.player.currentItem != nil }
        XCTAssertTrue(built)
        store.snapping = false
        let window = OverlayTestWindow(contentRect:NSRect(x:0,y:0,width:800,height:450),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let overlay = PreviewTransformOverlay(store:store)
        overlay.frame = NSRect(x:0,y:0,width:800,height:450); overlay.performHaptic = { _ in }
        window.contentView = overlay
        defer { overlay.finishDrag(); window.contentView = nil; window.close() }
        store.selectedClipID = a.id; store.previewTransformID = a.id
        func mouse(_ type: NSEvent.EventType, _ x: Double) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:overlay.convert(NSPoint(x:x,y:225),to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                               windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        overlay.mouseDown(with:mouse(.leftMouseDown,400)); overlay.mouseDragged(with:mouse(.leftMouseDragged,440))
        store.importFiles([still])
        let imported = await eventually { !store.isImporting }
        XCTAssertTrue(imported)
        overlay.refresh()                                                   // SwiftUI's update after the import
        XCTAssertTrue(overlay.isDragging,"the drag goes on")
        overlay.mouseDragged(with:mouse(.leftMouseDragged,560)); overlay.mouseUp(with:mouse(.leftMouseUp,560))
        XCTAssertEqual(store.project.clips[0].style.x,0.2,accuracy:0.01,"to where the pointer was let go")
        XCTAssertEqual(store.undoName,"Adjust clip")
        store.undo()
        XCTAssertEqual(store.project.clips[0].style.x,0,accuracy:1e-9)
        XCTAssertEqual(store.project.media.map(\.name),["Imported.png"],"undoing the drag keeps the media")
        XCTAssertEqual(store.undoName,"Import media")
        store.undo(); XCTAssertTrue(store.project.media.isEmpty)
        store.redo(); store.redo()
        XCTAssertEqual(store.project.media.count,1); XCTAssertEqual(store.project.clips[0].style.x,0.2,accuracy:0.01)
    }
}

/// The outline of a picture has a handle in the middle of each edge: dragging one stretches the
/// picture that way alone, the opposite edge staying put, as one undo step. A title's outline has
/// none: there the edge is the outline, which moves the title.
final class PreviewStretchTests: ProjectTestCase {
    func testAPicturesEdgeMiddlesStretchIt() async throws {
        let still = try makeStill("Wide.png",width:64,height:36)
        let store = makeStore()
        store.pasteboard = NSPasteboard(name:.init("ara-preview-stretch-\(UUID().uuidString)"))
        defer { store.pause(); store.pasteboard.releaseGlobally() }
        store.importFiles([still])
        let imported = await eventually { !store.isImporting && !store.project.media.isEmpty }
        XCTAssertTrue(imported)
        let media = try XCTUnwrap(store.project.media.first)
        var picture = Clip(mediaID:media.id,name:"Wide",kind:.image,lane:.v1,start:.zero,duration:.init(seconds:5)); picture.style.scale = 0.5
        var words = Clip(name:"T",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:5)); words.style.text = "Words"; words.style.x = 0.3
        XCTAssertTrue(store.edit("Fixture") { $0.videoTrackCount = 2; $0.clips = [picture,words] },store.message ?? "")
        let built = await eventually { !store.isBuilding && store.player.currentItem != nil }
        XCTAssertTrue(built)
        let window = OverlayTestWindow(contentRect:NSRect(x:0,y:0,width:800,height:450),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let overlay = PreviewTransformOverlay(store:store)
        overlay.frame = NSRect(x:0,y:0,width:800,height:450); overlay.performHaptic = { _ in }
        window.contentView = overlay
        defer { overlay.finishDrag(); window.contentView = nil; window.close() }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:overlay.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                               windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        func style(_ id: UUID) -> ClipStyle { store.project.clips.first { $0.id == id }!.style }
        func drag(_ from: CGPoint, by dx: CGFloat) {
            overlay.mouseDown(with:mouse(.leftMouseDown,from))
            overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:from.x+dx/2,y:from.y+15)))
            overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:from.x+dx,y:from.y+15)))
            overlay.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:from.x+dx,y:from.y+15)))
        }
        store.selectedClipID = picture.id; store.previewTransformID = picture.id
        // 16:9 at half size in an 800 × 450 canvas: 400 × 225 about the middle. The right edge's
        // middle pulled 100 points right (and a little down, which counts for nothing).
        drag(CGPoint(x:600,y:225),by:100)
        XCTAssertEqual(style(picture.id).stretchX,1.25,accuracy:1e-9); XCTAssertEqual(style(picture.id).stretchY,1)
        let stretched = VisualGeometry(sourceSize:CGSize(width:64,height:36),canvasSize:CGSize(width:800,height:450),style:style(picture.id))
        XCTAssertEqual(stretched.edgeMiddles[3].x,200,accuracy:1e-6,"the left edge stays")
        XCTAssertEqual(store.undoName,"Adjust clip")
        store.undo()
        XCTAssertEqual(style(picture.id).stretchX,1); XCTAssertEqual(style(picture.id).x,0,"one step")
        // Stretched again, then let go 3 pt from its own proportions: back on them, with a tick.
        let rebuiltForEven = await eventually { !store.isBuilding }
        XCTAssertTrue(rebuiltForEven)
        var cues: [NSHapticFeedbackManager.FeedbackPattern] = []
        overlay.performHaptic = { cues.append($0) }
        drag(CGPoint(x:600,y:225),by:100)                                  // 1.25 wide
        let wideAgain = await eventually { !store.isBuilding }
        XCTAssertTrue(wideAgain)
        cues = []
        overlay.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:700,y:225)))
        XCTAssertTrue(overlay.frameColor === PreviewTransformOverlay.outlineColor)
        overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:603,y:225)))
        XCTAssertTrue(overlay.proportional); XCTAssertTrue(overlay.frameColor === PreviewTransformOverlay.proportionColor,"its outline green while there")
        overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:620,y:225)))
        XCTAssertFalse(overlay.proportional,"off them, the outline's own colour"); XCTAssertTrue(overlay.frameColor === PreviewTransformOverlay.outlineColor)
        overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:603,y:225)))
        overlay.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:603,y:225)))
        XCTAssertFalse(overlay.proportional,"let go: no longer stretching")
        XCTAssertEqual(style(picture.id).stretchX,1,accuracy:1e-9,"its own proportions again")
        XCTAssertEqual(cues,[.alignment],"one tick: back on them within a moment is not another")
        overlay.performHaptic = { _ in }
        store.undo(); store.undo()
        // The top edge's middle, where the rotation knob's stem starts, stretches too: down here, shorter.
        let rebuiltOnce = await eventually { !store.isBuilding }
        XCTAssertTrue(rebuiltOnce)
        overlay.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:400,y:112.5)))
        overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:400,y:150)))
        overlay.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:400,y:150)))
        XCTAssertEqual(style(picture.id).stretchY,(337.5-150)/225,accuracy:1e-9); XCTAssertEqual(style(picture.id).rotation,0,"not turned")
        store.undo()
        // Snapping: the right edge let go 3 pt short of the frame's right lands on it, with its guide;
        // with Shift it stays where it was let go.
        let rebuiltTwice = await eventually { !store.isBuilding }
        XCTAssertTrue(rebuiltTwice)
        store.snapping = true
        XCTAssertNotNil(overlay.activeRotationHandle())
        overlay.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:600,y:225)))
        XCTAssertTrue(overlay.isStretching); XCTAssertNil(overlay.activeRotationHandle(),"the rotation knob steps aside while stretching")
        overlay.mouseDragged(with:mouse(.leftMouseDragged,CGPoint(x:797,y:225)))
        XCTAssertEqual(overlay.guides.vertical,800); XCTAssertNil(overlay.activeRotationHandle())
        overlay.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:797,y:225)))
        XCTAssertFalse(overlay.isStretching); XCTAssertNotNil(overlay.activeRotationHandle(),"and is back once let go")
        XCTAssertEqual(style(picture.id).stretchX,1.5,accuracy:1e-9,"from 200 to the frame's edge at 800")
        store.undo()
        let rebuiltThrice = await eventually { !store.isBuilding }
        XCTAssertTrue(rebuiltThrice)
        overlay.mouseDown(with:mouse(.leftMouseDown,CGPoint(x:600,y:225)))
        overlay.mouseDragged(with:NSEvent.mouseEvent(with:.leftMouseDragged,location:overlay.convert(CGPoint(x:797,y:225),to:nil),modifierFlags:[.shift],
                                                     timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!)
        XCTAssertNil(overlay.guides.vertical)
        overlay.mouseUp(with:mouse(.leftMouseUp,CGPoint(x:797,y:225)))
        XCTAssertEqual(style(picture.id).stretchX,597.0/400,accuracy:1e-9,"Shift: no snapping")
        store.undo()
        // A title: its outline's edge middle moves it, and it is never stretched.
        let rebuilt = await eventually { !store.isBuilding }
        XCTAssertTrue(rebuilt)
        store.selectedClipID = words.id; store.previewTransformID = words.id
        let size = try XCTUnwrap(store.previewSourceSize(for:store.project.clips.first { $0.id == words.id }!))
        let edge = VisualGeometry(sourceSize:size,canvasSize:CGSize(width:800,height:450),style:style(words.id),isText:true).edgeMiddles[1]
        drag(edge,by:40)
        XCTAssertEqual(style(words.id).stretchX,1)
        XCTAssertGreaterThan(style(words.id).x,0.3,"moved instead")
    }
}

/// A corner's pointer is the double arrow along the diagonal it pulls on, turned with the clip.
@MainActor final class PreviewCornerCursorTests: XCTestCase {
    func testCornersShowTheDiagonalTheyPullOn() {
        let falling = NSCursor.frameResize(position:.bottomRight,directions:.all), rising = NSCursor.frameResize(position:.topRight,directions:.all)
        func cursors(rotation: Double = 0, stretchX: Double = 1) -> [NSCursor] {
            var style = ClipStyle(); style.scale = 0.5; style.rotation = rotation; style.stretchX = stretchX
            let geometry = VisualGeometry(sourceSize:CGSize(width:64,height:36),canvasSize:CGSize(width:800,height:450),style:style)
            return (0..<4).map { PreviewTransformOverlay.cornerCursor(geometry,$0) }
        }
        func same(_ a: [NSCursor], _ b: [NSCursor]) -> Bool { zip(a,b).allSatisfy(===) }
        // The corners from the top left, clockwise: ↖↘, ↗↙, ↖↘, ↗↙.
        XCTAssertTrue(same(cursors(),[falling,rising,falling,rising]))
        XCTAssertTrue(same(cursors(stretchX:6),[falling,rising,falling,rising]),"a long, thin clip still pulls on the diagonal")
        XCTAssertTrue(same(cursors(rotation:90),[rising,falling,rising,falling]),"turned a right angle, the other diagonal")
        // Turned 45°, a corner pulls straight across or down.
        XCTAssertTrue(same(cursors(rotation:45),[NSCursor.resizeLeftRight,NSCursor.resizeUpDown,NSCursor.resizeLeftRight,NSCursor.resizeUpDown])
                      || same(cursors(rotation:45),[NSCursor.resizeUpDown,NSCursor.resizeLeftRight,NSCursor.resizeUpDown,NSCursor.resizeLeftRight]))
    }
}
