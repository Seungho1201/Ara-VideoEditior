import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

/// While an export reads the project nothing else changes it: every editing action is refused,
/// playback waits, and New, Open and Import say why instead of doing nothing.
@MainActor final class ExportGuardTests: XCTestCase {
    /// Titles A (V1 0–3 s) and B (V1 3–6 s) with a cross dissolve between them, a title T on V1
    /// (8–10 s) after a gap, a video V on V2 (0–5 s, a fake path: nothing decodes it) and an empty V3.
    private func withStore(_ check: @MainActor (EditorStore, [String:UUID]) throws -> Void) throws {
        _ = NSApplication.shared
        let store = EditorStore()
        let pasteboard = NSPasteboard(name:.init("ara-export-guard-tests-\(UUID().uuidString)"))
        store.pasteboard = pasteboard                                      // never the user's clipboard
        defer { store.isExporting = false; pasteboard.releaseGlobally() }
        store.runAlert = { alert in XCTFail("Unexpected question: \(alert.messageText)"); return .alertSecondButtonReturn }
        let video = MediaReference(name:"Source.mov",path:"/nonexistent/ara-tests/Source.mov",kind:.video,duration:.init(seconds:20),width:640,height:360,frameRate:30)
        let a = Clip(name:"A",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3))
        let b = Clip(name:"B",kind:.text,lane:.v1,start:.init(seconds:3),duration:.init(seconds:3))
        let t = Clip(name:"T",kind:.text,lane:.v1,start:.init(seconds:8),duration:.init(seconds:2))
        var ids = ["A":a.id,"B":b.id,"T":t.id]
        let made = store.edit("Fixture") { project in
            project.frameRate = .init(30); project.media = [video]; project.clips = [a,b,t]
            ids["X"] = try Editing.setTransition(.crossDissolve,from:a.id,to:b.id,in:&project)
            ids["V"] = try Editing.add(mediaID:video.id,lane:.v2,at:.zero,to:&project)
            try Editing.trim(ids["V"]!,leading:false,to:.init(seconds:5),in:&project)
            try Editing.addTrack(.video,to:&project)
        }
        XCTAssertTrue(made,store.message ?? "")
        store.isBuilding = false
        try check(store,ids)
    }

    func testEveryEditingActionWaitsForTheExport() throws {
        try withStore { store, id in
            // Ready beforehand: something to redo, a clip on the clipboard, a gap to close.
            store.addText(); store.undo()
            XCTAssertTrue(store.canRedo)
            store.selectedClipID = id["B"]; XCTAssertTrue(store.copySelection())
            let gap = try XCTUnwrap(Editing.gap(on:.v1,at:.init(seconds:7),in:store.project))
            store.isExporting = true
            let before = store.project, undoName = store.undoName
            @MainActor func refused(_ name: String, _ action: () throws -> Void) rethrows {
                try action()
                XCTAssertEqual(store.project,before,"\(name) changed the project during an export")
            }
            store.selectedClipID = id["A"]; store.seek(.init(seconds:1))
            refused("Split") { store.split() }
            refused("Delete") { store.deleteSelection() }
            refused("Add Text") { store.addText() }
            refused("Undo") { store.undo() }
            refused("Redo") { store.redo() }
            refused("Paste") { store.pasteClips() }
            refused("Reset appearance") { store.updateStyle { style in let text = style.text; style = ClipStyle(); style.text = text } }
            refused("Typing a title") { store.updateStyleLive(id["A"]!,name:"Edit text",closesWhenIdle:false) { $0.text = "Typed" } }
            refused("Font") { store.applyFont("Georgia",to:id["A"]) }
            refused("Move") { store.move(id["A"]!,to:.init(seconds:20),lane:.v1) }
            refused("Trim") { store.trim(id["T"]!,leading:false,to:.init(seconds:9)) }
            store.selectedClipID = id["V"]
            refused("Speed") { XCTAssertFalse(store.setSpeed(2)) }
            refused("Custom speed") { XCTAssertFalse(store.setCustomSpeed("3")) }
            refused("Speed slider") { store.beginInteraction(); store.setSpeedInteractively(4); store.endInteraction() }
            try refused("Video settings") { try store.setVideoSettings(aspectRatio:.square,frameRate:.init(30),resolution:720) }
            refused("Add track") { store.addTrack(.video) }
            refused("Remove track") { store.removeTrack(Lane(.video,3)) }
            store.selectGap(gap)
            refused("Close gap") { store.closeSelectedGap() }
            store.selectTransition(id["X"])
            refused("Transition kind") { store.updateSelectedTransition(kind:.wipe) }
            refused("Transition length") { store.updateSelectedTransition(duration:.init(seconds:0.5)) }
            refused("Delete transition") { store.deleteSelection() }
            XCTAssertEqual(store.undoName,undoName,"no undo step was recorded")
            XCTAssertTrue(store.canRedo,"nor was the redo step used up")
            // Once the export is done, the same actions work again.
            store.isExporting = false
            store.selectedClipID = id["A"]; store.split()
            XCTAssertEqual(store.project.clips.count,before.clips.count+1)
        }
    }

    /// The menus stand their editing commands down (App.swift disables Undo, Redo, Import and the
    /// Timeline menu with this) while a sheet, an export or help mode covers the project.
    func testTheMenusEditingCommandsStandDown() throws {
        try withStore { store, _ in
            store.resumeEditing()
            XCTAssertFalse(store.editingSuspended)
            let covers: [(String,(Bool) -> Void)] = [("export",{ store.isExporting = $0 }),("Export sheet",{ store.showExportSheet = $0 }),
                                                     ("New Project sheet",{ store.showNewProjectSheet = $0 }),("help mode",{ store.showHelp = $0 })]
            for (name,set) in covers {
                set(true); XCTAssertTrue(store.editingSuspended,name)
                set(false); XCTAssertFalse(store.editingSuspended,name)
            }
        }
    }

    func testNewOpenAndImportSayWhyTheyWait() throws {
        try withStore { store, _ in
            var told: [String] = []
            store.runAlert = { alert in told.append("\(alert.messageText) / \(alert.informativeText)"); return .alertFirstButtonReturn }
            store.isExporting = true
            let before = store.project
            store.newProject()
            XCTAssertFalse(store.showNewProjectSheet)
            store.importFiles([URL(fileURLWithPath:"/nonexistent/ara-tests/Clip.mov")])
            XCTAssertFalse(store.isImporting)
            XCTAssertEqual(store.project,before)
            XCTAssertEqual(told,["An output is being saved / Start a new project once the export has finished.",
                                 "An output is being saved / Import these files again once the export has finished."])
            // Not exporting: no question, the sheet opens.
            store.isExporting = false; told = []
            store.newProject()
            XCTAssertTrue(store.showNewProjectSheet); XCTAssertEqual(told,[])
        }
    }

    /// Space during an export does not start the preview alongside the encode.
    func testPlaybackWaitsForTheExport() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        store.edit("Fixture") { $0.clips = [Clip(name:"Title",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:5))] }
        for _ in 0..<1000 where store.isBuilding || store.player.currentItem == nil { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotNil(store.player.currentItem)
        defer { store.isExporting = false; store.pause() }
        store.isExporting = true
        store.togglePlayback()
        XCTAssertFalse(store.isPlaying); XCTAssertEqual(store.player.rate,0)
    }
}

/// A pause while the preview rebuilds holds: the build does not start playback again.
@MainActor final class PlaybackResumeTests: XCTestCase {
    private func waitForPreview(_ store: EditorStore) async throws {
        for _ in 0..<1000 where store.isBuilding || store.player.currentItem == nil { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertFalse(store.isBuilding); XCTAssertNotNil(store.player.currentItem)
    }

    func testAPauseDuringARebuildIsKept() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        let title = Clip(name:"Title",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:8))
        store.edit("Fixture") { $0.clips = [title] }
        store.selectedClipID = title.id
        try await waitForPreview(store)
        defer { store.pause() }
        // Playing, an edit rebuilds the preview: playback carries on once it is up.
        store.togglePlayback(); XCTAssertTrue(store.isPlaying)
        store.updateStyle { $0.opacity = 0.9 }
        XCTAssertTrue(store.isBuilding); XCTAssertFalse(store.isPlaying)
        try await waitForPreview(store)
        XCTAssertTrue(store.isPlaying,"the rebuild resumes playback")
        // Paused while the next build runs (a scrub, a click on a clip): it stays paused.
        store.updateStyle { $0.opacity = 0.8 }
        XCTAssertTrue(store.isBuilding)
        store.pause()
        try await waitForPreview(store)
        XCTAssertFalse(store.isPlaying,"a pause during the build is kept"); XCTAssertEqual(store.player.rate,0)
        // Space (Play / Pause) during a build pauses too.
        store.togglePlayback(); XCTAssertTrue(store.isPlaying)
        store.updateStyle { $0.opacity = 0.7 }
        XCTAssertTrue(store.isBuilding)
        store.togglePlayback()
        try await waitForPreview(store)
        XCTAssertFalse(store.isPlaying,"Space during the build is a pause"); XCTAssertEqual(store.player.rate,0)
        // Stopped, Space during a build plays: the build lands with playback, waiting on nothing.
        store.updateStyle { $0.opacity = 0.6 }
        XCTAssertTrue(store.isBuilding)
        store.togglePlayback()
        try await waitForPreview(store)
        XCTAssertTrue(store.isPlaying,"Space during the build plays once it is up")
    }
}

/// Settings ▸ General ▸ Snapping (and N) is kept for the next launch, like the other switches.
@MainActor final class SnappingSettingTests: XCTestCase {
    func testSnappingIsKeptAcrossLaunches() {
        let key = "timeline.snapping", saved = UserDefaults.standard.object(forKey:key)
        defer { if let saved { UserDefaults.standard.set(saved,forKey:key) } else { UserDefaults.standard.removeObject(forKey:key) } }
        UserDefaults.standard.removeObject(forKey:key)
        XCTAssertTrue(EditorStore().snapping,"on at first")
        let store = EditorStore()
        store.snapping = false
        XCTAssertFalse(EditorStore().snapping,"still off when Ara starts again")
        store.snapping.toggle()
        XCTAssertTrue(EditorStore().snapping)
    }
}
