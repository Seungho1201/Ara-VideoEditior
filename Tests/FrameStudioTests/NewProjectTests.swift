import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

final class NewProjectTests: XCTestCase {
    /// A new project folds every sound (kept in the defaults): put back after each test.
    private var foldedSound: Any?
    override func setUp() { super.setUp(); foldedSound = UserDefaults.standard.object(forKey:"timeline.foldedSound") }
    override func tearDown() {
        if let foldedSound { UserDefaults.standard.set(foldedSound,forKey:"timeline.foldedSound") } else { UserDefaults.standard.removeObject(forKey:"timeline.foldedSound") }
        super.tearDown()
    }
    @MainActor func testOpeningAndCancellingSetupPreservesCurrentWork() {
        _ = NSApplication.shared
        let store = EditorStore()
        XCTAssertTrue(store.edit("Fixture") { project in
            project.name = "Work in progress"
            project.clips = [Clip(name:"Title",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:5))]
        })
        store.selectedClipID = store.project.clips[0].id
        store.seek(.init(seconds:2))
        let before = store.project, session = store.session, selection = store.selectedClipID
        let wasLauncher = store.showLauncher
        store.newProject() // Must not prompt to discard or reset the current session.
        XCTAssertTrue(store.showNewProjectSheet)
        store.showNewProjectSheet = false // The sheet's Cancel dismisses its presentation binding.
        XCTAssertEqual(store.project,before)
        XCTAssertEqual(store.session,session)
        XCTAssertEqual(store.selectedClipID,selection)
        XCTAssertEqual(store.playhead,.init(seconds:2))
        XCTAssertEqual(store.showLauncher,wasLauncher)
        XCTAssertTrue(store.dirty)
        XCTAssertTrue(store.canUndo)
    }

    @MainActor func testCreateUsesAllSettingsAndKeepsEmptyProjectAvailableForSaving() throws {
        _ = NSApplication.shared
        let store = EditorStore()
        let originalSession = store.session
        store.newProject()
        XCTAssertTrue(try store.createProject(name:"  여행 영상  ",aspectRatio:.portrait,frameRate:.init(60000,1001),resolution:2160))
        XCTAssertEqual(store.project.name,"여행 영상")
        XCTAssertEqual(store.project.aspectRatio,.portrait)
        XCTAssertEqual(store.project.frameRate,.init(60000,1001))
        XCTAssertEqual(store.exportHeight,2160)
        XCTAssertEqual(store.project.aspectRatio.size(resolution:store.exportHeight),CGSize(width:2160,height:3840))
        XCTAssertTrue(store.project.clips.isEmpty)
        XCTAssertTrue(store.project.media.isEmpty)
        XCTAssertTrue(store.hasOpenWork)
        XCTAssertTrue(store.dirty)
        XCTAssertNil(store.documentURL)
        XCTAssertFalse(store.showNewProjectSheet)
        XCTAssertFalse(store.showLauncher)
        XCTAssertFalse(store.canUndo)
        XCTAssertNotEqual(store.session,originalSession)
        XCTAssertEqual(try ProjectFile.decode(ProjectFile.encode(store.project)),store.project)
        store.showStartScreen()
        XCTAssertTrue(store.hasOpenWork)
        store.resumeEditing()
        XCTAssertFalse(store.showLauncher)
    }

    @MainActor func testInvalidSetupCannotReplaceEvenUnsavedWork() throws {
        _ = NSApplication.shared
        let store = EditorStore()
        XCTAssertTrue(store.edit("Fixture") { $0.name = "Keep this" })
        let before = store.project, session = store.session
        store.newProject()
        for name in [" \n ",String(repeating:"a",count:121),"line\nbreak"] {
            XCTAssertThrowsError(try store.createProject(name:name,aspectRatio:.portrait,frameRate:.init(60),resolution:2160))
        }
        XCTAssertThrowsError(try store.createProject(name:"Invalid fps",aspectRatio:.portrait,frameRate:.init(0),resolution:2160))
        XCTAssertThrowsError(try store.createProject(name:"Invalid quality",aspectRatio:.portrait,frameRate:.init(60),resolution:900))
        XCTAssertEqual(store.project,before)
        XCTAssertEqual(store.session,session)
        XCTAssertTrue(store.showNewProjectSheet)
    }

    @MainActor func testExportQualityFollowsProjectEditsUndoAndRedo() throws {
        _ = NSApplication.shared
        let store = EditorStore()
        try store.setVideoSettings(aspectRatio:.square,frameRate:.init(24),resolution:2160)
        XCTAssertEqual(store.exportHeight,2160)
        store.undo(); XCTAssertEqual(store.exportHeight,1080)
        store.redo(); XCTAssertEqual(store.exportHeight,2160)
    }
}
