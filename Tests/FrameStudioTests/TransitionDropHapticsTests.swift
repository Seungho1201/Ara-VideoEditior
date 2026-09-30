import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

/// A transition tile dragged from the library, over the timeline, with an isolated pasteboard.
@MainActor private final class TransitionDropInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingDestinationWindow: NSWindow?
    var draggingLocation = NSPoint.zero
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    /// Over V1 (its row's middle) at this many seconds, 60 pt per second.
    /// Over V1's picture, or its sound, `seconds` in.
    func move(_ seconds: Double, on canvas: TimelineCanvas, lane: Lane = .v1) {
        draggingLocation = canvas.convert(NSPoint(x:seconds*60,y:canvas.trackLayout.row(lane)!.top+20),to:nil)
    }
}

final class TransitionDropHapticsTests: XCTestCase {
    /// Titles A 0–3 s and B 3–6 s meeting on V1 (a cut at 3 s), and C 8–10 s.
    @MainActor private func drag(haptics: Bool, _ steps: (TransitionDropInfo, TimelineCanvas, EditorStore) -> Void) -> [NSHapticFeedbackManager.FeedbackPattern] {
        _ = NSApplication.shared
        let store = EditorStore(), saved = UserDefaults.standard.object(forKey:"timeline.scrubHaptics")
        store.scrubHaptics = haptics
        store.edit("Fixture") { project in
            project.frameRate = .init(30)
            project.clips = [Clip(name:"A",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3)),
                             Clip(name:"B",kind:.text,lane:.v1,start:.init(seconds:3),duration:.init(seconds:3)),
                             Clip(name:"C",kind:.text,lane:.v1,start:.init(seconds:8),duration:.init(seconds:2))]
        }
        store.isBuilding = false
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:400),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let canvas = TimelineCanvas(frame:NSRect(x:0,y:0,width:900,height:400))
        canvas.store = store; canvas.pixelsPerSecond = 60
        window.contentView = canvas
        let info = TransitionDropInfo(); info.draggingDestinationWindow = window
        info.draggingPasteboard.setString(TransitionKind.crossDissolve.rawValue,forType:TransitionDrag.pasteboardType)
        var cues: [NSHapticFeedbackManager.FeedbackPattern] = []
        canvas.performHaptic = { cues.append($0) }
        defer {
            info.draggingPasteboard.releaseGlobally(); window.contentView = nil; window.close()
            if let saved { UserDefaults.standard.set(saved,forKey:"timeline.scrubHaptics") } else { UserDefaults.standard.removeObject(forKey:"timeline.scrubHaptics") }
        }
        steps(info,canvas,store)
        return cues
    }

    @MainActor func testEachNewEdgeTicksAndADropConfirms() {
        let cues = drag(haptics:true) { info, canvas, store in
            info.move(0.8,on:canvas)                                   // over A, nearest its start: a fade in
            XCTAssertEqual(canvas.draggingEntered(info),.copy)
            for x in [0.9,1.0,1.1] { info.move(x,on:canvas); _ = canvas.draggingUpdated(info) }   // same edge: quiet
            info.move(2.6,on:canvas); _ = canvas.draggingUpdated(info) // the cut between A and B
            for x in [2.7,2.9,3.2] { info.move(x,on:canvas); _ = canvas.draggingUpdated(info) }
            XCTAssertTrue(canvas.performDragOperation(info))
            XCTAssertEqual(store.project.transitions.first.map { [$0.from,$0.to].compactMap { $0 }.count },2,"dropped on the cut")
        }
        XCTAssertEqual(cues,[.alignment,.alignment,.generic])
    }

    /// V1's sound is part of V1: a transition let go over it goes on the picture's cut above.
    @MainActor func testATransitionOverATracksSoundGoesOnItsPicture() {
        _ = drag(haptics:false) { info, canvas, store in
            info.move(2.6,on:canvas,lane:.a1)
            XCTAssertEqual(canvas.draggingEntered(info),.copy)
            XCTAssertTrue(canvas.performDragOperation(info))
            let names = store.project.transitions.first.map { [$0.from,$0.to].compactMap { id in store.project.clips.first { $0.id == id }?.name } }
            XCTAssertEqual(names,["A","B"])
        }
    }

    @MainActor func testNothingWithHapticsOff() {
        let cues = drag(haptics:false) { info, canvas, _ in
            info.move(0.8,on:canvas); _ = canvas.draggingEntered(info)
            info.move(2.6,on:canvas); _ = canvas.draggingUpdated(info)
            _ = canvas.performDragOperation(info)
        }
        XCTAssertEqual(cues,[])
    }
}
