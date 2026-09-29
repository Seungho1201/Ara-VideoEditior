import AppKit
import ObjectiveC
import XCTest
import FrameCore
import FrameMedia
@testable import FrameStudio

/// The Korean string table as a whole, and words that reach it from outside the panels: the
/// engine's messages, the one key name written out, and counts of one.
@MainActor final class StringTableTests: XCTestCase {
    private var table: URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ko.lproj/Localizable.strings")
    }
    /// Runs `body` with Bundle.main answering from a bundle that holds only the app's Korean table,
    /// as Ara.app does in Korean: what goes through the table comes out in Korean.
    private func inKorean(_ body: () throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-korean-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at:folder) }
        let lproj = folder.appendingPathComponent("Contents/Resources/ko.lproj")
        try FileManager.default.createDirectory(at:lproj,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:table,to:lproj.appendingPathComponent("Localizable.strings"))
        let info: NSDictionary = ["CFBundleIdentifier":"ara.tests.korean","CFBundleDevelopmentRegion":"ko","CFBundleLocalizations":["ko"]]
        try info.write(to:folder.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url:folder))
        let method = try XCTUnwrap(class_getClassMethod(Bundle.self,#selector(getter:Bundle.main)))
        let original = method_getImplementation(method)
        let korean: @convention(block) (AnyObject) -> Bundle = { _ in bundle }
        method_setImplementation(method,imp_implementationWithBlock(korean))
        defer { method_setImplementation(method,original) }
        try body()
    }
    /// A string's format specifiers by position ("%2$@" is the second, like the second "%@").
    private func specifiers(_ text: String) -> [String] {
        var next = 0
        return text.matches(of:/%(\d+\$)?(\.\d+)?(lld|ld|d|f|@)/).map { match in
            next += 1
            let position = match.1.map { String($0.dropLast()) } ?? String(next)
            return "\(position) \(match.3)"
        }.sorted()
    }

    /// Every entry on a line of its own, each key once (the property list keeps only the last of
    /// a repeated key), with its key's format specifiers and escaped percent signs.
    func testEachKeyIsTranslatedOnceWithItsSpecifiers() throws {
        let text = try String(contentsOf:table,encoding:.utf8)
        var keys: [String] = []
        for line in text.split(separator:"\n") where !line.isEmpty && !line.hasPrefix("/*") {
            guard let entry = line.wholeMatch(of:/"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";/) else { XCTFail("not an entry: \(line)"); continue }
            let key = String(entry.1), value = String(entry.2)
            keys.append(key)
            XCTAssertEqual(specifiers(value),specifiers(key),key)
            XCTAssertEqual(value.ranges(of:"%%").count,key.ranges(of:"%%").count,key)
            XCTAssertFalse(value.replacing(/%%|%(\d+\$)?(\.\d+)?(lld|ld|d|f|@)/,with:"").contains("%"),"a lone % in the Korean for “\(key)”")
        }
        XCTAssertEqual(Set(keys).count,keys.count,"repeated: \(Dictionary(grouping:keys,by:{ $0 }).filter { $0.value.count > 1 }.keys.sorted())")
        let parsed = try XCTUnwrap(NSDictionary(contentsOf:table) as? [String:String])
        XCTAssertEqual(parsed.count,keys.count)
    }

    /// The engine's refusals and errors (FrameCore and FrameMedia) come out in the app's language,
    /// their values filled in, like the app's own words.
    func testTheEnginesMessagesAreInKorean() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-engine-words-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        var project = Project()
        let media = MediaReference(name:"Six",path:"/six.mov",kind:.video,duration:.init(seconds:6),hasAudio:true)
        project.media = [media]
        let id = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
        try Editing.trim(id,leading:false,to:.init(ticks:project.frameRate.frame.ticks*3),in:&project)
        let fake = folder.appendingPathComponent("Fake.ttf"); try Data("not a font".utf8).write(to:fake)
        func message(_ work: () throws -> Void) -> String? {
            do { try work(); return nil } catch { return error.localizedDescription }
        }
        XCTAssertEqual(message { try Editing.setSpeed(id,to:10,in:&project) },
                       "At this speed the clip would last less than one frame. Choose a slower speed or lengthen the clip first.")
        try inKorean {
            XCTAssertEqual(EditError("Clips overlap on \(Lane.v2.rawValue). Use another track.").message,"V2 트랙에서 클립이 겹칩니다. 다른 트랙을 사용하십시오.")
            XCTAssertEqual(message { try Editing.setSpeed(id,to:10,in:&project) },
                           "이 속도에서는 클립이 한 프레임보다 짧아집니다. 더 느린 속도를 선택하거나 먼저 클립을 늘리십시오.")
            // A frame rate change names the clip it would lose: one frame at 60 fps is 0.4 of one at 24.
            var short = project
            try Editing.setVideoSettings(aspectRatio:.landscape,frameRate:.init(60),in:&short)
            try Editing.trim(id,leading:false,to:short.frameRate.frame,in:&short)
            XCTAssertEqual(message { try Editing.setVideoSettings(aspectRatio:.landscape,frameRate:.init(24),in:&short) },
                           "24 fps에서는 “Six” 클립이 한 프레임보다 짧아집니다. 클립을 늘리거나 다른 프레임 레이트를 선택하십시오.")
            XCTAssertEqual(message { _ = try FontLibrary.importFonts([fake],into:folder.appendingPathComponent("Fonts")) },
                           "새로 추가된 폰트가 없습니다.\nFake.ttf: CoreText가 읽을 수 있는 폰트가 아닙니다")
        }
    }

    /// Space is the one key written out rather than drawn as a symbol: in Korean it reads as the
    /// Korean menus write it, in Settings, tips and status alike.
    func testTheSpaceKeyIsNamedInTheAppsLanguage() throws {
        let suite = "ara.tests.words.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let shortcuts = ShortcutSettings(defaults:defaults)
        XCTAssertEqual(shortcuts.label(.playPause),"Space")
        try inKorean {
            XCTAssertEqual(shortcuts.label(.playPause),"스페이스")
            XCTAssertEqual(Shortcut("space",[.command,.control]).display,"⌃⌘스페이스")
            XCTAssertEqual(shortcuts.label(.split),"⌘B")
        }
    }

    /// The project a fresh store edits (media opened with Ara before any New Project go into it)
    /// is named in Ara's language, as the New Project sheet names one, and is no unsaved change.
    func testTheFirstProjectIsNamedInTheAppsLanguage() throws {
        _ = NSApplication.shared
        let suite = "ara.tests.first-project.\(UUID().uuidString)"
        defer { UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite) }
        let english = EditorStore(registry:ProjectRegistry(defaults:UserDefaults(suiteName:suite)!))
        XCTAssertEqual(english.project.name,"Untitled"); XCTAssertFalse(english.dirty)
        try inKorean {
            let store = EditorStore(registry:ProjectRegistry(defaults:UserDefaults(suiteName:suite)!))
            XCTAssertEqual(store.project.name,"제목 없음"); XCTAssertFalse(store.dirty)
            XCTAssertEqual(store.project.name,String(localized:"Untitled"),"as the New Project sheet has it")
        }
    }

    /// One font added reads “1 font” and “1 style”, not “1 fonts” and “1 styles”.
    func testAddingOneFontSaysOneFont() async throws {
        _ = NSApplication.shared
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ara-one-font-\(UUID().uuidString)",isDirectory:true)
        defer { try? FileManager.default.removeItem(at:scratch) }
        let store = EditorStore()
        store.fontFolder = scratch.appendingPathComponent("Fonts")
        let family = TestFont.uniqueFamily(), file = try TestFont.make(family:family,in:scratch)
        store.addFonts([file],applyToSelection:false)
        for _ in 0..<500 where store.isAddingFonts { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(store.status,"Added 1 font · \(family)")
        XCTAssertEqual(store.message,"Added \(family) (1 style). Choose it from a title's Font menu.")
        let korean = try XCTUnwrap(NSDictionary(contentsOf:table) as? [String:String])
        XCTAssertEqual(korean["Added 1 font · %@"],"폰트 1개 추가됨 · %@")
        XCTAssertEqual(korean["Added %@ (1 style). Choose it from a title's Font menu."],"%@ 추가됨 (스타일 1개). 자막의 폰트 메뉴에서 선택하십시오.")
    }
}
