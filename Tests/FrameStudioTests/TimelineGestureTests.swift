import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

@MainActor private final class RigWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// A timeline canvas in a hidden window with its own store: a private pasteboard, shortcut
/// settings of its own, captured haptics and synthesized events. The app's timeline settings are
/// put back when it closes.
@MainActor final class TimelineRig {
    let store = EditorStore()
    let canvas: TimelineCanvas
    let window: NSWindow
    var cues: [NSHapticFeedbackManager.FeedbackPattern] = []
    static let pps = 60.0, rulerY = 10.0
    private static let keys = ["timeline.snapping","timeline.scrubHaptics","haptics.off","haptics.skimStrength"]
    private let saved: [String:Any]
    private let suite = "ara.tests.timeline.\(UUID().uuidString)"
    private var now: TimeInterval = 1000
    init(width: CGFloat = 1200, height: CGFloat = 400, _ fixture: (inout Project) throws -> Void) {
        _ = NSApplication.shared
        saved = Self.keys.reduce(into:[:]) { values, key in values[key] = UserDefaults.standard.object(forKey:key) }
        store.pasteboard = NSPasteboard(name:.init("ara-timeline-rig-\(UUID().uuidString)"))    // never the user's clipboard
        store.shortcuts = ShortcutSettings(defaults:UserDefaults(suiteName:suite)!)
        store.runAlert = { alert in XCTFail("Unexpected question: \(alert.messageText)"); return .alertSecondButtonReturn }
        let made = store.edit("Fixture") { project in project.frameRate = .init(30); try fixture(&project) }
        XCTAssertTrue(made,store.message ?? "")
        store.isBuilding = false; store.message = nil
        store.snapping = true; store.scrubHaptics = true; store.hapticsOff = []
        window = RigWindow(contentRect:NSRect(x:0,y:0,width:width,height:height),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        canvas = TimelineCanvas(frame:NSRect(x:0,y:0,width:width,height:height))
        canvas.store = store; canvas.pixelsPerSecond = Self.pps
        canvas.pressedMouseButtons = { 0 }
        window.contentView = canvas
        canvas.performHaptic = { [unowned self] in self.cues.append($0) }
        window.makeFirstResponder(canvas)
    }
    func close() {
        store.pause()
        window.contentView = nil; window.close()
        store.pasteboard.releaseGlobally()
        UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
        for key in Self.keys {
            if let value = saved[key] { UserDefaults.standard.set(value,forKey:key) } else { UserDefaults.standard.removeObject(forKey:key) }
        }
    }
    /// y in a track's row: 20 pt down is a clip's title band, 45 pt its transition strip.
    func y(_ lane: Lane, _ offset: Double = 20) -> Double {
        TimelineCanvas.ruler+TimelineCanvas.addBand+Double(store.project.displayLanes.firstIndex(of:lane)!)*TimelineCanvas.rowHeight+offset
    }
    func clip(_ id: UUID) -> Clip { store.project.clips.first { $0.id == id }! }
    func clip(_ name: String) -> Clip { store.project.clips.first { $0.name == name }! }
    private func mouse(_ type: NSEvent.EventType, _ seconds: Double, _ y: Double, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        now += 0.05
        return NSEvent.mouseEvent(with:type,location:canvas.convert(NSPoint(x:seconds*Self.pps,y:y),to:nil),modifierFlags:flags,timestamp:now,
                                  windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }
    func down(_ seconds: Double, _ y: Double, _ flags: NSEvent.ModifierFlags = []) { canvas.mouseDown(with:mouse(.leftMouseDown,seconds,y,flags)) }
    func drag(_ seconds: Double, _ y: Double, _ flags: NSEvent.ModifierFlags = []) { canvas.mouseDragged(with:mouse(.leftMouseDragged,seconds,y,flags)) }
    func up(_ seconds: Double, _ y: Double, _ flags: NSEvent.ModifierFlags = []) { canvas.mouseUp(with:mouse(.leftMouseUp,seconds,y,flags)) }
    /// Pressed at `from`, dragged through `path` on one row, let go at the end.
    func drag(from: Double, through path: [Double], y: Double) {
        down(from,y); for x in path { drag(x,y) }; up(path.last ?? from,y)
    }
    func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        now += 0.05
        return NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:now,windowNumber:window.windowNumber,
                                context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
    }
    func press(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) { canvas.keyDown(with:key(code,characters,flags)) }
    /// A ⌘-key as AppKit offers it first. True when the canvas took it.
    func commandKey(_ code: UInt16, _ characters: String) -> Bool { canvas.performKeyEquivalent(with:key(code,characters,.command)) }
    /// The canvas drawn into a bitmap, a pixel per point, its rows running down as the canvas's do.
    func paint() -> CGContext {
        let size = canvas.bounds.size
        let context = CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,
                                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        context.translateBy(x:0,y:size.height); context.scaleBy(x:1,y:-1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return context
    }
    /// Red, green and blue of a painted pixel.
    static func color(_ context: CGContext, _ x: Double, _ y: Double) -> (red: Int, green: Int, blue: Int) {
        let bytes = context.data!.assumingMemoryBound(to:UInt8.self), offset = Int(y)*context.bytesPerRow+Int(x)*4
        return (Int(bytes[offset]),Int(bytes[offset+1]),Int(bytes[offset+2]))
    }
    /// Ara's accent (#9ACBFF): selection outlines, the playhead and its badges.
    static func isAccent(_ context: CGContext, _ x: Double, _ y: Double) -> Bool {
        let c = color(context,x,y)
        return abs(c.red-154) < 16 && abs(c.green-203) < 16 && abs(c.blue-255) < 16
    }
}

/// A 20 s video with sound (a made-up path: nothing here decodes it).
func timelineTestVideo() -> MediaReference {
    MediaReference(name:"Source",path:"/nonexistent/ara-tests/Source.mov",kind:.video,duration:.init(seconds:20),
                   width:1920,height:1080,frameRate:30,hasAudio:true)
}

/// Dragging on the timeline: trims stop at their limits, a clip keeps its kind of track, the snap
/// tick only where the drag gets to, a rectangle-select click, and a drag the project changed under.
@MainActor final class TimelineGestureTests: XCTestCase {
    private func title(_ name: String, _ lane: Lane, _ start: Double, _ length: Double) -> Clip {
        Clip(name:name,kind:.text,lane:lane,start:.init(seconds:start),duration:.init(seconds:length))
    }
    private let frame = FrameRate(30).frame

    func testATrimDraggedPastALimitStopsThere() {
        var id = UUID()
        let rig = TimelineRig { project in
            let media = timelineTestVideo(); project.media = [media]
            id = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
            try Editing.trim(id,leading:false,to:.init(seconds:7),in:&project)
            try Editing.trim(id,leading:true,to:.init(seconds:2),in:&project)          // source 2–7 s: 2 s to spare before it
            try Editing.move(id,to:.init(seconds:4),lane:.v1,in:&project)              // at 4–9 s
            project.clips.append(self.title("B",.v1,12,2))
        }
        defer { rig.close() }
        rig.store.snapping = false
        // The start handle dragged 3 s out: it stops at the source's first frame, sound and all.
        rig.drag(from:4+3/60,through:[3,1+3/60],y:rig.y(.v1))
        XCTAssertEqual(rig.clip(id).start,.init(seconds:2)); XCTAssertEqual(rig.clip(id).sourceStart,.zero)
        XCTAssertEqual(Set(rig.store.project.group(for:id).map(\.start)),[.init(seconds:2)])
        XCTAssertEqual(rig.store.undoName,"Trim clip")
        // The end handle dragged into B and past it: it stops against B.
        rig.drag(from:9-3/60,through:[11,15],y:rig.y(.v1))
        XCTAssertEqual(rig.clip(id).end,.init(seconds:12))
        // Past a limit and back inside it: the edge follows the pointer again (pressed 3 pt inside it).
        rig.down(12-3/60,rig.y(.v1)); rig.drag(16,rig.y(.v1)); rig.drag(17,rig.y(.v1)); rig.drag(8-3/60,rig.y(.v1)); rig.up(8-3/60,rig.y(.v1))
        XCTAssertEqual(rig.clip(id).end,.init(seconds:8))
        // The end handle dragged past the clip's own start: one frame is the shortest.
        rig.drag(from:8-3/60,through:[5,0.5],y:rig.y(.v1))
        XCTAssertEqual(rig.clip(id).duration,frame); XCTAssertEqual(rig.clip(id).start,.init(seconds:2))
        XCTAssertNil(rig.store.message,"no alert on the way")
    }

    /// A camera file a little longer than its whole frames (10.01 s, added as 300 frames at 30 fps,
    /// its sound a few milliseconds past the picture): the end handle dragged far past it stops
    /// where the clip was added, sound and all.
    func testTheEndHandleStopsAtTheSourcesLastWholeFrame() {
        var id = UUID()
        let media = MediaReference(name:"Phone",path:"/nonexistent/ara-tests/Phone.mov",kind:.video,duration:.init(seconds:10.01),
                                   width:1920,height:1080,frameRate:30,hasAudio:true)
        let rig = TimelineRig { project in project.media = [media]; id = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project) }
        defer { rig.close() }
        rig.store.snapping = false
        rig.drag(from:10-3/60,through:[11,13],y:rig.y(.v1))
        XCTAssertEqual(Set(rig.store.project.group(for:id).map(\.end)),[.init(seconds:10)])
        XCTAssertNil(rig.store.message)
        // Shortened and dragged out again, it stops there too.
        rig.drag(from:10-3/60,through:[9-3/60],y:rig.y(.v1))
        XCTAssertEqual(rig.clip(id).end,.init(seconds:9))
        rig.drag(from:9-3/60,through:[12,14],y:rig.y(.v1))
        XCTAssertEqual(rig.clip(id).end,.init(seconds:10)); XCTAssertEqual(rig.store.undoName,"Trim clip")
    }

    func testAClipDraggedOverARowOfTheOtherKindKeepsItsTrack() {
        var id = UUID()
        let rig = TimelineRig { project in
            let media = timelineTestVideo(); project.media = [media]
            id = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
            try Editing.trim(id,leading:false,to:.init(seconds:5),in:&project)
        }
        defer { rig.close() }
        rig.store.snapping = false
        let audio = rig.store.project.group(for:id).first { $0.id != id }!.id
        // Grabbed low in its row and dragged 2 s right, drifting down onto A1 and on to A2.
        rig.down(2.5,rig.y(.v1,50)); rig.drag(3.5,rig.y(.v1,56)); rig.drag(4.5,rig.y(.a1,10)); rig.drag(4.5,rig.y(.a2))
        rig.up(4.5,rig.y(.a2))
        XCTAssertEqual(rig.clip(id).start,.init(seconds:2)); XCTAssertEqual(rig.clip(id).lane,.v1)
        XCTAssertEqual(rig.clip(audio).lane,.a1)
        XCTAssertEqual(rig.store.undoName,"Move clip")
        // Its sound dragged up over the video rows stays on A1 as well, and still moves in time.
        rig.down(3,rig.y(.a1)); rig.drag(3.5,rig.y(.v1)); rig.drag(4,rig.y(.v2)); rig.up(4,rig.y(.v2))
        XCTAssertEqual(rig.clip(audio).start,.init(seconds:3)); XCTAssertEqual(rig.clip(audio).lane,.a1); XCTAssertEqual(rig.clip(id).lane,.v1)
    }

    func testNoSnapTickWhereTheDraggedEdgeCannotGo() {
        var ids: [String:UUID] = [:]
        let rig = TimelineRig(width:1800) { project in
            // A 0–10 s fading in over 1 s; C | D at 12–15–18 s with a 1 s dissolve; E 20–25 s fading out over 1 s.
            let a = self.title("A",.v1,0,10), c = self.title("C",.v1,12,3), d = self.title("D",.v1,15,3), e = self.title("E",.v1,20,5)
            project.clips = [a,c,d,e]
            ids["in"] = try Editing.setTransition(.crossDissolve,duration:.init(seconds:1),from:nil,to:a.id,in:&project)
            ids["cut"] = try Editing.setTransition(.crossDissolve,duration:.init(seconds:1),from:c.id,to:d.id,in:&project)
            ids["out"] = try Editing.setTransition(.crossDissolve,duration:.init(seconds:1),from:e.id,to:nil,in:&project)
        }
        defer { rig.close() }
        func length(_ name: String) -> MediaTime { rig.store.project.transitions.first { $0.id == ids[name] }!.duration }
        let strip = rig.y(.v1,45)
        // The fade in's edge dragged to the playhead at 6 s: a transition is 5 s at most, so it stops short.
        rig.store.seek(.init(seconds:6))
        rig.drag(from:1-3/60,through:[3,5.95],y:strip)
        XCTAssertEqual(length("in"),Transition.longest); XCTAssertEqual(rig.cues,[],"no tick for the playhead it never reached")
        // Within reach it does catch the playhead, with one tick.
        rig.store.undo(); rig.store.seek(.init(seconds:4))
        rig.drag(from:1-3/60,through:[3,3.95],y:strip)
        XCTAssertEqual(length("in"),.init(seconds:4)); XCTAssertEqual(rig.cues,[.alignment])
        // Its own cut is no target: 0.1 s from it the dissolve follows the pointer (0.2 s long) instead
        // of shrinking to a frame.
        rig.cues = []; rig.store.seek(.zero)
        rig.drag(from:15.5-3/60,through:[15.3,15.05],y:strip)
        XCTAssertEqual(length("cut"),MediaTime(ticks:frame.ticks*6)); XCTAssertEqual(rig.cues,[])
        // Nor is a fade out's anchored end.
        rig.drag(from:24+3/60,through:[24.5,24.95],y:strip)
        XCTAssertEqual(length("out"),MediaTime(ticks:frame.ticks*3)); XCTAssertEqual(rig.cues,[])
        // A trim whose snap target lies past the next clip stops at the clip, without a tick.
        rig.store.seek(.init(seconds:13))
        rig.drag(from:10-3/60,through:[11,12.95],y:rig.y(.v1))
        XCTAssertEqual(rig.clip("A").end,.init(seconds:12)); XCTAssertEqual(rig.cues,[])
    }

    func testNoTickWhenAGroupIsStoppedShortOfItsSnapTarget() {
        let rig = TimelineRig { $0.clips = [self.title("A",.v1,1,2),self.title("B",.v2,3.5,2),self.title("Far",.v2,30,1)] }
        defer { rig.close() }
        let a = rig.clip("A").id, b = rig.clip("B").id
        // B's start dragged to the playhead at 0.5 s: A stops the group at the timeline's start first.
        rig.store.seek(.init(seconds:0.5)); rig.store.selectClips([a,b])
        rig.down(4.5,rig.y(.v2)); rig.drag(3.5,rig.y(.v2)); rig.drag(1.55,rig.y(.v2)); rig.up(1.55,rig.y(.v2))
        XCTAssertEqual(rig.clip(a).start,.zero); XCTAssertEqual(rig.clip(b).start,.init(seconds:2.5))
        XCTAssertEqual(rig.cues,[])
        // A playhead the group can reach gets its tick.
        rig.store.undo(); rig.store.seek(.init(seconds:3)); rig.store.selectClips([a,b])
        rig.down(4.5,rig.y(.v2)); rig.drag(4.2,rig.y(.v2)); rig.drag(4.05,rig.y(.v2)); rig.up(4.05,rig.y(.v2))
        XCTAssertEqual(rig.clip(a).start,.init(seconds:0.5)); XCTAssertEqual(rig.clip(b).start,.init(seconds:3))
        XCTAssertEqual(rig.cues,[.alignment])
    }

    func testRectangleSelectPressedWithoutADragPicksTheClipUnderIt() {
        let rig = TimelineRig { $0.clips = [self.title("A",.v1,1,2),self.title("B",.v2,2,2),self.title("C",.v1,6,2)] }
        defer { rig.close() }
        let a = rig.clip("A").id, b = rig.clip("B").id, c = rig.clip("C").id
        rig.store.selectClips([c]); rig.store.dragSelectArmed = true
        rig.down(2,rig.y(.v1)); rig.up(2,rig.y(.v1))
        XCTAssertEqual(rig.store.selectionForEditing,[a]); XCTAssertEqual(rig.store.selectedClipID,a)
        XCTAssertFalse(rig.store.dragSelectArmed,"one press, then off")
        // With Shift the clicked clip is added.
        rig.store.dragSelectArmed = true
        rig.down(3,rig.y(.v2),.shift); rig.up(3,rig.y(.v2),.shift)
        XCTAssertEqual(rig.store.selectionForEditing,[a,b]); XCTAssertFalse(rig.store.dragSelectArmed)
        // On empty track space: nothing is selected, it is off, and the playhead stays.
        rig.store.dragSelectArmed = true
        rig.down(5,rig.y(.v1)); rig.up(5,rig.y(.v1))
        XCTAssertTrue(rig.store.selectionForEditing.isEmpty); XCTAssertFalse(rig.store.dragSelectArmed)
        XCTAssertEqual(rig.store.playhead,.zero)
    }

    func testAnUndoInTheMiddleOfADragDropsTheDragQuietly() {
        let rig = TimelineRig { $0.clips = [self.title("A",.v1,0,3),self.title("Far",.v1,30,1)] }
        defer { rig.close() }
        rig.store.snapping = false
        let a = rig.clip("A").id
        // ⌘Z (the Edit menu's Undo) while a just-added title is still being dragged: it is gone on release.
        rig.store.addText()
        let t = rig.store.selectedClipID!, lane = rig.clip(t).lane
        rig.down(1.5,rig.y(lane)); rig.drag(3,rig.y(lane))
        rig.store.undo()
        rig.drag(4,rig.y(lane)); rig.up(4,rig.y(lane))
        XCTAssertNil(rig.store.message,"no alert"); XCTAssertFalse(rig.store.project.clips.contains { $0.id == t })
        XCTAssertTrue(rig.store.canRedo,"nothing was recorded over the undone step")
        // A clip the undo left in place is not moved or trimmed by the stale drag.
        rig.store.redo()
        let before = rig.clip(a)
        for handle: Double in [1.5,3-3/60] {
            rig.down(handle,rig.y(.v1)); rig.drag(handle+2,rig.y(.v1))
            rig.store.undo()
            rig.up(handle+2,rig.y(.v1))
            XCTAssertEqual(rig.clip(a),before); XCTAssertNil(rig.store.message)
            rig.store.redo()
        }
        // A rectangle being drawn stops selecting.
        rig.store.selectClips([])
        rig.down(10,rig.y(.v2,-15),.shift); rig.drag(12,rig.y(.v1),.shift)
        rig.store.undo()
        rig.drag(0.5,rig.y(.v1),.shift); rig.up(0.5,rig.y(.v1),.shift)
        XCTAssertTrue(rig.store.selectionForEditing.isEmpty)
        // So is a transition's edge whose fade is undone meanwhile.
        rig.store.applyTransition(.crossDissolve,from:a,to:nil)                  // a 1 s fade out, 2–3 s
        rig.down(2+3/60,rig.y(.v1,45)); rig.drag(1.5,rig.y(.v1,45))
        rig.store.undo()
        rig.drag(1,rig.y(.v1,45)); rig.up(1,rig.y(.v1,45))
        XCTAssertTrue(rig.store.project.transitions.isEmpty); XCTAssertNil(rig.store.message)
    }

    func testAGroupDragMovesEachClipWithItsLinkedSound() {
        var video = UUID()
        let rig = TimelineRig { project in
            let media = timelineTestVideo(); project.media = [media]
            video = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
            try Editing.trim(video,leading:false,to:.init(seconds:2),in:&project)
            project.clips.append(self.title("T",.v2,3,2))
        }
        defer { rig.close() }
        rig.store.snapping = false
        let audio = rig.store.project.group(for:video).first { $0.id != video }!.id
        rig.store.selectClips([video,rig.clip("T").id])
        rig.down(4,rig.y(.v2)); rig.drag(5,rig.y(.v2)); rig.up(5,rig.y(.v2))
        XCTAssertEqual([rig.clip(video).start,rig.clip(audio).start,rig.clip("T").start],[.init(seconds:1),.init(seconds:1),.init(seconds:4)])
        XCTAssertEqual(rig.store.undoName,"Move clips")
        // The sound of a selected video is drawn selected too: its outline in the accent.
        let image = rig.paint()
        XCTAssertTrue(TimelineRig.isAccent(image,60,rig.y(.a1,30)),"the linked sound's outline")
        XCTAssertFalse(TimelineRig.isAccent(image,60,rig.y(.a2,30)),"the empty row below it")
    }
}

/// Media imported while a clip is dragged (files dropped in the library a moment before) change
/// no clip: a move, trim or rectangle going on lands as if nothing happened.
final class TimelineImportDuringADragTests: ProjectTestCase {
    private func title(_ name: String, _ start: Double, _ length: Double) -> Clip {
        Clip(name:name,kind:.text,lane:.v1,start:.init(seconds:start),duration:.init(seconds:length))
    }
    func testAnImportLandingMidDragLeavesTheDragGoing() async throws {
        let rig = TimelineRig { $0.clips = [self.title("A",0,3),self.title("B",5,2),self.title("Far",30,1)] }
        defer { rig.close() }
        rig.store.snapping = false
        let a = rig.clip("A").id, b = rig.clip("B").id
        func importStill(_ name: String) async throws {
            rig.store.importFiles([try makeStill(name,width:64,height:36)])
            let done = await eventually { !rig.store.isImporting }
            XCTAssertTrue(done)
        }
        rig.down(1.5,rig.y(.v1)); rig.drag(2,rig.y(.v1))
        try await importStill("One.png")
        rig.drag(2.5,rig.y(.v1)); rig.up(2.5,rig.y(.v1))
        XCTAssertEqual(rig.clip(a).start,.init(seconds:1)); XCTAssertEqual(rig.store.undoName,"Move clip")
        rig.down(7-3/60,rig.y(.v1)); rig.drag(8-3/60,rig.y(.v1))
        try await importStill("Two.png")
        rig.drag(9-3/60,rig.y(.v1)); rig.up(9-3/60,rig.y(.v1))
        XCTAssertEqual(rig.clip(b).end,.init(seconds:9)); XCTAssertEqual(rig.store.undoName,"Trim clip")
        rig.store.selectClips([])
        rig.down(12,rig.y(.v2,-15),.shift); rig.drag(10,rig.y(.v1),.shift)
        try await importStill("Three.png")
        rig.drag(0.5,rig.y(.v1),.shift); rig.up(0.5,rig.y(.v1),.shift)
        XCTAssertEqual(rig.store.selectionForEditing,[a,b])
        XCTAssertEqual(rig.store.project.media.count,3); XCTAssertNil(rig.store.message)
    }
}
