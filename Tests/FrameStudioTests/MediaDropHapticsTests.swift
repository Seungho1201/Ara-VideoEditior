import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

/// Calls the native drag destination with an isolated pasteboard and hidden window.
@MainActor private final class LibraryDropInfo: NSObject, NSDraggingInfo {
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
    /// Over x on the canvas; by default in the middle of V1's picture.
    func move(x: Double, y: Double? = nil, on canvas: TimelineCanvas) {
        draggingLocation = canvas.convert(NSPoint(x:x,y:y ?? canvas.trackLayout.row(.v1)!.top+31),to:nil)
    }
}

final class MediaDropHapticsTests: XCTestCase {
    @MainActor private func withTimeline(_ check: (EditorStore, TimelineCanvas, LibraryDropInfo, UUID) throws -> Void) rethrows {
        _ = NSApplication.shared
        let store = EditorStore(), oldHaptics = UserDefaults.standard.object(forKey:"timeline.scrubHaptics")
        store.scrubHaptics = true
        let media = MediaReference(name:"Drop fixture",path:"/nonexistent/ara-drop-fixture.mov",kind:.video,
                                   duration:.init(seconds:1),width:1920,height:1080,frameRate:30,hasAudio:true)
        XCTAssertTrue(store.edit("Fixture") { project in
            project.media = [media]; project.audioTrackCount = 3         // A3: an audio track of its own, at the bottom
            project.clips = [Clip(name:"Existing",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:10))]
        })
        store.resumeEditing(); store.isBuilding = false
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:480),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let canvas = TimelineCanvas(frame:NSRect(x:0,y:0,width:900,height:480))
        canvas.store = store; canvas.pixelsPerSecond = 60
        window.contentView = canvas
        let info = LibraryDropInfo(); info.draggingDestinationWindow = window
        info.draggingPasteboard.setString(media.id.uuidString,forType:.string)
        canvas.performHaptic = { _ in XCTFail("Unexpected hardware cue") }
        defer {
            info.draggingPasteboard.releaseGlobally()
            window.contentView = nil; window.close()
            if let oldHaptics { UserDefaults.standard.set(oldHaptics,forKey:"timeline.scrubHaptics") }
            else { UserDefaults.standard.removeObject(forKey:"timeline.scrubHaptics") }
        }
        try check(store,canvas,info,media.id)
    }

    @MainActor func testEntryAlignmentAndCommittedDropWithLinkedAudioAndUndo() {
        withTimeline { store, canvas, info, mediaID in
            let before = store.project
            var cues: [NSHapticFeedbackManager.FeedbackPattern] = []
            canvas.performHaptic = { cues.append($0) }
            info.move(x:720,on:canvas)
            XCTAssertEqual(canvas.draggingEntered(info),.copy)
            // Continuous pointer movement and AppKit's stationary updates stay quiet.
            for x in 720...735 { info.move(x:Double(x),on:canvas); XCTAssertEqual(canvas.draggingUpdated(info),.copy) }
            XCTAssertEqual(cues,[.generic])
            // Exact alignment counts, even though snapping need not move the pointer.
            info.move(x:600,on:canvas)
            XCTAssertEqual(canvas.draggingUpdated(info),.copy)
            for _ in 0..<5 { _ = canvas.draggingUpdated(info) }
            XCTAssertEqual(cues,[.generic,.alignment])
            XCTAssertEqual(store.project,before)
            XCTAssertTrue(canvas.performDragOperation(info))
            XCTAssertEqual(cues,[.generic,.alignment,.generic])
            let added = store.project.clips.filter { $0.mediaID == mediaID }
            XCTAssertEqual(added.count,2)
            XCTAssertEqual(Set(added.map(\.lane)),[.v1,.a1])
            XCTAssertTrue(added.allSatisfy { $0.start == .init(seconds:10) && $0.duration == .init(seconds:1) })
            XCTAssertNotNil(added.first?.linkID)
            XCTAssertEqual(added[0].linkID,added[1].linkID)
            store.undo(); XCTAssertEqual(store.project,before)
        }
    }

    /// A track's picture and sound are one track: a video let go over V1's sound goes on V1 (its
    /// sound under it), and an audio file let go over V1's picture goes in its sound.
    @MainActor func testMediaDroppedOnEitherHalfOfATrackGoesWhereItBelongs() {
        withTimeline { store, canvas, info, mediaID in
            canvas.performHaptic = { _ in }
            info.move(x:720,y:canvas.trackLayout.row(.a1)!.top+20,on:canvas)
            XCTAssertEqual(canvas.draggingEntered(info),.copy)
            XCTAssertTrue(canvas.performDragOperation(info))
            XCTAssertEqual(Set(store.project.clips.filter { $0.mediaID == mediaID }.map(\.lane)),[.v1,.a1])
            let song = MediaReference(name:"Song",path:"/nonexistent/ara-drop-song.m4a",kind:.audio,duration:.init(seconds:2),hasAudio:true)
            XCTAssertTrue(store.edit("Song") { $0.media.append(song) })
            info.draggingPasteboard.clearContents(); info.draggingPasteboard.setString(song.id.uuidString,forType:.string)
            info.draggingSequenceNumber += 1
            info.move(x:840,on:canvas)
            XCTAssertEqual(canvas.draggingEntered(info),.copy)
            XCTAssertTrue(canvas.performDragOperation(info))
            XCTAssertEqual(store.project.clips.first { $0.mediaID == song.id }?.lane,.a1)
        }
    }

    @MainActor func testInvalidTargetsAndStaleDropDoNotEmitSuccessOrMutateProject() {
        withTimeline { store, canvas, info, mediaID in
            let before = store.project
            var cues: [NSHapticFeedbackManager.FeedbackPattern] = []
            canvas.performHaptic = { cues.append($0) }
            info.move(x:720,y:canvas.trackLayout.row(Lane(.audio,3))!.top+31,on:canvas) // Video cannot land on A3, an audio track of its own.
            XCTAssertEqual(canvas.draggingEntered(info),[])
            info.move(x:300,on:canvas) // Existing V1 footage blocks this position.
            XCTAssertEqual(canvas.draggingUpdated(info),[])
            XCTAssertTrue(cues.isEmpty)
            info.move(x:720,on:canvas)
            XCTAssertEqual(canvas.draggingUpdated(info),.copy)
            XCTAssertEqual(cues,[.generic])
            store.missing.insert(mediaID)
            XCTAssertFalse(canvas.performDragOperation(info))
            XCTAssertEqual(cues,[.generic]); XCTAssertEqual(store.project,before)
            store.missing.remove(mediaID); store.isExporting = true
            XCTAssertFalse(canvas.performDragOperation(info))
            XCTAssertEqual(cues,[.generic]); XCTAssertEqual(store.project,before)
        }
    }

    @MainActor func testReleaseLocationIsRevalidatedWithHapticsDisabled() {
        withTimeline { store, canvas, info, mediaID in
            store.scrubHaptics = false
            info.move(x:720,on:canvas)
            XCTAssertEqual(canvas.draggingEntered(info),.copy)
            info.move(x:780,on:canvas) // Mouse-up can arrive before another draggingUpdated.
            XCTAssertTrue(canvas.performDragOperation(info))
            XCTAssertTrue(store.project.clips.filter { $0.mediaID == mediaID }.allSatisfy { $0.start == .init(seconds:13) })
        }
    }

    @MainActor func testCancelAndNextSessionDoNotReusePlacementOrFeedbackLatch() {
        withTimeline { store, canvas, info, _ in
            let before = store.project
            var cues: [NSHapticFeedbackManager.FeedbackPattern] = []
            canvas.performHaptic = { cues.append($0) }
            info.move(x:600,on:canvas)
            XCTAssertEqual(canvas.draggingEntered(info),.copy)
            canvas.draggingExited(info); canvas.draggingEnded(info)
            XCTAssertEqual(store.project,before); XCTAssertEqual(cues,[.alignment])
            info.draggingSequenceNumber += 1
            XCTAssertEqual(canvas.draggingEntered(info),.copy)
            XCTAssertEqual(cues,[.alignment,.alignment])
            info.move(x:600,y:10,on:canvas) // Release outside the tracks.
            XCTAssertFalse(canvas.performDragOperation(info))
            XCTAssertEqual(store.project,before); XCTAssertEqual(cues.count,2)
        }
    }

    func testTrackChangesAndBoundaryJitterAreCoalesced() {
        let id = UUID()
        func target(_ lane: Lane, _ snap: Double? = nil) -> MediaDropTarget {
            MediaDropTarget(id:id,lane:lane,time:.init(seconds:snap ?? 12),snappedTime:snap.map { .init(seconds:$0) })
        }
        var feedback = MediaDropFeedback()
        XCTAssertEqual(feedback.cue(for:target(.v1),at:0,enabled:true),.generic)
        XCTAssertNil(feedback.cue(for:target(.v1),at:1,enabled:true))
        XCTAssertEqual(feedback.cue(for:target(.v2),at:2,enabled:true),.generic)
        XCTAssertEqual(feedback.cue(for:target(.v2,10),at:2.01,enabled:true),.alignment)
        XCTAssertNil(feedback.cue(for:nil,at:2.02,enabled:true))
        XCTAssertNil(feedback.cue(for:target(.v2,10),at:2.03,enabled:true))
        XCTAssertNil(feedback.cue(for:target(.v2),at:2.04,enabled:true))
        XCTAssertEqual(feedback.cue(for:target(.v2,10),at:2.3,enabled:true),.alignment)
        XCTAssertNil(feedback.cue(for:target(.v1),at:3,enabled:false))
        XCTAssertNil(feedback.cue(for:target(.v1,10),at:4,enabled:false))
    }
}
