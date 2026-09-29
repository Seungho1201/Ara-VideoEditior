import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

/// Records the keys a view passes on up the responder chain.
@MainActor private final class KeyRecorder: NSResponder {
    var keys: [UInt16] = []
    override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
}

/// The keys the timeline handles itself: Return and Esc (a transform, the alignment point), the
/// fixed keys against the shortcuts set in Settings, and no keys at all behind help mode.
@MainActor final class TimelineKeyTests: XCTestCase {
    /// Title T on V1 2–6 s; a far title keeps the timeline 31 s long.
    private func rig() -> TimelineRig {
        TimelineRig { $0.clips = [Clip(name:"T",kind:.text,lane:.v1,start:.init(seconds:2),duration:.init(seconds:4)),
                                  Clip(name:"Far",kind:.text,lane:.v2,start:.init(seconds:30),duration:.init(seconds:1))] }
    }
    private let arrow: NSEvent.ModifierFlags = [.numericPad,.function]
    private let tenFrames = MediaTime(ticks:FrameRate(30).frame.ticks*10)

    func testReturnFinishesATransformOnlyWithoutAModifierAndGoesOnOtherwise() {
        let rig = rig(); defer { rig.close() }
        let t = rig.clip("T").id
        let passed = KeyRecorder(); passed.nextResponder = rig.canvas.nextResponder; rig.canvas.nextResponder = passed
        rig.store.selectedClipID = t
        for flags: NSEvent.ModifierFlags in [.shift,.command,.option,.control] {
            for (code,characters) in [(UInt16(36),"\r"),(UInt16(76),"\u{3}")] {
                rig.store.previewTransformID = t
                rig.press(code,characters,flags)
                XCTAssertEqual(rig.store.previewTransformID,t,"key \(code) with \(flags.rawValue) is not the finishing key, as in the preview")
            }
        }
        rig.press(36,"\r"); XCTAssertNil(rig.store.previewTransformID,"Return finishes")
        rig.store.previewTransformID = t
        rig.press(76,"\u{3}"); XCTAssertNil(rig.store.previewTransformID,"so does Enter")
        passed.keys = []
        rig.press(36,"\r"); rig.press(76,"\u{3}")
        XCTAssertEqual(passed.keys,[36,76],"with nothing to finish both go on up the responder chain")
    }

    func testReturnOrEscWhilePlacingTheAlignmentPointEndsOnlyThePlacing() {
        for (code,characters) in [(UInt16(36),"\r"),(UInt16(76),"\u{3}"),(UInt16(53),"\u{1b}")] {
            let rig = rig(); defer { rig.close() }
            let t = rig.clip("T")
            rig.store.editAnchor(t)                   // the inspector's Adjust button: the timeline keeps the keys
            XCTAssertEqual(rig.store.anchorEditID,t.id)
            rig.press(code,characters)
            XCTAssertNil(rig.store.anchorEditID,"key \(code) ends placing the point")
            XCTAssertEqual(rig.store.previewTransformID,t.id,"key \(code) keeps the transform, as in the preview")
            XCTAssertEqual(rig.store.selectedClipID,t.id)
        }
        // Scrubbing the ruler inside the clip keeps the placing on and gives the timeline the keys.
        let rig = rig(); defer { rig.close() }
        let t = rig.clip("T")
        rig.store.editAnchor(t)
        rig.down(3,TimelineRig.rulerY); rig.up(3,TimelineRig.rulerY)
        XCTAssertEqual(rig.store.anchorEditID,t.id); XCTAssertTrue(rig.window.firstResponder === rig.canvas)
        rig.press(36,"\r")
        XCTAssertNil(rig.store.anchorEditID); XCTAssertEqual(rig.store.previewTransformID,t.id)
        rig.press(36,"\r")
        XCTAssertNil(rig.store.previewTransformID,"the next Return finishes the transform")
    }

    /// Placing the alignment point, Esc in the timeline ends the placing and still does its own
    /// work there: a move or trim in progress is let go, and rectangle select is switched off.
    func testEscWhilePlacingTheAlignmentPointAlsoLetsGoOfADrag() {
        let rig = rig(); defer { rig.close() }
        rig.store.snapping = false
        let t = rig.clip("T")
        for (from,path) in [(4.0,[5.0,6]),(6-3/60,[7.0,8])] {                   // a move, then a trim of its end
            rig.store.editAnchor(rig.clip(t.id))
            rig.down(from,rig.y(.v1)); rig.drag(path[0],rig.y(.v1))
            XCTAssertEqual(rig.store.anchorEditID,t.id,"a press on its own clip keeps the placing")
            rig.press(53,"\u{1b}")
            rig.drag(path[1],rig.y(.v1)); rig.up(path[1],rig.y(.v1))
            XCTAssertEqual(rig.clip(t.id),t,"Esc let go of the drag")
            XCTAssertNil(rig.store.anchorEditID); XCTAssertEqual(rig.store.previewTransformID,t.id)
        }
        rig.store.editAnchor(rig.clip(t.id)); rig.store.dragSelectArmed = true
        rig.press(53,"\u{1b}")
        XCTAssertNil(rig.store.anchorEditID); XCTAssertFalse(rig.store.dragSelectArmed)
        XCTAssertEqual(rig.store.previewTransformID,t.id,"the transform stays")
    }

    func testTheFixedKeysComeBeforeTheShortcutsSetInSettings() {
        let rig = rig(); defer { rig.close() }
        let t = rig.clip("T").id
        // ⇧→ and ⇧← given to Next Frame and Go to Clip Start: in the timeline they still step ten frames.
        rig.store.shortcuts.set(Shortcut("right",.shift),for:.nextFrame)
        rig.store.shortcuts.set(Shortcut("left",.shift),for:.clipStart)
        rig.store.selectedClipID = t; rig.store.seek(.init(seconds:10))
        rig.press(124,"\u{F703}",arrow.union(.shift))
        XCTAssertEqual(rig.store.playhead,MediaTime(seconds:10)+tenFrames)
        rig.press(123,"\u{F702}",arrow.union(.shift)); rig.press(123,"\u{F702}",arrow.union(.shift))
        XCTAssertEqual(rig.store.playhead,MediaTime(seconds:10)-tenFrames)
        // Return given to Split: with a transform open it finishes the transform and splits nothing.
        rig.store.shortcuts.set(Shortcut("return"),for:.split)
        rig.store.previewTransformID = t; rig.store.seek(.init(seconds:3))
        rig.press(36,"\r")
        XCTAssertNil(rig.store.previewTransformID); XCTAssertEqual(rig.store.project.clips.count,2)
        // ⇧Esc given to Delete: it is still Esc, which deletes nothing.
        rig.store.shortcuts.set(Shortcut("escape",.shift),for:.delete)
        rig.press(53,"\u{1b}",.shift)
        XCTAssertEqual(rig.store.project.clips.count,2); XCTAssertEqual(rig.store.selectedClipID,t)
        // The frame keys themselves follow Settings as before.
        rig.store.shortcuts.set(Shortcut("l"),for:.nextFrame)
        let before = rig.store.playhead
        rig.press(37,"l"); XCTAssertEqual(rig.store.playhead,before+FrameRate(30).frame)
    }

    func testHelpModeKeepsKeysFromTheTimelineAndEscClosesIt() {
        let rig = rig(); defer { rig.close() }
        let t = rig.clip("T").id
        rig.store.selectedClipID = t
        XCTAssertTrue(rig.store.copySelection())                       // something to paste
        rig.store.showHelp = true
        let before = rig.store.project, snapping = rig.store.snapping
        rig.press(45,"n"); rig.press(51,"\u{7f}"); rig.press(117,"\u{F728}",.function)
        rig.press(11,"b",.command); rig.press(17,"t",[.command,.shift]); rig.press(124,"\u{F703}",arrow.union(.shift))
        XCTAssertEqual(rig.store.snapping,snapping,"N"); XCTAssertEqual(rig.store.project,before,"no edit behind the tips")
        XCTAssertEqual(rig.store.playhead,.zero)
        XCTAssertFalse(rig.commandKey(9,"v"),"⌘V is not taken"); XCTAssertEqual(rig.store.project,before)
        XCTAssertFalse(rig.canvas.validateUserInterfaceItem(NSMenuItem(title:"Paste",action:#selector(TimelineCanvas.paste(_:)),keyEquivalent:"v")),
                       "nor is the Edit menu's Paste")
        rig.press(53,"\u{1b}")
        XCTAssertFalse(rig.store.showHelp,"Esc closes help mode")
        XCTAssertEqual(rig.store.selectedClipID,t,"and does nothing else")
        rig.press(45,"n"); XCTAssertNotEqual(rig.store.snapping,snapping,"keys work again")
    }
}
