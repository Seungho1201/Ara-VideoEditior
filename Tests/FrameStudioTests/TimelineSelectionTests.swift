import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

@MainActor private final class SelectionTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// Several clips selected on the timeline: Shift-drag, Shift-click, and what they do together.
final class TimelineSelectionTests: XCTestCase {
    /// Titles: A on V1 1–3 s, B on V2 2–4 s, C on V1 6–8 s. 60 pt per second.
    @MainActor private func withTimeline(_ check: (EditorStore, TimelineCanvas, [String:UUID]) throws -> Void) throws {
        _ = NSApplication.shared
        let store = EditorStore()
        let restore = unfoldingEverySound(store); defer { restore() }
        let pasteboard = NSPasteboard(name:.init("ara-selection-tests-\(UUID().uuidString)"))
        store.pasteboard = pasteboard                    // never the user's clipboard
        let a = Clip(name:"A",kind:.text,lane:.v1,start:.init(seconds:1),duration:.init(seconds:2))
        let b = Clip(name:"B",kind:.text,lane:.v2,start:.init(seconds:2),duration:.init(seconds:2))
        let c = Clip(name:"C",kind:.text,lane:.v1,start:.init(seconds:6),duration:.init(seconds:2))
        store.edit("Fixture") { project in project.frameRate = .init(30); project.clips = [a,b,c] }
        store.isBuilding = false
        let window = SelectionTestWindow(contentRect:NSRect(x:0,y:0,width:900,height:400),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let canvas = TimelineCanvas(frame:NSRect(x:0,y:0,width:900,height:400))
        canvas.store = store; canvas.pixelsPerSecond = 60
        canvas.pressedMouseButtons = { 0 }
        window.contentView = canvas
        defer { window.contentView = nil; window.close(); pasteboard.releaseGlobally() }
        try check(store,canvas,["A":a.id,"B":b.id,"C":c.id])
    }
    /// Row middles (31 pt down each picture's row): V2 at the top, then its sound A2, then V1.
    private static let tracks = TrackLayout(videoTracks:2,audioTracks:2,folded:[],top:TimelineCanvas.ruler+TimelineCanvas.addBand)
    private let v2 = tracks.row(.v2)!.top+31, v1 = tracks.row(.v1)!.top+31
    @MainActor private func mouse(_ type: NSEvent.EventType, _ seconds: Double, _ y: Double, _ flags: NSEvent.ModifierFlags = [], on canvas: TimelineCanvas) -> NSEvent {
        NSEvent.mouseEvent(with:type,location:canvas.convert(NSPoint(x:seconds*60,y:y),to:nil),modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,
                           windowNumber:canvas.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }
    @MainActor private func click(_ seconds: Double, _ y: Double, _ flags: NSEvent.ModifierFlags = [], on canvas: TimelineCanvas) {
        canvas.mouseDown(with:mouse(.leftMouseDown,seconds,y,flags,on:canvas)); canvas.mouseUp(with:mouse(.leftMouseUp,seconds,y,flags,on:canvas))
    }
    @MainActor private func key(_ code: UInt16, _ characters: String, on canvas: TimelineCanvas) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:canvas.window!.windowNumber,
                         context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
    }

    @MainActor func testShiftDragAndShiftClickBuildASelection() throws {
        try withTimeline { store, canvas, id in
            // Shift-drag from empty V2 space at 0.5 s to V1 at 3.5 s: touches A and B, not C.
            canvas.mouseDown(with:mouse(.leftMouseDown,0.5,v2-20,.shift,on:canvas))
            canvas.mouseDragged(with:mouse(.leftMouseDragged,3.5,v1,.shift,on:canvas))
            XCTAssertEqual(store.selectionForEditing,[id["A"]!,id["B"]!],"selected while dragging")
            canvas.mouseUp(with:mouse(.leftMouseUp,3.5,v1,.shift,on:canvas))
            XCTAssertTrue(store.hasMultipleSelection)
            XCTAssertNil(store.selectedClipID,"no single clip for the inspector")
            XCTAssertEqual(store.playhead,.zero,"a Shift-drag is not a scrub")
            // Shift-click adds C, then takes B out.
            click(7,v1,.shift,on:canvas)
            XCTAssertEqual(store.selectionForEditing,[id["A"]!,id["B"]!,id["C"]!])
            click(3,v2,.shift,on:canvas)
            XCTAssertEqual(store.selectionForEditing,[id["A"]!,id["C"]!])
            // A plain click on one of them picks just that one.
            click(2,v1,on:canvas)
            XCTAssertEqual(store.selectedClipID,id["A"]); XCTAssertEqual(store.selectionForEditing,[id["A"]!])
            // Esc clears a multiple selection; ⌘A selects everything.
            store.selectClips([id["A"]!,id["C"]!])
            canvas.keyDown(with:key(53,"\u{1b}",on:canvas))
            XCTAssertTrue(store.selectionForEditing.isEmpty)
            canvas.selectAll(nil)
            XCTAssertEqual(store.selectionForEditing,Set(id.values))
        }
    }

    @MainActor func testDraggingOneOfSeveralMovesThemAllAsOneStep() throws {
        try withTimeline { store, canvas, id in
            store.selectClips([id["A"]!,id["C"]!])
            let before = store.project
            canvas.mouseDown(with:mouse(.leftMouseDown,2,v1,on:canvas))
            canvas.mouseDragged(with:mouse(.leftMouseDragged,2.5,v1,on:canvas))
            canvas.mouseDragged(with:mouse(.leftMouseDragged,3,v1,on:canvas))
            canvas.mouseUp(with:mouse(.leftMouseUp,3,v1,on:canvas))
            let start = { (name: String) -> Double in store.project.clips.first { $0.id == id[name] }!.start.seconds }
            XCTAssertEqual(start("A"),2,accuracy:1e-9); XCTAssertEqual(start("C"),7,accuracy:1e-9)
            XCTAssertEqual(start("B"),2,accuracy:1e-9,"B was not selected")
            XCTAssertEqual(store.undoName,"Move clips")
            XCTAssertTrue(store.hasMultipleSelection,"still selected together")
            store.undo(); XCTAssertEqual(store.project,before)
        }
    }

    @MainActor func testSeveralClipsDeleteCopyPasteAndCutTogether() throws {
        try withTimeline { store, canvas, id in
            store.selectClips([id["A"]!,id["C"]!])
            XCTAssertTrue(store.canCopyClip)
            XCTAssertTrue(store.copySelection())
            store.seek(.init(seconds:8))                                  // the end of the timeline
            store.pasteClips()
            let pasted = store.project.clips.filter { !id.values.contains($0.id) }
            XCTAssertEqual(pasted.map(\.start.seconds).sorted(),[8,13],"at the playhead, 5 s apart as copied")
            XCTAssertEqual(Set(pasted.map(\.lane)),[.v1])
            XCTAssertEqual(store.selectionForEditing,Set(pasted.map(\.id)),"the pasted clips are selected together")
            XCTAssertEqual(store.undoName,"Paste clips")
            // Delete takes both, as one step.
            canvas.keyDown(with:key(51,"\u{7f}",on:canvas))
            XCTAssertEqual(Set(store.project.clips.map(\.id)),Set(id.values))
            XCTAssertEqual(store.undoName,"Delete clips")
            // Cut: gone, and on the clipboard to paste back.
            store.selectClips([id["B"]!])
            store.cutSelection()
            XCTAssertNil(store.project.clips.first { $0.id == id["B"] })
            XCTAssertEqual(store.undoName,"Cut clip")
            store.seek(.init(seconds:4)); store.pasteClips()
            XCTAssertEqual(store.project.clips.filter { $0.lane == .v2 }.map(\.start.seconds),[4])
        }
    }

    @MainActor func testUndoKeepsTheSelectionHonest() throws {
        try withTimeline { store, canvas, id in
            store.selectClips([id["A"]!])
            store.addText()                                            // a new title T, selected
            let t = try XCTUnwrap(store.selectedClipID)
            store.selectClips([id["A"]!,t])
            XCTAssertTrue(store.hasMultipleSelection)
            store.undo()                                               // T is gone again
            XCTAssertEqual(store.selectedClipID,id["A"],"the survivor is the selection, with its inspector")
            XCTAssertEqual(store.selectedClipIDs,[id["A"]!])
            canvas.keyDown(with:key(51,"\u{7f}",on:canvas))
            XCTAssertNil(store.project.clips.first { $0.id == id["A"] },"and Delete acts on what is drawn selected")
        }
    }

    @MainActor func testAVideoAndItsLinkedAudioAreOneSelection() throws {
        _ = NSApplication.shared
        let store = EditorStore()
        let restore = unfoldingEverySound(store); defer { restore() }
        store.pasteboard = NSPasteboard(name:.init("ara-selection-tests-\(UUID().uuidString)"))
        defer { store.pasteboard.releaseGlobally() }
        let media = MediaReference(name:"Clip",path:"/nonexistent/clip.mov",bookmark:nil,kind:.video,duration:.init(seconds:10),width:1920,height:1080,frameRate:30,hasAudio:true)
        var video: UUID?
        store.edit("Fixture") { project in project.media = [media]; video = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project) }
        store.isBuilding = false
        let pair = Set(store.project.group(for:try XCTUnwrap(video)).map(\.id))
        XCTAssertEqual(pair.count,2)
        store.selectClips(pair)                                        // what ⌘A or a marquee over V1 and A1 gives
        XCTAssertFalse(store.hasMultipleSelection)
        XCTAssertEqual(store.selectedClipID,video,"the picture half, with its inspector")
        store.selectAllClips()
        XCTAssertEqual(store.selectedClipID,video)
    }

    @MainActor func testShiftOverATransitionStillChoosesClipsAndAMarqueeClearsAGap() throws {
        try withTimeline { store, canvas, id in
            store.edit("Fade") { project in _ = try Editing.setTransition(.crossDissolve,direction:.left,duration:.init(seconds:1),from:nil,to:id["C"]!,in:&project) }
            store.selectClips([id["A"]!,id["B"]!])
            // Shift-click C where its fade-in strip is (the lower part of the row, at its start).
            click(6.3,v1+18,.shift,on:canvas)
            XCTAssertEqual(store.selectionForEditing,[id["A"]!,id["B"]!,id["C"]!],"added, not replaced by the transition")
            XCTAssertNil(store.selectedTransitionID)
            // A gap selected, then a marquee that touches one clip: the clip, not both.
            store.selectClips([])
            store.selectGap(Editing.gap(on:.v1,at:.init(seconds:4.5),in:store.project))
            XCTAssertNotNil(store.selectedGap)
            canvas.mouseDown(with:mouse(.leftMouseDown,5.5,v2-20,.shift,on:canvas))
            canvas.mouseDragged(with:mouse(.leftMouseDragged,6.5,v1,.shift,on:canvas))
            canvas.mouseUp(with:mouse(.leftMouseUp,6.5,v1,.shift,on:canvas))
            XCTAssertEqual(store.selectedClipID,id["C"])
            XCTAssertNil(store.selectedGap)
        }
    }

    @MainActor func testCommandLettersFollowTheLayoutNotTheKeyPosition() {
        _ = NSApplication.shared
        func event(_ characters: String, keyCode: UInt16) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:0,context:nil,
                             characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:keyCode)!
        }
        // AZERTY ⌘Q is the A key; Dvorak ⌘Q is the X key: neither is Select All or Cut.
        XCTAssertFalse(TimelineCanvas.isCommand(event("q",keyCode:0),"a",keyCode:0))
        XCTAssertFalse(TimelineCanvas.isCommand(event("q",keyCode:7),"x",keyCode:7))
        XCTAssertTrue(TimelineCanvas.isCommand(event("x",keyCode:12),"x",keyCode:7),"Dvorak ⌘X")
        // A Korean input source types Hangul: the physical key decides.
        XCTAssertTrue(TimelineCanvas.isCommand(event("ㅁ",keyCode:0),"a",keyCode:0))
        XCTAssertTrue(TimelineCanvas.isCommand(event("ㅌ",keyCode:7),"x",keyCode:7))
    }

    @MainActor func testTheToolbarRectangleSelectWorksOnceWithoutShift() throws {
        try withTimeline { store, canvas, id in
            store.selectClips([id["C"]!])
            store.dragSelectArmed = true
            // A plain drag that starts on A (which would move it) draws a rectangle over A and B.
            let before = store.project
            canvas.mouseDown(with:mouse(.leftMouseDown,1.5,v1,on:canvas))
            canvas.mouseDragged(with:mouse(.leftMouseDragged,3.5,v2-20,on:canvas))
            canvas.mouseUp(with:mouse(.leftMouseUp,3.5,v2-20,on:canvas))
            XCTAssertEqual(store.selectionForEditing,[id["A"]!,id["B"]!],"the new rectangle replaces the old selection")
            XCTAssertEqual(store.project,before,"nothing moved")
            XCTAssertFalse(store.dragSelectArmed,"one drag, then it is off")
            // The next plain drag is an ordinary one again: it moves the selected clips.
            canvas.mouseDown(with:mouse(.leftMouseDown,2,v1,on:canvas))
            canvas.mouseDragged(with:mouse(.leftMouseDragged,2.5,v1,on:canvas))
            canvas.mouseUp(with:mouse(.leftMouseUp,2.5,v1,on:canvas))
            XCTAssertEqual(store.undoName,"Move clips")
            // Esc switches it off without touching the selection.
            let selection = store.selectionForEditing
            store.dragSelectArmed = true
            canvas.keyDown(with:key(53,"\u{1b}",on:canvas))
            XCTAssertFalse(store.dragSelectArmed); XCTAssertEqual(store.selectionForEditing,selection)
            // With Shift as well, the rectangle adds to what is selected.
            store.selectClips([id["C"]!]); store.dragSelectArmed = true
            canvas.mouseDown(with:mouse(.leftMouseDown,4.5,v2,.shift,on:canvas))
            canvas.mouseDragged(with:mouse(.leftMouseDragged,3.9,v2,.shift,on:canvas))
            canvas.mouseUp(with:mouse(.leftMouseUp,3.9,v2,.shift,on:canvas))
            XCTAssertEqual(store.selectionForEditing,[id["B"]!,id["C"]!])
        }
    }

    @MainActor func testPastingOverATitleGoesOnANewTrackInsteadOfFailing() throws {
        try withTimeline { store, canvas, id in
            store.selectClips([id["B"]!])                       // the title on V2, 2–4 s
            XCTAssertTrue(store.copySelection())
            store.seek(.init(seconds:2.5))
            store.message = nil
            store.pasteClips()
            XCTAssertNil(store.message,"no 'occupied' alert")
            let pasted = try XCTUnwrap(store.selectedClip)
            XCTAssertEqual(pasted.start.seconds,2.5,accuracy:1e-9,"at the playhead")
            XCTAssertEqual(pasted.lane,Lane(.video,3),"on a new track above the one in use")
            XCTAssertEqual(store.project.videoTrackCount,3)
            // Again: V2 and V3 are both in use there now, so V4.
            store.pasteClips()
            XCTAssertEqual(store.selectedClip?.lane,Lane(.video,4))
        }
    }
}
