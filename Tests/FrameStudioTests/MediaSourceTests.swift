import AppKit
import XCTest
import FrameCore
import FrameMedia
@testable import FrameStudio

/// Sources in the media library: missing ones the timeline uses or not, sources moved or deleted
/// while the project is open, relinking and undoing it, importing a file twice, and where a
/// double-click puts a source.
final class MediaSourceTests: ProjectTestCase {
    /// A saved project with `used` on V1 and `unused` only in the library, reopened in a new store.
    private func document(using used: URL, keeping unused: URL? = nil) async throws -> URL {
        let store = makeStore()
        store.importFiles([used] + (unused.map { [$0] } ?? []))
        let imported = await eventually { !store.isImporting }
        XCTAssertTrue(imported)
        let media = try XCTUnwrap(store.project.media.first { $0.name == used.lastPathComponent })
        XCTAssertTrue(store.addMedia(media.id))
        let url = folder.appendingPathComponent("Sources.framestudio")
        try ProjectFile.encode(store.project).write(to:url)
        return url
    }
    private func opened(_ url: URL) async throws -> EditorStore {
        let store = makeStore()
        XCTAssertTrue(store.openProject(url))
        let built = await eventually { !store.isBuilding }
        XCTAssertTrue(built)
        return store
    }
    private func isWide(_ image: NSImage?) -> Bool? { image.map { $0.size.width > $0.size.height } }

    /// A missing source no clip uses is marked in the library but stops nothing.
    func testAnUnusedMissingSourceDoesNotBlockThePreview() async throws {
        let used = try makeStill("Used.png",width:64,height:36), unused = try makeStill("Unused.png",width:36,height:64)
        let url = try await document(using:used,keeping:unused)
        try FileManager.default.removeItem(at:unused)
        let store = try await opened(url)
        let gone = try XCTUnwrap(store.project.media.first { $0.name == "Unused.png" })
        XCTAssertEqual(store.missing,[gone.id],"the library shows it Missing with Relink…")
        XCTAssertTrue(store.missingInUse.isEmpty)
        XCTAssertNotNil(store.player.currentItem,"the preview builds")
        XCTAssertNil(store.message)
        XCTAssertTrue(store.canCaptureSnapshot)
        XCTAssertEqual(store.status,"Clips: 1 · SDR Rec.709")
        XCTAssertFalse(store.dirty)
        XCTAssertFalse(store.addMedia(gone.id),"it goes on the timeline only once relinked")
        store.message = nil
    }

    /// Deleted in Finder while the project is open: the next build marks it missing instead of failing.
    func testASourceDeletedWhileOpenIsMarkedMissing() async throws {
        let source = try makeStill("Clip.png",width:64,height:36)
        let store = try await opened(try await document(using:source))
        XCTAssertNotNil(store.player.currentItem)
        let media = store.project.media[0]
        try FileManager.default.removeItem(at:source)
        store.addText()                                        // any edit rebuilds the preview
        XCTAssertEqual(store.missing,[media.id])
        XCTAssertEqual(store.missingInUse,[media.id],"the viewer asks to reconnect")
        XCTAssertNil(store.player.currentItem)
        XCTAssertEqual(store.status,"Missing sources: 1 · Use Relink in the library")
        XCTAssertFalse(store.canCaptureSnapshot)
        try await Task.sleep(for:.milliseconds(400))
        XCTAssertNil(store.message,"no alert: the library offers Relink…")
    }

    /// Moved in Finder while the project is open: followed through its bookmark as soon as Ara is
    /// back in front (no unsaved change for it), or at the next edit, and the preview keeps working.
    func testASourceMovedWhileOpenIsFollowed() async throws {
        let source = try makeStill("Clip.png",width:64,height:36)
        let store = try await opened(try await document(using:source))
        let delegate = AppDelegate(); delegate.attach(store)
        let elsewhere = folder.appendingPathComponent("Moved",isDirectory:true)
        try FileManager.default.createDirectory(at:elsewhere,withIntermediateDirectories:true)
        let moved = elsewhere.appendingPathComponent("Clip.png")
        try FileManager.default.moveItem(at:source,to:moved)
        noteCached(moved)
        delegate.applicationDidBecomeActive(Notification(name:NSApplication.didBecomeActiveNotification))
        XCTAssertTrue(store.missing.isEmpty)
        XCTAssertEqual(ProjectHistory.normalized(store.project.media[0].path),ProjectHistory.normalized(moved.path))
        XCTAssertFalse(store.dirty,"following the file is not an edit")
        var built = await eventually { !store.isBuilding && store.player.currentItem != nil }
        XCTAssertTrue(built)
        // Moved again while Ara stays in front: the next edit finds it before building.
        let renamed = elsewhere.appendingPathComponent("Clip renamed.png")
        try FileManager.default.moveItem(at:moved,to:renamed)
        noteCached(renamed)
        store.addText()
        XCTAssertTrue(store.missing.isEmpty)
        XCTAssertEqual(ProjectHistory.normalized(store.project.media[0].path),ProjectHistory.normalized(renamed.path))
        built = await eventually { !store.isBuilding && store.player.currentItem != nil }
        XCTAssertTrue(built)
        XCTAssertNil(store.message)
    }

    /// Deleted in Finder while Ara was in the background: marked missing when Ara comes back, before
    /// any edit, and picked up again once the file is put back.
    func testComingBackToAraLooksForSourcesAgain() async throws {
        let source = try makeStill("Clip.png",width:64,height:36)
        let store = try await opened(try await document(using:source))
        let delegate = AppDelegate(); delegate.attach(store)
        let media = store.project.media[0], backup = folder.appendingPathComponent("Backup.png")
        try FileManager.default.copyItem(at:source,to:backup)
        try FileManager.default.removeItem(at:source)
        delegate.applicationDidBecomeActive(Notification(name:NSApplication.didBecomeActiveNotification))
        XCTAssertEqual(store.missing,[media.id])
        XCTAssertNil(store.player.currentItem)
        XCTAssertEqual(store.status,"Missing sources: 1 · Use Relink in the library")
        // Put back where it was.
        try FileManager.default.moveItem(at:backup,to:source)
        noteCached(source)
        delegate.applicationDidBecomeActive(Notification(name:NSApplication.didBecomeActiveNotification))
        XCTAssertTrue(store.missing.isEmpty)
        let built = await eventually { !store.isBuilding && store.player.currentItem != nil }
        XCTAssertTrue(built)
        XCTAssertNil(store.message)
    }

    /// Deleted in Finder, a source goes to the Trash and its bookmark follows it there. It is missing
    /// (the library offers Relink…, the viewer asks to reconnect), not followed into the Trash where
    /// it goes for good once emptied; reopened the same, and found again once put back. A folder
    /// named .Trash stands in for the Trash.
    func testASourceMovedToTheTrashIsMissingUntilPutBack() async throws {
        let source = try makeStill("Clip.png",width:64,height:36)
        let url = try await document(using:source)
        let store = try await opened(url)
        let delegate = AppDelegate(); delegate.attach(store)
        let media = store.project.media[0], trash = folder.appendingPathComponent(".Trash",isDirectory:true)
        try FileManager.default.createDirectory(at:trash,withIntermediateDirectories:true)
        let trashed = trash.appendingPathComponent("Clip.png")
        try FileManager.default.moveItem(at:source,to:trashed)
        noteCached(trashed)
        store.addText()                                        // any edit rebuilds the preview
        XCTAssertEqual(store.missing,[media.id])
        XCTAssertEqual(store.project.media[0].path,media.path,"the document still names its place")
        XCTAssertEqual(store.status,"Missing sources: 1 · Use Relink in the library")
        let reopened = try await opened(url)
        XCTAssertEqual(reopened.missing,[media.id],"reopened, the same")
        // Put Back.
        try FileManager.default.moveItem(at:trashed,to:source)
        delegate.applicationDidBecomeActive(Notification(name:NSApplication.didBecomeActiveNotification))
        XCTAssertTrue(store.missing.isEmpty)
        let built = await eventually { !store.isBuilding && store.player.currentItem != nil }
        XCTAssertTrue(built)
        XCTAssertNil(store.message)
    }

    /// Put back (or on a drive plugged in again) while Ara stays in front: the next edit finds it,
    /// and so does the drive being mounted, with no edit at all.
    func testASourceBackWhileAraStaysInFrontIsFound() async throws {
        let source = try makeStill("Clip.png",width:64,height:36)
        let store = try await opened(try await document(using:source))
        let media = store.project.media[0], backup = folder.appendingPathComponent("Backup.png")
        func gone() throws {
            try FileManager.default.copyItem(at:source,to:backup)
            try FileManager.default.removeItem(at:source)
            store.addText()
            XCTAssertEqual(store.missing,[media.id])
        }
        try gone()
        try FileManager.default.moveItem(at:backup,to:source)
        store.addText()
        XCTAssertTrue(store.missing.isEmpty,"the edit found it")
        var built = await eventually { !store.isBuilding && store.player.currentItem != nil }
        XCTAssertTrue(built)
        try gone()
        try FileManager.default.moveItem(at:backup,to:source)
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.didMountNotification,object:NSWorkspace.shared,
                                                   userInfo:["NSDevicePath":folder.path,NSWorkspace.volumeURLUserInfoKey:folder!])
        built = await eventually { store.missing.isEmpty && !store.isBuilding && store.player.currentItem != nil }
        XCTAssertTrue(built,"a drive mounted: found without an edit")
        XCTAssertNil(store.message)
    }

    /// Relinking replaces a source's thumbnail and waveform; undo and redo bring back those of the
    /// file the item points at, also when the relinked file's analysis lands late.
    func testUndoingARelinkBringsBackTheFirstFilesThumbnailAndWaveform() async throws {
        let wide = try makeStill("Wide.png",width:64,height:32), tall = try makeStill("Tall.png",width:32,height:64,red:0,green:0.4,blue:1)
        let loud = try makeTone("Loud.wav",amplitude:0.8), quiet = try makeTone("Quiet.wav",amplitude:0.2)
        let store = makeStore()
        store.importFiles([wide,loud])
        var done = await eventually { !store.isImporting && store.project.media.count == 2 }
        XCTAssertTrue(done)
        let still = try XCTUnwrap(store.project.media.first { $0.kind == .image }), tone = try XCTUnwrap(store.project.media.first { $0.kind == .audio })
        func peak() -> Float? { store.waveforms[tone.id]?.max() }
        done = await eventually { self.isWide(store.thumbnails[still.id]) == true && (peak() ?? 0) > 0.6 }
        XCTAssertTrue(done,"first files read")
        store.relink(still,to:tall)
        done = await eventually { self.isWide(store.thumbnails[still.id]) == false }
        XCTAssertTrue(done,"relinked: the tall file's thumbnail")
        store.relink(tone,to:quiet)
        done = await eventually { (peak() ?? 1) < 0.4 }
        XCTAssertTrue(done,"relinked: the quiet file's waveform")
        store.undo()
        done = await eventually { (peak() ?? 0) > 0.6 }
        XCTAssertTrue(done,"undo: the loud file's waveform again")
        store.undo()
        done = await eventually { self.isWide(store.thumbnails[still.id]) == true }
        XCTAssertTrue(done,"undo: the wide file's thumbnail again")
        store.redo()
        done = await eventually { self.isWide(store.thumbnails[still.id]) == false }
        XCTAssertTrue(done,"redo: the tall file's thumbnail again")
        store.undo()
        done = await eventually { self.isWide(store.thumbnails[still.id]) == true }
        XCTAssertTrue(done)
        // Undo straight after the relink lands, while the tall file may still be being read: its
        // late result must not replace the wide file's thumbnail.
        store.relink(still,to:tall)
        done = await eventually(5) { store.project.media.first { $0.id == still.id }?.name == "Tall.png" }
        XCTAssertTrue(done)
        store.undo()
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertEqual(store.project.media.first { $0.id == still.id }?.name,"Wide.png")
        XCTAssertEqual(isWide(store.thumbnails[still.id]),true)
    }

    /// The same file reached through a symbolic link, or spelled with /private, is one source.
    func testTheSameFileImportedUnderAnotherSpellingIsAddedOnce() async throws {
        let still = try makeStill("Still.png",width:64,height:36)
        let link = folder.appendingPathComponent("Still link.png")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:still)
        noteCached(link)
        let store = makeStore()
        store.importFiles([still])
        var done = await eventually { !store.isImporting }
        XCTAssertTrue(done)
        let first = try XCTUnwrap(store.project.media.first)
        var spellings = [link]
        if still.path.hasPrefix("/var/") { spellings.append(URL(fileURLWithPath:"/private"+still.path)) }
        else if still.path.hasPrefix("/private/var/") { spellings.append(URL(fileURLWithPath:String(still.path.dropFirst("/private".count)))) }
        for url in spellings {
            store.selectedMediaID = nil
            store.importFiles([url])
            done = await eventually { !store.isImporting }
            XCTAssertTrue(done)
            XCTAssertEqual(store.project.media.map(\.id),[first.id],url.path)
            XCTAssertEqual(store.selectedMediaID,first.id,"the source already there is selected")
        }
    }

    /// Double-click or + appends audio at the end of its own track, a still at the end of V1, and a
    /// video with sound after both lanes it fills.
    func testAppendingPutsEachKindOfSourceAtTheEndOfItsOwnTracks() throws {
        let store = makeStore()
        let still = MediaReference(name:"Still",path:"/nonexistent/ara-append-still.png",kind:.image,duration:.init(seconds:5),width:640,height:360)
        let music = MediaReference(name:"Music",path:"/nonexistent/ara-append-music.wav",kind:.audio,duration:.init(seconds:4),hasAudio:true)
        let film = MediaReference(name:"Film",path:"/nonexistent/ara-append-film.mov",kind:.video,duration:.init(seconds:3),width:640,height:360,frameRate:30,hasAudio:true)
        XCTAssertTrue(store.edit("Fixture") { $0.media = [still,music,film] })
        func start(of id: UUID?) -> Double? { store.project.clips.first { $0.id == id }?.start.seconds }
        XCTAssertTrue(store.addMedia(still.id)); XCTAssertTrue(store.addMedia(still.id))           // V1 0–10 s
        XCTAssertTrue(store.addMedia(music.id))
        XCTAssertEqual(store.selectedClip?.lane,.a1)
        XCTAssertEqual(start(of:store.selectedClipID),0,"A1 is empty: the music starts at 0, not after the stills")
        XCTAssertTrue(store.addMedia(film.id))
        XCTAssertEqual(store.selectedClip?.lane,.v1)
        XCTAssertEqual(start(of:store.selectedClipID),10,"a video with sound goes after both V1 and A1")
        XCTAssertTrue(store.addMedia(music.id))
        XCTAssertEqual(start(of:store.selectedClipID),13,"after the film's own sound on A1")
        XCTAssertTrue(store.addMedia(music.id,lane:.a2))
        XCTAssertEqual(start(of:store.selectedClipID),0,"A2 is empty")
        XCTAssertTrue(store.addMedia(still.id))
        XCTAssertEqual(start(of:store.selectedClipID),13,"a still only looks at V1")
        store.message = nil
    }
}
