import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

/// A video with its sound, 5 s on V1/A1 from the start of a 20 s source (a fake path: nothing
/// here decodes it), and whatever `after` puts behind it.
@MainActor private func speedStore(_ after: (inout Project) throws -> Void = { _ in }) -> (EditorStore, UUID) {
    _ = NSApplication.shared
    let store = EditorStore()
    let video = MediaReference(name:"Source.mov",path:"/nonexistent/ara-tests/Source.mov",kind:.video,duration:.init(seconds:20),
                               width:640,height:360,frameRate:30,hasAudio:true)
    var id = UUID()
    let made = store.edit("Fixture") { project in
        project.frameRate = .init(30); project.media = [video]
        id = try Editing.add(mediaID:video.id,lane:.v1,at:.zero,to:&project)
        try Editing.trim(id,leading:false,to:.init(seconds:5),in:&project)
        try after(&project)
    }
    XCTAssertTrue(made,store.message ?? "")
    store.isBuilding = false; store.selectedClipID = id
    return (store,id)
}

/// A title on V1 from `seconds`.
private func title(at seconds: Double) -> Clip { Clip(name:"Next",kind:.text,lane:.v1,start:.init(seconds:seconds),duration:.init(seconds:3)) }

/// Slowing a clip lengthens it. With a clip right behind it there is no room: the speed is refused
/// saying so (not with the overlap advice), and the slider stops against the next clip.
@MainActor final class ClipSpeedTests: XCTestCase {
    private func noRoom(_ speed: String) -> String { "There isn't room after this clip for \(speed) speed. Move the next clip or use another track." }

    func testASlowerSpeedWithNoRoomIsRefusedSayingWhy() {
        let (store,id) = speedStore { $0.clips.append(title(at:5)) }
        let before = store.project
        XCTAssertFalse(store.setSpeed(0.5))
        XCTAssertEqual(store.project,before)
        XCTAssertEqual(store.message,noRoom("0.5x"))
        // Custom…: refused too, so its popover stays open for another value.
        store.message = nil
        XCTAssertFalse(store.setCustomSpeed("0.5"))
        XCTAssertEqual(store.project,before); XCTAssertEqual(store.message,noRoom("0.5x"))
        // Faster needs no room.
        store.message = nil
        XCTAssertTrue(store.setSpeed(2))
        XCTAssertEqual(store.project.clip(id)?.speed,2); XCTAssertNil(store.message)
    }

    /// Nothing behind the picture on V1, but music behind its sound on A1.
    func testTheLinkedSoundNeedsRoomToo() {
        let music = MediaReference(name:"Music.wav",path:"/nonexistent/ara-tests/Music.wav",kind:.audio,duration:.init(seconds:30),hasAudio:true)
        let (store,id) = speedStore { project in
            project.media.append(music)
            project.clips.append(Clip(mediaID:music.id,name:"Music",kind:.audio,lane:.a1,start:.init(seconds:6),duration:.init(seconds:10)))
        }
        XCTAssertFalse(store.setCustomSpeed("0.1"))
        XCTAssertEqual(store.project.clip(id)?.speed,1)
        XCTAssertEqual(store.message,noRoom("0.1x"))
        // With room up to the music, a little slower fits.
        store.message = nil
        XCTAssertTrue(store.setCustomSpeed("0.9"))
        XCTAssertEqual(store.project.clip(id)?.speed,0.9); XCTAssertNil(store.message)
    }

    func testTheLastClipSlowsDown() {
        let (store,id) = speedStore()
        XCTAssertTrue(store.setSpeed(0.5))
        XCTAssertEqual(store.project.clip(id)?.duration,.init(seconds:10))
        XCTAssertEqual(Set(store.project.group(for:id).map(\.duration)),[.init(seconds:10)],"its sound too")
    }

    /// The inspector's slider, from 1x down to 0.5x with a clip 1 s behind: no alert on any sample,
    /// the reason once in the status, and the clip ends where the next one starts.
    func testTheSliderStopsAgainstTheNextClip() throws {
        let (store,id) = speedStore { $0.clips.append(title(at:6)) }
        store.status = ""
        store.beginInteraction()
        var notes: [String] = []
        for v in stride(from:0.0,through:-1.0,by:-0.05) {
            store.setSpeedInteractively((pow(2,v)*20).rounded()/20)
            XCTAssertNil(store.message,"no modal alert while dragging")
            if !store.status.isEmpty { notes.append(store.status); store.status = "" }
        }
        store.endInteraction()
        XCTAssertEqual(notes.count,1,"said once: \(notes)")
        XCTAssertTrue(notes.first?.hasPrefix("There isn't room after this clip for ") == true,notes.first ?? "")
        let clip = try XCTUnwrap(store.project.clip(id))
        XCTAssertEqual(clip.end,.init(seconds:6),"against the next clip")
        // The fastest speed of that length, so the clip keeps as much of its source as it can.
        XCTAssertEqual(clip.speed,0.833)
        XCTAssertEqual(store.undoName,"Change speed")
        store.undo()
        XCTAssertEqual(store.project.clip(id)?.speed,1,"one drag, one undo step")
        // With no room at all the drag leaves it as it was, and records nothing.
        let (full,fullID) = speedStore { $0.clips.append(title(at:5)) }
        let before = full.project, undoName = full.undoName
        full.beginInteraction()
        for v in stride(from:0.0,through:-1.0,by:-0.1) { full.setSpeedInteractively((pow(2,v)*20).rounded()/20) }
        full.endInteraction()
        XCTAssertEqual(full.project,before); XCTAssertEqual(full.undoName,undoName)
        XCTAssertEqual(full.project.clip(fullID)?.speed,1); XCTAssertNil(full.message)
    }
}

/// A note the status gives about an edit (why the speed slider stopped, what was added) is still
/// there once the preview that edit rebuilt is up: the build's summary does not replace it.
final class StatusNoteTests: ProjectTestCase {
    func testANoteOutlivesTheBuildItsEditStarted() async throws {
        let url = folder.appendingPathComponent("Ten.mov")
        try await writeRedMovie(url)
        noteCached(url)
        let store = makeStore()
        defer { store.pause() }
        store.importFiles([url])
        let imported = await eventually { !store.isImporting }
        XCTAssertTrue(imported)
        XCTAssertTrue(store.addMedia(try XCTUnwrap(store.project.media.first).id))
        let id = try XCTUnwrap(store.selectedClipID)
        store.trim(id,leading:false,to:.init(seconds:5))
        store.edit("Fixture") { $0.clips.append(Clip(name:"Next",kind:.text,lane:.v1,start:.init(seconds:6),duration:.init(seconds:3))) }
        var built = await eventually { !store.isBuilding && store.player.currentItem != nil }
        XCTAssertTrue(built)
        XCTAssertEqual(store.status,"Clips: 2 · SDR Rec.709","an edit without a note of its own: the summary")
        // The speed slider held against the next clip, the preview rebuilt meanwhile.
        store.beginInteraction()
        for v in stride(from:0.0,through:-1.0,by:-0.05) { store.setSpeedInteractively((pow(2,v)*20).rounded()/20) }
        let note = store.status
        XCTAssertTrue(note.hasPrefix("There isn't room after this clip for "),note)
        built = await eventually { !store.isBuilding && store.player.currentItem != nil }
        XCTAssertTrue(built)
        store.setSpeedInteractively(0.5)
        store.endInteraction()
        XCTAssertEqual(store.status,note,"still there, and after the drag")
        XCTAssertEqual(store.project.clip(id)?.end,.init(seconds:6))
        // A transition's note too.
        XCTAssertTrue(store.applyTransition(.crossDissolve,from:id,to:nil))
        let added = store.status
        XCTAssertTrue(added.hasPrefix("Cross Dissolve added"),added)
        built = await eventually { !store.isBuilding && store.player.currentItem != nil }
        XCTAssertTrue(built)
        XCTAssertEqual(store.status,added)
        XCTAssertNil(store.message)
    }
}

/// A 10 s red movie with sound, written off the main actor.
private func writeRedMovie(_ url: URL) async throws { try await TestMovie.write(to:url,frames:300) { _ in (255,0,0) } }

/// Undo names: slider drags are named after what they changed, and every name has a Korean entry.
@MainActor final class UndoNameTests: XCTestCase {
    func testSliderDragsAreNamedAfterWhatTheyChange() {
        let (store,id) = speedStore()
        store.beginInteraction()
        for v in [0.2,0.5,1.0,1.3] { store.setSpeedInteractively((pow(2,v)*20).rounded()/20) }
        store.endInteraction()
        XCTAssertEqual(store.undoName,"Change speed","as the speed menu names it")
        store.undo(); XCTAssertEqual(store.project.clip(id)?.speed,1)
        // The transition's Duration slider.
        let a = Clip(name:"A",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3))
        let other = EditorStore()
        other.edit("Fixture") { project in project.clips = [a]; try Editing.setTransition(.crossDissolve,duration:.init(seconds:1),from:nil,to:a.id,in:&project) }
        other.selectTransition(other.project.transitions[0].id)
        other.beginInteraction()
        for d in [1.1,1.3,1.5] { other.updateSelectedTransition(duration:.init(seconds:d)) }
        other.endInteraction()
        XCTAssertEqual(other.undoName,"Transition length","as a drag on the timeline names it")
        // Volume changes the mix: its drag is still one "Adjust clip".
        store.beginInteraction()
        for volume in [0.8,0.6] { store.updateStyle { $0.volume = volume } }
        store.endInteraction()
        XCTAssertEqual(store.undoName,"Adjust clip")
    }

    /// Every name the app records, looked up in Resources/ko.lproj as the Edit menu does.
    func testEveryUndoNameHasAKoreanName() throws {
        let strings = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ko.lproj/Localizable.strings")
        let korean = try XCTUnwrap(NSDictionary(contentsOf:strings) as? [String:String])
        let pasteboard = NSPasteboard(name:.init("ara-undo-name-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let (store,video) = speedStore { project in
            project.clips += [Clip(name:"A",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:3)),
                              Clip(name:"B",kind:.text,lane:.v2,start:.init(seconds:3),duration:.init(seconds:3))]
        }
        store.pasteboard = pasteboard
        let a = try XCTUnwrap(store.project.clips.first { $0.name == "A" }).id, b = try XCTUnwrap(store.project.clips.first { $0.name == "B" }).id
        var names: [String] = []
        func note() { if !names.contains(store.undoName) { names.append(store.undoName) } }
        store.selectedClipID = video; store.setSpeed(2); note()
        store.seek(.init(seconds:1)); store.split(); note()
        store.move(a,to:.init(seconds:20),lane:.v2); note()
        store.trim(a,leading:false,to:.init(seconds:24)); note()
        store.moveClips([a,b],by:.init(seconds:1)); note()
        store.selectedClipID = a; store.updateStyle { $0.opacity = 0.5 }; note()
        store.applyTransition(.crossDissolve,from:nil,to:a); note()
        store.applyTransition(.wipe,from:a,to:nil); note()
        store.updateSelectedTransition(kind:.push); note()
        store.updateSelectedTransition(direction:.up); note()
        store.updateSelectedTransition(duration:.init(seconds:0.5)); note()
        store.removeSelectedTransition(); note()
        store.addTrack(.video); note(); store.addTrack(.audio); note()
        store.removeTrack(Lane(.audio,3)); note(); store.removeTrack(Lane(.video,3)); note()
        store.addText(); note()
        store.selectedClipID = b; XCTAssertTrue(store.copySelection()); store.seek(.init(seconds:40)); store.pasteClips(); note()
        store.selectClips([a,b]); XCTAssertTrue(store.copySelection()); store.seek(.init(seconds:50)); store.pasteClips(); note()
        store.selectedClipID = b; store.cutSelection(); note()
        store.selectClips(Set(store.project.clips.filter { $0.start >= .init(seconds:50) }.map(\.id))); store.cutSelection(); note()
        store.selectedClipID = a; store.deleteSelection(); note()
        store.selectAllClips(); store.deleteSelection(); note()
        store.undo()
        store.selectGap(Editing.gap(on:.v2,at:.init(seconds:12),in:store.project)); store.closeSelectedGap(); note()
        try store.setVideoSettings(aspectRatio:.portrait,frameRate:.init(30)); note()
        XCTAssertNil(store.message,"every step above applied")
        XCTAssertTrue(names.contains("Remove video track") && names.contains("Remove audio track"),"\(names)")
        // Recorded elsewhere: the inspector's sliders and colours, typing, fonts, the preview, import, relink.
        let elsewhere = ["Adjust clip","Edit text","Font","Font size","Text colour","Outline","Outline colour","Shadow","Shadow colour",
                         "Alignment point","Import media","Relink media","Transition kind"]
        let untranslated = (names+elsewhere).filter { korean[$0] == nil }
        XCTAssertEqual(untranslated,[],"undo names without a Korean entry")
    }
}
