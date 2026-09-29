import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import FrameCore
import FrameMedia
@testable import FrameStudio

/// A folder of its own for each test, stores whose start-screen list lives in their own defaults,
/// and nothing left behind: no question shown on screen, no thumbnail in Ara's cache.
@MainActor class ProjectTestCase: XCTestCase {
    private(set) var folder: URL!
    /// One domain for every run, emptied before and after each test: an emptied suite still leaves
    /// its (empty) file behind.
    private let suite = "ara.tests.projects"
    /// Ara's cache entries (thumbnails, waveforms) the test's sources may have made.
    private var cacheKeys: Set<String> = []
    override func setUp() async throws {
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-project-tests-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
    }
    override func tearDown() async throws {
        try? await Task.sleep(for:.milliseconds(300))       // start-screen bookmarks land in the background
        UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
        for key in cacheKeys {
            for suffix in [".jpg",".json"] { try? FileManager.default.removeItem(at:MediaPaths.cache.appendingPathComponent(key+suffix)) }
        }
        try? FileManager.default.removeItem(at:folder)
    }
    /// A store whose questions fail the test unless it answers them itself.
    func makeStore() -> EditorStore {
        let store = EditorStore(registry:ProjectRegistry(defaults:UserDefaults(suiteName:suite)!))
        store.runAlert = { alert in XCTFail("Unexpected question: \(alert.messageText)"); return .alertSecondButtonReturn }
        return store
    }
    /// Lets the store's tasks run until `condition` holds, for up to `seconds`.
    func eventually(_ seconds: Double = 10, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for:.milliseconds(10))
        }
        return true
    }
    /// Notes where Ara caches this file's thumbnail and waveform, under every spelling of its path.
    func noteCached(_ url: URL) {
        var paths: Set<String> = [url.path,url.standardizedFileURL.resolvingSymlinksInPath().path]
        for path in paths {
            if path.hasPrefix("/private/") { paths.insert(String(path.dropFirst("/private".count))) }
            else if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { paths.insert("/private"+path) }
        }
        for path in paths { cacheKeys.insert(MediaPaths.key(for:URL(fileURLWithPath:path))) }
    }
    /// A solid still, `width` × `height`.
    func makeStill(_ name: String, width: Int, height: Int, red: CGFloat = 1, green: CGFloat = 0.5, blue: CGFloat = 0) throws -> URL {
        let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                                bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red:red,green:green,blue:blue,alpha:1); context.fill(CGRect(x:0,y:0,width:width,height:height))
        let url = folder.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,context.makeImage()!,nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        noteCached(url); return url
    }
    /// A 440 Hz tone whose peaks reach `amplitude`.
    func makeTone(_ name: String, amplitude: Float, seconds: Double = 1) throws -> URL {
        let url = folder.appendingPathComponent(name), rate = 8000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:rate,channels:1))
        let frames = AVAudioFrameCount(rate*seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames)); buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = amplitude*sin(Float(i)*2*Float.pi*440/Float(rate)) }
        let file = try AVAudioFile(forWriting:url,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:rate,AVNumberOfChannelsKey:1,
                                                            AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false])
        try file.write(from:buffer); file.close()
        noteCached(url); return url
    }
    /// A project document with one title, as Ara writes it.
    func makeDocument(_ fileName: String, name: String = "Trip", in folder: URL? = nil) throws -> URL {
        var project = Project(); project.name = name
        project.clips = [Clip(name:"Title",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3))]
        let url = (folder ?? self.folder).appendingPathComponent(fileName)
        try ProjectFile.encode(project).write(to:url)
        return url
    }
    func clipCount(_ url: URL) -> Int? { (try? ProjectFile.decode(Data(contentsOf:url)))?.clips.count }
}

/// The project document: the save question, saving where the file is now, what saving keeps on
/// the file, the name, and the files Ara is asked to open.
final class ProjectDocumentTests: ProjectTestCase {
    /// Quitting or closing the window right after typing in a title: the last keystrokes are still
    /// waiting on the inspector's short commit delay, and must count as unsaved work.
    func testQuittingRightAfterTypingATitleAsksToSave() async throws {
        let store = makeStore(), url = try makeDocument("Trip.framestudio")
        XCTAssertTrue(store.openProject(url))
        let title = store.project.clips[0].id
        // What the inspector's title field hands the store while a draft waits to be committed.
        var draft = "Jeju"
        store.flushPendingEdits = { [weak store] in store?.updateStyleLive(title,name:"Edit text",closesWhenIdle:false) { $0.text = draft } }
        XCTAssertFalse(store.dirty,"the typing has not reached the project yet")
        var asked: [String] = []
        store.runAlert = { alert in asked.append(alert.messageText); return .alertSecondButtonReturn }       // Cancel
        let delegate = AppDelegate(); delegate.attach(store)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateCancel)
        XCTAssertEqual(asked,["Save changes to Trip?"])
        XCTAssertEqual(store.project.clips[0].style.text,"Jeju")
        // Closing the window asks the same way, again with the latest keystrokes.
        draft = "Jeju trip"
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:200,height:100),styleMask:[.titled,.closable],backing:.buffered,defer:true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertFalse(delegate.windowShouldClose(window))
        XCTAssertEqual(asked.count,2)
        // Saving from the question writes what was typed, then lets Ara quit.
        draft = "Jeju trip 2026"
        store.runAlert = { alert in asked.append(alert.messageText); return .alertFirstButtonReturn }        // Save
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateNow)
        XCTAssertEqual(asked.count,3)
        XCTAssertEqual(try ProjectFile.decode(Data(contentsOf:url)).clips.first?.style.text,"Jeju trip 2026")
        XCTAssertFalse(store.dirty)
    }

    /// Renamed or moved in Finder while open, then ⌘S: the edits go to the file where it is now.
    func testSaveFollowsTheDocumentRenamedOrMovedInFinder() async throws {
        let store = makeStore(), original = try makeDocument("Untitled.framestudio",name:"Untitled")
        XCTAssertTrue(store.openProject(original))
        let followed = await eventually { store.documentBookmark != nil }
        XCTAssertTrue(followed)
        store.addText()
        let renamed = folder.appendingPathComponent("Jeju trip.framestudio")
        try FileManager.default.moveItem(at:original,to:renamed)
        XCTAssertTrue(store.save())
        XCTAssertFalse(FileManager.default.fileExists(atPath:original.path),"not written again at the old path")
        XCTAssertEqual(clipCount(renamed),2)
        XCTAssertEqual(store.documentURL.map { ProjectHistory.normalized($0.path) },ProjectHistory.normalized(renamed.path))
        XCTAssertEqual(store.project.name,"Jeju trip")
        XCTAssertFalse(store.dirty)
        // The start screen lists it once, under its new name and place.
        XCTAssertEqual(store.registry.history.entries.map(\.path),[ProjectHistory.normalized(renamed.path)])
        // Moved to another folder, then saved again.
        let refollowed = await eventually { store.documentBookmark != nil }
        XCTAssertTrue(refollowed)
        store.addText()
        let elsewhere = folder.appendingPathComponent("Trips",isDirectory:true)
        try FileManager.default.createDirectory(at:elsewhere,withIntermediateDirectories:true)
        let moved = elsewhere.appendingPathComponent("Jeju trip.framestudio")
        try FileManager.default.moveItem(at:renamed,to:moved)
        XCTAssertTrue(store.save())
        XCTAssertFalse(FileManager.default.fileExists(atPath:renamed.path))
        XCTAssertEqual(clipCount(moved),3)
        XCTAssertEqual(store.registry.history.entries.map(\.path),[ProjectHistory.normalized(moved.path)])
    }

    /// Renamed in Finder while open, then chosen on the start screen, where its card has followed
    /// it: that is the open document, so editing resumes without a question.
    func testTheStartScreenCardOfTheRenamedOpenDocumentResumesIt() async throws {
        let store = makeStore(), original = try makeDocument("Untitled.framestudio",name:"Untitled")
        XCTAssertTrue(store.openProject(original))
        let followed = await eventually { store.documentBookmark != nil }
        XCTAssertTrue(followed)
        store.addText()
        let renamed = folder.appendingPathComponent("Jeju trip.framestudio")
        try FileManager.default.moveItem(at:original,to:renamed)
        store.showStartScreen()
        store.openFromLauncher(renamed.path)                   // an unexpected save question fails the test
        XCTAssertFalse(store.showLauncher)
        XCTAssertEqual(store.project.clips.count,2,"the unsaved edit is still there")
        XCTAssertTrue(store.save())
        XCTAssertEqual(clipCount(renamed),2)
        XCTAssertFalse(FileManager.default.fileExists(atPath:original.path))
    }

    /// Deleted, or put in the Trash, while open: ⌘S writes the document where it was, never into the Trash.
    func testSaveWritesADeletedOrTrashedDocumentWhereItWas() async throws {
        let store = makeStore(), url = try makeDocument("Trip.framestudio")
        XCTAssertTrue(store.openProject(url))
        var followed = await eventually { store.documentBookmark != nil }
        XCTAssertTrue(followed)
        store.addText()
        try FileManager.default.removeItem(at:url)
        XCTAssertTrue(store.save())
        XCTAssertEqual(clipCount(url),2)
        // A folder named like the Trash stands in for it, so nothing reaches the user's own Trash.
        followed = await eventually { store.documentBookmark != nil }
        XCTAssertTrue(followed)
        store.addText()
        let trash = folder.appendingPathComponent(".Trash",isDirectory:true)
        try FileManager.default.createDirectory(at:trash,withIntermediateDirectories:true)
        let trashed = trash.appendingPathComponent("Trip.framestudio")
        try FileManager.default.moveItem(at:url,to:trashed)
        XCTAssertTrue(store.save())
        XCTAssertEqual(clipCount(url),3)
        XCTAssertEqual(clipCount(trashed),2,"the trashed copy is left as it was")
        XCTAssertEqual(store.documentURL,url)
        XCTAssertTrue(EditorStore.isInTrash(URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent(".Trash/Trip.framestudio")))
        XCTAssertTrue(EditorStore.isInTrash(URL(fileURLWithPath:"/Volumes/Media/.Trashes/501/Trip.framestudio")))
        XCTAssertFalse(EditorStore.isInTrash(url))
    }

    /// Saving keeps what Finder keeps on the file: tags, other extended attributes, permissions and
    /// the creation date.
    func testSaveKeepsFinderTagsAttributesPermissionsAndCreationDate() async throws {
        var url = try makeDocument("Tagged.framestudio")
        try (url as NSURL).setResourceValue(["Red","Work"],forKey:.tagNamesKey)
        XCTAssertEqual(url.withUnsafeFileSystemRepresentation { setxattr($0,"com.example.ara-test","kept",4,0,0) },0)
        let created = Date(timeIntervalSince1970:1_700_000_000)
        try FileManager.default.setAttributes([.posixPermissions:0o640,.creationDate:created],ofItemAtPath:url.path)
        let store = makeStore()
        XCTAssertTrue(store.openProject(url))
        store.addText()
        XCTAssertTrue(store.save())
        url.removeAllCachedResourceValues()
        XCTAssertEqual(clipCount(url),2)
        XCTAssertEqual(try url.resourceValues(forKeys:[.tagNamesKey]).tagNames,["Red","Work"])
        var value = [UInt8](repeating:0,count:4)
        XCTAssertEqual(url.withUnsafeFileSystemRepresentation { getxattr($0,"com.example.ara-test",&value,4,0,0) },4)
        XCTAssertEqual(String(decoding:value,as:UTF8.self),"kept")
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int,0o640)
        XCTAssertEqual(attributes[.creationDate] as? Date,created)
        // A read-only document still saves, as before.
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:url.path)
        store.addText()
        XCTAssertTrue(store.save())
        XCTAssertEqual(clipCount(url),3)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? Int,0o444)
    }

    /// A document in a folder shared with a group (Get Info ▸ Sharing & Permissions): saving keeps
    /// the access list the file has from the folder, and the folder's group, as writing it in
    /// place would, so the others keep their access.
    func testSaveKeepsTheSharedFoldersAccessListAndGroup() throws {
        let shared = folder.appendingPathComponent("Shared",isDirectory:true)
        try FileManager.default.createDirectory(at:shared,withIntermediateDirectories:true)
        func group(_ url: URL) -> UInt32? { (try? FileManager.default.attributesOfItem(atPath:url.path))?[.groupOwnerAccountID] as? UInt32 }
        func acl(_ url: URL) -> String? {
            guard let acl = acl_get_file(url.path,ACL_TYPE_EXTENDED) else { return nil }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            guard let text = acl_to_text(acl,nil) else { return nil }
            defer { acl_free(UnsafeMutableRawPointer(text)) }
            return String(cString:text)
        }
        // Another group of the user's than the one new files get, as a shared folder's would be.
        var groups = [gid_t](repeating:0,count:64)
        let count = max(0,Int(getgroups(Int32(groups.count),&groups))), own = try XCTUnwrap(group(shared))
        guard let other = groups.prefix(count).first(where: { $0 != own && chown(shared.path,uid_t.max,$0) == 0 }) else { throw XCTSkip("no second group to share with") }
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath:"/bin/chmod")
        chmod.arguments = ["+a","group:_lpadmin allow read,write,append,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit",shared.path]
        try chmod.run(); chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus,0)
        let url = try makeDocument("Team.framestudio",in:shared)
        let access = try XCTUnwrap(acl(url),"the new document takes the folder's entry")
        XCTAssertTrue(access.contains("_lpadmin")); XCTAssertEqual(group(url),other)
        let store = makeStore()
        XCTAssertTrue(store.openProject(url))
        store.addText()
        XCTAssertTrue(store.save())
        XCTAssertEqual(clipCount(url),2)
        XCTAssertEqual(acl(url),access); XCTAssertEqual(group(url),other)
    }

    /// A document opened through a symbolic link: ⌘S updates the file it points at and the link stays.
    func testSaveWritesThroughASymbolicLink() async throws {
        let real = try makeDocument("Real.framestudio")
        let link = folder.appendingPathComponent("Shortcut.framestudio")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:real)
        let store = makeStore()
        XCTAssertTrue(store.openProject(link))
        store.addText()
        XCTAssertTrue(store.save())
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:link.path)[.type] as? FileAttributeType,.typeSymbolicLink)
        XCTAssertEqual(clipCount(real),2)
        XCTAssertEqual(store.registry.history.entries.map(\.path),[ProjectHistory.normalized(real.path)],"listed once")
    }

    /// Saving names the project after its file; undo and redo leave that name alone.
    func testUndoAndRedoKeepTheNameOfTheFile() async throws {
        let store = makeStore(), url = try makeDocument("Jeju trip.framestudio",name:"Untitled")
        XCTAssertTrue(store.openProject(url))
        store.addText()
        XCTAssertTrue(store.save())
        XCTAssertEqual(store.project.name,"Jeju trip")
        store.undo()
        XCTAssertEqual(store.project.name,"Jeju trip")
        XCTAssertEqual(store.project.clips.count,1)
        XCTAssertTrue(store.dirty)
        store.redo()
        XCTAssertEqual(store.project.name,"Jeju trip")
        XCTAssertFalse(store.dirty)
    }

    /// Only line breaks and control characters are refused: joiners in emoji, ZWNJ, a soft hyphen
    /// and a direction mark are ordinary text.
    func testProjectNamesRefuseOnlyLineBreaksAndControlCharacters() throws {
        let store = makeStore()
        store.runAlert = { _ in .alertThirdButtonReturn }                      // Discard Changes
        for name in ["가족 여행 👨‍👩‍👧","Pride 🏳️‍🌈","می‌خواهم","Photo\u{00AD}graphy","\u{200E}Seoul","작업 👩‍💻",String(repeating:"🎬",count:120)] {
            XCTAssertTrue(try store.createProject(name:name,aspectRatio:.landscape,frameRate:.init(30),resolution:1080),name.debugDescription)
            XCTAssertEqual(store.project.name,name)
        }
        for name in ["a\nb","a\r\nb","a\u{2028}b","a\u{2029}b","a\u{0085}b","a\tb","a\u{1B}b",String(repeating:"a",count:121)] {
            XCTAssertThrowsError(try store.createProject(name:name,aspectRatio:.landscape,frameRate:.init(30),resolution:1080),name.debugDescription) { error in
                XCTAssertEqual(error.localizedDescription,"Use a project name of up to 120 characters, without line breaks or tabs.")
            }
        }
        // A name of characters that draw nothing would show blank everywhere: it is no name, and
        // the sheet's Create button stays off for it.
        for name in ["\u{200B}","\u{2060}","\u{FEFF}","\u{00AD}","\u{200E}\u{200F}"," \u{2060} ","\u{3164}"] {
            XCTAssertFalse(EditorStore.isVisibleName(name),name.debugDescription)
            XCTAssertThrowsError(try store.createProject(name:name,aspectRatio:.landscape,frameRate:.init(30),resolution:1080),name.debugDescription) { error in
                XCTAssertEqual(error.localizedDescription,"Enter a project name.")
            }
        }
        XCTAssertTrue(EditorStore.isVisibleName("\u{200E}Seoul")); XCTAssertTrue(EditorStore.isVisibleName("👨‍👩‍👧"))
    }

    /// Files opened with Ara (Finder, the Dock) or dropped on the library or timeline.
    func testFilesOpenedWithAraOpenProjectsWhateverTheirCase() async throws {
        // Launch Services matches the extension in any case.
        let upper = try makeDocument("Upper.FRAMESTUDIO",name:"Upper")
        let store = makeStore(), delegate = AppDelegate(); delegate.attach(store)
        delegate.application(NSApplication.shared,open:[upper])
        XCTAssertEqual(store.documentURL,upper)
        XCTAssertEqual(store.project.name,"Upper")
        XCTAssertNil(store.message)
        XCTAssertFalse(store.isImporting)
        // Dropped on the library or the timeline: opened, not read as media.
        let dropped = try makeDocument("Dropped.framestudio",name:"Dropped")
        store.importFiles([dropped])
        XCTAssertEqual(store.documentURL,dropped)
        XCTAssertNil(store.message)
        // Two at once: Ara keeps one project open, so the other goes on the start screen, and a note says so.
        let a = try makeDocument("A.framestudio",name:"A"), b = try makeDocument("B.framestudio",name:"B")
        delegate.application(NSApplication.shared,open:[a,b,a])
        XCTAssertEqual(store.documentURL,a)
        XCTAssertEqual(store.message,"Ara opens one project at a time. These were put on the start screen instead: B.framestudio.")
        XCTAssertEqual(store.registry.history.entries.first?.path,ProjectHistory.normalized(b.path))
        store.message = nil
    }

    /// The Export sheet is up (not exporting yet) and a project is opened from Finder or the Dock:
    /// the sheet, made with the first project's settings, closes with it, so its Apply cannot turn
    /// the opened project to them.
    func testOpeningAProjectUnderTheExportSheetClosesTheSheet() async throws {
        let other = try makeDocument("Other.framestudio",name:"Other")
        let store = makeStore(), delegate = AppDelegate(); delegate.attach(store)
        store.runAlert = { _ in .alertThirdButtonReturn }                      // Discard Changes
        XCTAssertTrue(try store.createProject(name:"Mine",aspectRatio:.portrait,frameRate:.init(24),resolution:1080))
        store.showExportSheet = true
        delegate.application(NSApplication.shared,open:[other])
        XCTAssertEqual(store.documentURL,other)
        XCTAssertFalse(store.showExportSheet)
        XCTAssertEqual(store.project.frameRate,.init(30)); XCTAssertEqual(store.project.aspectRatio,.landscape)
    }

    func testMediaOpenedTogetherWithAProjectGoIntoIt() async throws {
        let document = try makeDocument("Trip.framestudio"), still = try makeStill("Still.png",width:64,height:36)
        let store = makeStore(), delegate = AppDelegate(); delegate.attach(store)
        delegate.application(NSApplication.shared,open:[document,still])
        XCTAssertEqual(store.documentURL,document)
        let imported = await eventually { !store.isImporting }
        XCTAssertTrue(imported)
        XCTAssertEqual(store.project.media.map(\.name),["Still.png"])
        XCTAssertNil(store.message)
        XCTAssertTrue(store.dirty)
    }

    func testOpeningAProjectDuringAnExportSaysWhyNot() async throws {
        let document = try makeDocument("Trip.framestudio")
        let store = makeStore(), delegate = AppDelegate(); delegate.attach(store)
        var asked: [String] = []
        store.runAlert = { alert in asked.append("\(alert.messageText) / \(alert.informativeText)"); return .alertFirstButtonReturn }
        store.isExporting = true
        defer { store.isExporting = false }
        delegate.application(NSApplication.shared,open:[document])
        XCTAssertEqual(asked,["An output is being saved / Open “Trip.framestudio” again once the export has finished."])
        XCTAssertNil(store.documentURL)
    }
}
