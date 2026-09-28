import XCTest
@testable import FrameCore

final class TransitionTests: XCTestCase {
    /// Two 4 s clips meeting at 4 s on V1 (each with linked audio), 30 fps.
    private func cutProject(rate: FrameRate = .init(30)) throws -> (Project,UUID,UUID) {
        var p = Project(); p.frameRate = rate
        let media = MediaReference(name:"Source",path:"/fixture.mov",kind:.video,duration:.init(seconds:20),hasAudio:true)
        p.media = [media]
        let a = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&p)
        try Editing.trim(a,leading:false,to:.init(seconds:4),in:&p)
        let b = try Editing.add(mediaID:media.id,lane:.v1,at:.init(seconds:4),to:&p)
        try Editing.trim(b,leading:false,to:.init(seconds:8),in:&p)
        return (p,a,b)
    }

    func testTransitionEdgesAreSnapTargets() throws {
        var (p,a,b) = try cutProject()
        // A title on V2 over the second clip, with a 1 s fade out ending at 8 s (starts at 7 s).
        let title = try Editing.addText(at:.init(seconds:4.5),to:&p)
        let fade = try Editing.setTransition(.dipToBlack,duration:.init(seconds:1),from:title,to:nil,in:&p)
        let own = try Editing.setTransition(.dipToBlack,duration:.init(seconds:0.6),from:b,to:nil,in:&p)
        let titleWindow = try XCTUnwrap(p.window(of:p.transitions.first { $0.id == fade }!))
        let threshold = MediaTime(seconds:0.1)
        // Resizing V1's fade out near the title's fade start catches it.
        let near = titleWindow.start + MediaTime(seconds:0.05)
        XCTAssertEqual(Editing.snapTarget(near,excludingTransition:own,playhead:.init(seconds:30),threshold:threshold,project:p),titleWindow.start)
        // Its own edges are never a target for itself.
        let ownWindow = try XCTUnwrap(p.window(of:p.transitions.first { $0.id == own }!))
        let beside = ownWindow.start + MediaTime(seconds:0.05)
        XCTAssertNotEqual(Editing.snapTarget(beside,excludingTransition:own,playhead:.init(seconds:30),threshold:.init(seconds:0.06),project:p),ownWindow.start)
        // Moving the title: its own fade goes with it and is no target.
        XCTAssertNil(Editing.snapTarget(titleWindow.start+MediaTime(seconds:0.02),excluding:title,playhead:.init(seconds:30),threshold:.init(seconds:0.03),project:p))
        _ = a
    }

    func testACutTransitionIsCentredOnTheCut() throws {
        var (p,a,b) = try cutProject()
        let id = try Editing.setTransition(.crossDissolve,duration:.init(seconds:1),from:a,to:b,in:&p)
        let t = try XCTUnwrap(p.transitions.first { $0.id == id })
        let w = try XCTUnwrap(p.window(of:t))
        XCTAssertEqual(w.start,.init(seconds:3.5)); XCTAssertEqual(w.end,.init(seconds:4.5))
        // An odd number of frames puts the extra frame after the cut, still on the frame grid.
        try Editing.updateTransition(id,duration:MediaTime(ticks:p.frameRate.frame.ticks*25),in:&p)
        let odd = try XCTUnwrap(p.window(of:p.transitions[0]))
        XCTAssertEqual(odd.before,MediaTime(ticks:p.frameRate.frame.ticks*12))
        XCTAssertEqual(odd.after,MediaTime(ticks:p.frameRate.frame.ticks*13))
        XCTAssertEqual(p.frameRate.quantize(odd.start),odd.start)
    }

    func testEitherCutHandleResizesAroundTheSameCutWithoutChangingClips() throws {
        var (base,a,b) = try cutProject()
        let id = try Editing.setTransition(.push,direction:.right,duration:.init(seconds:1),from:a,to:b,in:&base)
        for leading in [true,false] {
            var p = base
            try Editing.resizeTransition(id,leading:leading,to:.init(seconds:leading ? 2.8 : 5.2),in:&p)
            let t = try XCTUnwrap(p.transitions.first), w = try XCTUnwrap(p.window(of:t))
            XCTAssertEqual(t.duration,.init(seconds:2.4))
            XCTAssertEqual(w.start,.init(seconds:2.8)); XCTAssertEqual(w.end,.init(seconds:5.2))
            XCTAssertEqual(t.id,id); XCTAssertEqual(t.kind,.push); XCTAssertEqual(t.direction,.right)
            XCTAssertEqual(p.clips,base.clips); XCTAssertEqual(p.duration,base.duration)
        }
    }

    func testOddFrameHandleResizesDoNotJumpAtAnyProjectFrameRate() throws {
        for rate in FrameRate.supported {
            var (base,a,b) = try cutProject(rate:rate)
            let id = try Editing.setTransition(.crossDissolve,duration:MediaTime(ticks:rate.frame.ticks*25),from:a,to:b,in:&base)
            let window = try XCTUnwrap(base.window(of:base.transitions[0]))
            for leading in [true,false] {
                let edge = leading ? window.start : window.end
                var still = base
                try Editing.resizeTransition(id,leading:leading,to:edge,in:&still)
                XCTAssertEqual(still,base,rate.label)
                var expanded = base
                try Editing.resizeTransition(id,leading:leading,to:edge+MediaTime(ticks:rate.frame.ticks*(leading ? -1 : 1)),in:&expanded)
                XCTAssertEqual(expanded.transitions[0].duration.ticks,rate.frame.ticks*27)
                let w = try XCTUnwrap(expanded.window(of:expanded.transitions[0]))
                XCTAssertEqual(w.before.ticks,rate.frame.ticks*13)
                XCTAssertEqual(w.after.ticks,rate.frame.ticks*14)
                XCTAssertEqual(expanded.clips,base.clips)
            }
        }
    }

    func testFadeHandlesKeepTheirClipAnchorsFixed() throws {
        var (p,a,b) = try cutProject()
        let first = try Editing.setTransition(.dipToBlack,from:nil,to:a,in:&p)
        let last = try Editing.setTransition(.dipToBlack,from:b,to:nil,in:&p)
        let clips = p.clips
        try Editing.resizeTransition(first,leading:false,to:.init(seconds:2),in:&p)
        try Editing.resizeTransition(last,leading:true,to:.init(seconds:6.5),in:&p)
        let fadeIn = try XCTUnwrap(p.transition(into:a)), fadeOut = try XCTUnwrap(p.transition(outOf:b))
        XCTAssertEqual(p.window(of:fadeIn)?.start,.zero)
        XCTAssertEqual(fadeIn.duration,.init(seconds:2))
        XCTAssertEqual(p.window(of:fadeOut)?.end,.init(seconds:8))
        XCTAssertEqual(fadeOut.duration,.init(seconds:1.5))
        XCTAssertEqual(p.clips,clips)
        let before = p
        XCTAssertThrowsError(try Editing.resizeTransition(first,leading:true,to:.init(seconds:1),in:&p))
        XCTAssertThrowsError(try Editing.resizeTransition(last,leading:false,to:.init(seconds:9),in:&p))
        XCTAssertThrowsError(try Editing.resizeTransition(UUID(),leading:true,to:.zero,in:&p))
        XCTAssertEqual(p,before)
    }

    func testHandleResizeClampsAtOneFrameMaximumAndNeighbouringTransitions() throws {
        var (base,a,b) = try cutProject()
        let id = try Editing.setTransition(.crossDissolve,from:a,to:b,in:&base)
        for leading in [true,false] {
            var p = base
            try Editing.resizeTransition(id,leading:leading,to:.init(seconds:leading ? -10 : 20),in:&p)
            XCTAssertEqual(p.transitions[0].duration,Transition.longest)
            p = base
            try Editing.resizeTransition(id,leading:leading,to:.init(seconds:leading ? 10 : -10),in:&p)
            XCTAssertEqual(p.transitions[0].duration,p.frameRate.frame)
            XCTAssertEqual(p.clips,base.clips)
        }
        let fade = try Editing.setTransition(.dipToWhite,duration:.init(seconds:2.5),from:nil,to:a,in:&base)
        var p = base
        try Editing.resizeTransition(id,leading:false,to:.init(seconds:20),in:&p)
        XCTAssertEqual(p.transition(outOf:a)?.duration,.init(seconds:3))
        XCTAssertEqual(p.transitions.first { $0.id == fade },base.transitions.first { $0.id == fade })
        XCTAssertEqual(p.clips,base.clips)
    }

    func testResizeSamplesUseTheirOriginalProjectAndCommitAsOneHistoryStep() throws {
        var (base,a,b) = try cutProject()
        let id = try Editing.setTransition(.crossDissolve,from:a,to:b,in:&base)
        // A long drag crosses both limits and returns to its start; it must not ratchet.
        var candidate = base
        for second in [10.0,-2,3.6,3.5] {
            candidate = base
            try Editing.resizeTransition(id,leading:true,to:.init(seconds:second),in:&candidate)
        }
        XCTAssertEqual(candidate,base)
        try Editing.resizeTransition(id,leading:true,to:.init(seconds:3),in:&candidate)
        var history = EditHistory(); history.record(base,name:"Transition length")
        let undone = try XCTUnwrap(history.undo(candidate))
        XCTAssertEqual(undone,base); XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.redo(undone),candidate)
        XCTAssertEqual(try ProjectFile.decode(ProjectFile.encode(candidate)),candidate)
    }

    func testOneSidedTransitionsFadeInsideTheClip() throws {
        var (p,a,b) = try cutProject()
        try Editing.setTransition(.dipToBlack,duration:.init(seconds:1),from:nil,to:a,in:&p)   // fade in at 0
        try Editing.setTransition(.dipToBlack,duration:.init(seconds:1),from:b,to:nil,in:&p)   // fade out at 8
        XCTAssertEqual(p.window(of:p.transition(into:a)!)?.start,.zero)
        XCTAssertEqual(p.window(of:p.transition(outOf:b)!)?.end,.init(seconds:8))
        XCTAssertEqual(Editing.edge(on:.v1,at:.init(seconds:4),in:p)?.from,a)
        XCTAssertEqual(Editing.edge(on:.v1,at:.init(seconds:4),in:p)?.to,b)
        XCTAssertNil(Editing.edge(on:.v1,at:.init(seconds:2),in:p))
        XCTAssertNil(Editing.edge(on:.a1,at:.init(seconds:4),in:p))                             // no transitions on audio
    }

    func testDropFindsTheCutAndFreeEdgesAtDifferentZooms() throws {
        let (p,a,b) = try cutProject()
        for zoom in [8.0,64,220] {
            let reach = MediaTime(seconds:24/zoom)
            for delta in [-10.0,10] {
                let cut = try XCTUnwrap(Editing.nearestTransitionEdge(on:.v1,to:.init(seconds:4+delta/zoom),within:reach,in:p))
                XCTAssertEqual(cut.time,.init(seconds:4))
                XCTAssertEqual(cut.from,a); XCTAssertEqual(cut.to,b)
            }
            let start = try XCTUnwrap(Editing.nearestTransitionEdge(on:.v1,to:.init(seconds:10/zoom),within:reach,in:p))
            XCTAssertEqual(start.time,.zero); XCTAssertNil(start.from); XCTAssertEqual(start.to,a)
            let end = try XCTUnwrap(Editing.nearestTransitionEdge(on:.v1,to:.init(seconds:8+23/zoom),within:reach,in:p))
            XCTAssertEqual(end.time,.init(seconds:8)); XCTAssertEqual(end.from,b); XCTAssertNil(end.to)
            XCTAssertNil(Editing.nearestTransitionEdge(on:.v1,to:.init(seconds:8+25/zoom),within:reach,in:p))
        }
    }

    func testDropNeverTargetsAudioEmptyTracksOrBridgesAGap() throws {
        var (p,a,b) = try cutProject()
        for lane in [Lane.a1,.a2,.v2] {
            XCTAssertNil(Editing.nearestTransitionEdge(on:lane,to:.init(seconds:4),within:.init(seconds:1),in:p))
        }
        XCTAssertNil(Editing.nearestTransitionEdge(on:.v1,to:.init(seconds:2),within:.init(seconds:0.3),in:p))
        try Editing.move(b,to:.init(seconds:10),lane:.v1,in:&p)
        let edge = try XCTUnwrap(Editing.nearestTransitionEdge(on:.v1,to:.init(seconds:4.1),within:.init(seconds:0.3),in:p))
        XCTAssertEqual(edge.from,a); XCTAssertNil(edge.to)
        XCTAssertNil(Editing.nearestTransitionEdge(on:.v1,to:.init(seconds:7),within:.init(seconds:0.3),in:p))
        // A card over the centre of a clip chooses its earlier edge consistently.
        p.clips.reverse()
        let tied = try XCTUnwrap(Editing.nearestTransitionEdge(on:.v1,to:.init(seconds:2),within:.init(seconds:4),in:p))
        XCTAssertEqual(tied.time,.zero); XCTAssertEqual(tied.to,a)
    }

    func testEveryDroppedKindPreservesClipTimingAndSupportsUndoAndSave() throws {
        let (base,_,_) = try cutProject()
        let edge = try XCTUnwrap(Editing.nearestTransitionEdge(on:.v1,to:.init(seconds:3.9),within:.init(seconds:0.4),in:base))
        for kind in TransitionKind.allCases {
            var p = base, history = EditHistory()
            history.record(p,name:"Add transition")
            try Editing.setTransition(kind,from:edge.from,to:edge.to,in:&p)
            XCTAssertEqual(p.clips,base.clips,kind.rawValue)
            XCTAssertEqual(p.duration,base.duration)
            XCTAssertEqual(p.transitions.first?.kind,kind)
            let undone = try XCTUnwrap(history.undo(p))
            XCTAssertEqual(undone,base)
            XCTAssertEqual(history.redo(undone),p)
            XCTAssertEqual(try ProjectFile.decode(ProjectFile.encode(p)),p)
        }
    }

    func testLengthsFitTheClipsAndNeverOverlap() throws {
        var (p,a,b) = try cutProject()
        let long = try Editing.setTransition(.push,duration:.init(seconds:5),from:a,to:b,in:&p)
        XCTAssertEqual(p.transitions.first { $0.id == long }?.duration,.init(seconds:5))        // 2.5 s each side fits in 4 s clips
        // A's fade in may only use what the cut transition leaves: 4 - 2.5 = 1.5 s.
        try Editing.setTransition(.crossDissolve,duration:.init(seconds:3),from:nil,to:a,in:&p)
        XCTAssertEqual(p.transition(into:a)?.duration,.init(seconds:1.5))
        // Replacing the transition on an edge keeps one, with the new kind.
        let replaced = try Editing.setTransition(.wipe,from:a,to:b,in:&p)
        XCTAssertEqual(replaced,long)
        XCTAssertEqual(p.transitions.filter { $0.from == a }.map(\.kind),[.wipe])
    }

    func testTransitionsFollowTheirClipsThroughEdits() throws {
        var (p,a,b) = try cutProject()
        try Editing.setTransition(.crossDissolve,from:a,to:b,in:&p)
        try Editing.setTransition(.dipToBlack,from:b,to:nil,in:&p)
        // Split B: its fade out moves to the right-hand piece; the cut into B stays.
        try Editing.split(b,at:.init(seconds:6),in:&p)
        let right = try XCTUnwrap(p.clips.first { $0.lane == .v1 && $0.start == .init(seconds:6) })
        XCTAssertEqual(p.transition(outOf:right.id)?.kind,.dipToBlack)
        XCTAssertEqual(p.transition(into:b)?.from,a)
        // Trim A shorter than its half of the cut: the cut no longer meets, so it goes.
        var trimmed = p
        try Editing.trim(a,leading:false,to:.init(seconds:3),in:&trimmed)
        XCTAssertNil(trimmed.transition(into:b))
        // Moving B away drops the cut transition too; deleting a clip drops its transitions.
        var moved = p
        try Editing.move(b,to:.init(seconds:10),lane:.v1,in:&moved)
        XCTAssertNil(moved.transition(outOf:a))
        var deleted = p
        Editing.delete(right.id,from:&deleted)
        deleted = try deleted.validated()
        XCTAssertNil(deleted.transitions.first { $0.from == right.id })
        // Shortening a clip shortens what no longer fits, and both of its transitions still fit.
        var short = p
        try Editing.setTransition(.crossDissolve,duration:.init(seconds:2),from:nil,to:a,in:&short)
        try Editing.trim(a,leading:true,to:.init(seconds:2.5),in:&short)                      // A is now 1.5 s long
        let fadeIn = try XCTUnwrap(short.transition(into:a)), cut = try XCTUnwrap(short.transition(outOf:a))
        XCTAssertLessThan(fadeIn.duration,.init(seconds:2))
        XCTAssertLessThanOrEqual((short.window(of:fadeIn)!.after+short.window(of:cut)!.before).ticks,MediaTime(seconds:1.5).ticks)
    }

    func testDeletingTheLastFadedClipWorks() throws {
        var (p,a,b) = try cutProject()
        try Editing.setTransition(.crossDissolve,from:nil,to:a,in:&p)
        try Editing.setTransition(.crossDissolve,from:b,to:nil,in:&p)
        try Editing.setTransition(.crossDissolve,from:a,to:b,in:&p)
        Editing.delete(a,from:&p); p = try p.validated()
        Editing.delete(b,from:&p); p = try p.validated()
        XCTAssertTrue(p.transitions.isEmpty)
    }
    func testASpeedDragAwayAndBackKeepsTransitions() throws {
        var (p,a,b) = try cutProject()
        try Editing.setTransition(.crossDissolve,from:a,to:b,in:&p)
        try Editing.setTransition(.dipToBlack,from:nil,to:a,in:&p)
        let base = p
        for speed in [1.5,2,1.5,1] { try Editing.setSpeed(a,to:speed,in:&p,basedOn:base) }
        XCTAssertEqual(p.transitions.map(\.kind).sorted { $0.rawValue < $1.rawValue },[.crossDissolve,.dipToBlack])
    }
    func testCompetingTransitionsShrinkTogetherInsteadOfOneVanishing() throws {
        var (p,a,b) = try cutProject()
        try Editing.setTransition(.dipToBlack,duration:.init(seconds:1),from:nil,to:a,in:&p)   // added first
        try Editing.setTransition(.crossDissolve,duration:.init(seconds:1),from:a,to:b,in:&p)
        try Editing.trim(a,leading:true,to:.init(seconds:3.5),in:&p)                           // A is now 0.5 s; its end still meets B
        // Both survive, shrunk in proportion, whichever was added first; together they fit A.
        let fadeIn = try XCTUnwrap(p.transition(into:a)), cut = try XCTUnwrap(p.transition(outOf:a))
        XCTAssertLessThanOrEqual((p.window(of:fadeIn)!.after+p.window(of:cut)!.before).ticks,MediaTime(seconds:0.5).ticks)
        XCTAssertGreaterThan(cut.duration,.zero)
    }
    func testDuplicateTransitionIDsGetSeparated() throws {
        var (p,a,b) = try cutProject()
        try Editing.setTransition(.crossDissolve,from:nil,to:a,in:&p)
        try Editing.setTransition(.crossDissolve,from:b,to:nil,in:&p)
        p.transitions[1].id = p.transitions[0].id
        let fixed = try p.validated()
        XCTAssertEqual(Set(fixed.transitions.map(\.id)).count,2)
    }
    func testNewTransitionsTakeTheirKindsLengthAndKeepTheirDirection() throws {
        var (p,a,b) = try cutProject()
        let id = try Editing.setTransition(.push,direction:.up,from:a,to:b,in:&p)
        XCTAssertEqual(p.transitions.first { $0.id == id }?.duration,TransitionKind.push.defaultDuration)
        try Editing.updateTransition(id,direction:.right,in:&p)
        XCTAssertEqual(p.transitions.first { $0.id == id }?.direction,.right)
        // A document from before directions opens with the default one.
        var json = try JSONSerialization.jsonObject(with:ProjectFile.encode(p)) as! [String:Any]
        var stored = json["transitions"] as! [[String:Any]]
        stored[0].removeValue(forKey:"direction"); json["transitions"] = stored
        XCTAssertEqual(try ProjectFile.decode(JSONSerialization.data(withJSONObject:json)).transitions.first?.direction,.left)
        // One from a newer version with a kind this one lacks still opens.
        stored[0]["kind"] = "morphCut"; stored[0]["direction"] = "diagonal"; json["transitions"] = stored
        let newer = try ProjectFile.decode(JSONSerialization.data(withJSONObject:json)).transitions.first
        XCTAssertEqual(newer?.kind,.crossDissolve); XCTAssertEqual(newer?.direction,.left)
        // Every kind has a name, a category and a length that fits the usual limits.
        for kind in TransitionKind.allCases {
            XCTAssertFalse(kind.name.isEmpty)
            XCTAssertTrue(kind.defaultDuration > .zero && kind.defaultDuration <= Transition.longest)
        }
        XCTAssertEqual(TransitionKind.allCases.filter { !$0.needsBothPictures },[.dipToBlack,.dipToWhite])
    }
    func testDocumentsKeepTransitionsAndOlderOnesHaveNone() throws {
        var (p,a,b) = try cutProject()
        try Editing.setTransition(.iris,duration:.init(seconds:0.5),from:a,to:b,in:&p)
        let reopened = try ProjectFile.decode(ProjectFile.encode(p))
        XCTAssertEqual(reopened.transitions,p.transitions)
        var json = try JSONSerialization.jsonObject(with:ProjectFile.encode(p)) as! [String:Any]
        json.removeValue(forKey:"transitions")
        XCTAssertEqual(try ProjectFile.decode(JSONSerialization.data(withJSONObject:json)).transitions,[])
        // Only visual clips take transitions.
        let audio = try XCTUnwrap(p.clips.first { $0.kind == .audio })
        XCTAssertThrowsError(try Editing.setTransition(.crossDissolve,from:nil,to:audio.id,in:&p))
    }
}
