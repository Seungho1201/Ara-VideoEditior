import AppKit
import AVFoundation
import Combine
import SwiftUI
import XCTest
import FrameCore
@testable import FrameStudio

/// Counts the player items the preview is given: one per build of it.
@MainActor private final class ItemCount { var value = 0 }

/// How soon an edit shows in the preview: at once after a quiet moment, and edits close together
/// gathered into one build rather than one each.
@MainActor final class PreviewResponseTests: XCTestCase {
    private func spin(_ milliseconds: Int) async throws { try await Task.sleep(for:.milliseconds(milliseconds)) }
    private func built(_ store: EditorStore) async throws { for _ in 0..<400 where store.isBuilding { try await spin(5) } }

    func testAnEditShowsInThePreviewAtOnce() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        var title = Clip(name:"T",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:3)); title.style.text = "Hello"
        XCTAssertTrue(store.edit("Fixture") { $0.clips = [title] })
        try await built(store); try await spin(300)                              // a quiet moment
        let count = ItemCount()
        let watch = store.player.observe(\.currentItem,options:[.new]) { _,_ in MainActor.assumeIsolated { count.value += 1 } }
        defer { watch.invalidate(); store.pause() }
        func nudge(_ seconds: Double) { store.edit("Move clip") { $0.clips[0].start = .init(seconds:seconds) } }

        let start = CACurrentMediaTime()
        nudge(1)
        try await built(store)
        XCTAssertLessThan(CACurrentMediaTime()-start,EditorStore.rebuildSpacing,"no fixed wait before it shows")
        XCTAssertEqual(count.value,1)

        // Five nudges 20 ms apart: the first at once at most, the rest in one build after them.
        try await spin(300); count.value = 0
        for step in 2...6 { nudge(Double(step)); try await spin(20) }
        try await built(store); try await spin(200)
        XCTAssertLessThanOrEqual(count.value,2,"gathered, not one build each")
        XCTAssertGreaterThanOrEqual(count.value,1)
        XCTAssertEqual(store.project.clips[0].start,.init(seconds:6))
    }

    /// Dragging a clip starts at once (the rest of the editor hears of the pick on release), the
    /// preview is left alone while the drag goes on, and the release lands the move and builds the
    /// preview once, at once. Esc lands nothing and builds nothing.
    func testThePreviewIsBuiltOnceWhenADragLands() async throws {
        var ids: [String:UUID] = [:]
        let rig = TimelineRig { project in
            let a = Clip(name:"A",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:2)), b = Clip(name:"B",kind:.text,lane:.v1,start:.init(seconds:3),duration:.init(seconds:2))
            ids["a"] = a.id; ids["b"] = b.id; project.clips = [a,b]
        }
        defer { rig.close() }
        let store = rig.store
        store.snapping = false; store.selectedClipID = ids["b"]
        try await built(store); try await spin(300)
        let count = ItemCount()
        let watch = store.player.observe(\.currentItem,options:[.new]) { _,_ in MainActor.assumeIsolated { count.value += 1 } }
        defer { watch.invalidate(); store.pause() }
        let before = store.project, lane = rig.y(.v2)

        rig.down(1,lane)
        XCTAssertEqual(store.selectedClipID,ids["b"],"the inspector is not redrawn as the drag starts")
        for x in stride(from:1.1,through:2,by:0.1) { rig.drag(x,lane); try await spin(20) }
        XCTAssertFalse(store.isBuilding); XCTAssertEqual(count.value,0,"nothing built while dragging")
        XCTAssertEqual(store.project,before)
        let release = CACurrentMediaTime()
        rig.up(2,lane)
        XCTAssertEqual(store.selectedClipID,ids["a"],"picked on release")
        XCTAssertEqual(rig.clip(ids["a"]!).start,.init(seconds:1)); XCTAssertEqual(store.undoName,"Move clip")
        try await built(store)
        XCTAssertLessThan(CACurrentMediaTime()-release,EditorStore.rebuildSpacing,"built at once on release")
        try await spin(200)
        XCTAssertEqual(count.value,1,"once")

        // Esc mid-drag: nothing lands, nothing is built.
        count.value = 0
        rig.down(1.5,lane); rig.drag(2.5,lane); rig.drag(3,lane)
        rig.press(53,"\u{1b}")
        rig.up(3,lane)
        try await spin(200)
        XCTAssertEqual(rig.clip(ids["a"]!).start,.init(seconds:1),"nothing landed"); XCTAssertEqual(count.value,0)
    }

    /// In the app the clip pressed on is picked after the release: the drop is drawn first, then
    /// the preview's new frame, and only then is the inspector redrawn for the clip. A press
    /// meanwhile has the say.
    func testTheDropIsDrawnBeforeTheInspectorFollows() async throws {
        var ids: [String:UUID] = [:]
        let rig = TimelineRig { project in
            let a = Clip(name:"A",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:2)), b = Clip(name:"B",kind:.text,lane:.v1,start:.init(seconds:3),duration:.init(seconds:2))
            ids["a"] = a.id; ids["b"] = b.id; project.clips = [a,b]
        }
        defer { rig.close() }
        let store = rig.store, lane = rig.y(.v2)
        try await built(store); try await spin(300)                              // its frame drawn
        store.snapping = false; store.selectedClipID = ids["b"]; rig.canvas.pickDelay = 0.03
        var settledWhenPicked: Bool?
        let watch = store.$selectedClipID.dropFirst().sink { _ in settledWhenPicked = !store.previewIsSettling }
        defer { watch.cancel() }
        rig.drag(from:1,through:[1.5,2],y:lane)
        XCTAssertEqual(rig.clip(ids["a"]!).start,.init(seconds:1),"the move lands at once")
        XCTAssertEqual(store.selectedClipID,ids["b"],"the inspector follows later")
        XCTAssertTrue(store.previewIsSettling)
        for _ in 0..<60 where store.selectedClipID != ids["a"] { try await spin(10) }
        XCTAssertEqual(store.selectedClipID,ids["a"]); XCTAssertEqual(store.previewTransformID,ids["a"])
        XCTAssertEqual(settledWhenPicked,true,"after the preview's new frame is up")
        // Pressed on A, then on empty track space before A is picked: nothing picked.
        store.selectedClipID = ids["b"]
        rig.down(1.5,lane); rig.up(1.5,lane)
        rig.down(8,lane); rig.up(8,lane)
        try await spin(80)
        XCTAssertNil(store.selectedClipID,"the later press has the say")
    }

    /// A build beginning and ending is not an update of the whole editor: only the views that show
    /// it hear of it.
    func testABuildIsNoUpdateOfTheEditor() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        var title = Clip(name:"T",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:3)); title.style.text = "Hello"
        XCTAssertTrue(store.edit("Fixture") { $0.clips = [title] })
        defer { store.pause() }
        try await built(store)
        var editor = 0, badge = 0
        let a = store.objectWillChange.sink { editor += 1 }, b = store.building.objectWillChange.sink { badge += 1 }
        defer { a.cancel(); b.cancel() }
        store.isBuilding = true; store.isBuilding = true
        XCTAssertTrue(store.canCaptureSnapshot,"a snapshot is drawn from the project: a build does not stop it")
        store.isBuilding = false
        XCTAssertEqual(editor,0); XCTAssertEqual(badge,2,"only real changes")
    }

    /// The inspector is redrawn for what it shows, not for a clip moved elsewhere, a status note or
    /// playback.
    func testTheInspectorIsLeftAloneByWhatItDoesNotShow() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        let a = Clip(name:"A",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:2)), b = Clip(name:"B",kind:.text,lane:.v1,start:.init(seconds:3),duration:.init(seconds:2))
        XCTAssertTrue(store.edit("Fixture") { $0.clips = [a,b] })
        defer { store.pause() }
        store.selectedClipID = a.id
        let shown = InspectorInputs(store)
        store.edit("Move clip") { $0.clips[1].start = .init(seconds:4) }
        store.status = "Something else"; store.isPlaying = store.isPlaying
        XCTAssertEqual(InspectorInputs(store),shown,"B moved: A's inspector stays as it is")
        store.edit("Move clip") { $0.clips[0].start = .init(seconds:0.5) }
        XCTAssertNotEqual(InspectorInputs(store),shown,"A moved: its TIMING changes")
        let moved = InspectorInputs(store)
        store.selectedClipID = b.id
        XCTAssertNotEqual(InspectorInputs(store),moved)
        XCTAssertEqual(store.selectedClip?.id,b.id,"the remembered selection follows the pick")
        store.edit("Rename") { $0.clips[1].style.text = "Changed" }
        XCTAssertEqual(store.selectedClip?.style.text,"Changed","and the edit")
    }

    /// The timeline is drawn again only when something it shows changes.
    func testTheTimelineIsRedrawnOnlyForWhatItShows() async throws {
        var id = UUID()
        let rig = TimelineRig { project in let a = Clip(name:"A",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:2)); id = a.id; project.clips = [a] }
        defer { rig.close() }
        let store = rig.store, canvas = rig.canvas
        canvas.redrawIfChanged(); canvas.displayIfNeeded()
        XCTAssertFalse(canvas.needsDisplay)
        store.status = "A note"; store.isBuilding = true; store.isBuilding = false
        canvas.redrawIfChanged()
        XCTAssertFalse(canvas.needsDisplay,"nothing it shows changed")
        store.edit("Move clip") { $0.clips[0].start = .init(seconds:1) }
        canvas.redrawIfChanged()
        XCTAssertTrue(canvas.needsDisplay,"a clip moved"); canvas.displayIfNeeded()
        store.selectedClipID = id; canvas.redrawIfChanged()
        XCTAssertTrue(canvas.needsDisplay,"a clip picked"); canvas.displayIfNeeded()
        store.zoom = 90; canvas.redrawIfChanged()
        XCTAssertTrue(canvas.needsDisplay,"zoomed")
    }

    /// A rebuilt preview never shows a blank moment: the frame on screen is held over it from the
    /// moment the new player item replaces the old until the new one's frame has landed.
    func testTheLastFrameIsHeldWhileTheNewItemComesUp() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        var title = Clip(name:"T",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:3)); title.style.text = "Hello"
        XCTAssertTrue(store.edit("Fixture") { $0.clips = [title] })
        defer { store.pause() }
        try await built(store); try await spin(400)                              // its frame drawn
        XCTAssertNil(store.heldFrame.value)
        var events: [String] = []
        let holds = store.heldFrame.dropFirst().sink { events.append($0.map { "held \($0.width)" } ?? "released") }
        let swaps = store.player.observe(\.currentItem,options:[.new]) { _,_ in MainActor.assumeIsolated { events.append("swap") } }
        defer { holds.cancel(); swaps.invalidate() }
        store.edit("Move clip") { $0.clips[0].start = .init(seconds:1) }
        try await built(store)
        XCTAssertEqual(events,["held 1920","swap"],"held before the swap")
        XCTAssertTrue(store.previewIsSettling)
        XCTAssertNotNil(store.heldFrame.value,"until the new frame lands")
        for _ in 0..<300 where store.heldFrame.value != nil { try await spin(10) }
        XCTAssertEqual(events,["held 1920","swap","released"])
        XCTAssertFalse(store.previewIsSettling)
        // An emptied preview holds nothing.
        store.edit("Delete") { $0.clips = [] }
        XCTAssertNil(store.player.currentItem); XCTAssertNil(store.heldFrame.value)
    }

    /// The held frame sits between the player and the transform overlay, takes no clicks, shows
    /// at once and fades out.
    func testTheHeldFrameShowsAtOnceAndFadesOut() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        let view = PreviewEditorView(store:store); view.frame = NSRect(x:0,y:0,width:320,height:180); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.subviews.map { ObjectIdentifier($0) },[view.playerView,view.held,view.overlay].map { ObjectIdentifier($0) })
        XCTAssertEqual(view.held.frame,view.bounds)
        XCTAssertNil(view.held.hitTest(NSPoint(x:100,y:100)))
        XCTAssertTrue(view.held.isHidden)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil,16,9,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:] as CFDictionary] as CFDictionary,&buffer)
        let still = try XCTUnwrap(buffer.flatMap(PreviewFrame.init))
        store.heldFrame.send(still)
        XCTAssertFalse(view.held.isHidden); XCTAssertEqual(view.held.layer?.opacity,1)
        XCTAssertTrue((view.held.layer?.contents as AnyObject?) === still.surface,"the player's own surface: nothing copied")
        XCTAssertTrue(view.held.shown?.buffer === still.buffer,"kept while shown")
        store.heldFrame.send(nil)
        XCTAssertEqual(view.held.layer?.opacity,0,"fading")
        XCTAssertEqual((view.held.layer?.animation(forKey:"fade") as? CABasicAnimation)?.duration,HeldFrameView.fade)
        // Held again mid-fade: back at once.
        store.heldFrame.send(still)
        XCTAssertEqual(view.held.layer?.opacity,1); XCTAssertNil(view.held.layer?.animation(forKey:"fade"))
    }

    /// "Updating preview" stays out of sight for a build quick enough to pass unnoticed.
    func testTheBuildingNoteOnlyShowsForALongBuild() async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView:BuildingNote().frame(width:240,height:80))
        host.frame = NSRect(x:0,y:0,width:240,height:80)
        let window = NSWindow(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func inked() -> Int {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { return 0 }
            host.cacheDisplay(in:host.bounds,to:rep)
            var count = 0
            for x in stride(from:0,to:rep.pixelsWide,by:2) { for y in stride(from:0,to:rep.pixelsHigh,by:2) where (rep.colorAt(x:x,y:y)?.alphaComponent ?? 0) > 0.3 { count += 1 } }
            return count
        }
        try await spin(100)
        XCTAssertEqual(inked(),0,"not yet")
        try await spin(800)
        XCTAssertGreaterThan(inked(),50,"shown once the build runs long")
    }
}
