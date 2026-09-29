import AppKit
import ObjectiveC
import SwiftUI
import Vision
import XCTest
import FrameCore
@testable import FrameStudio

/// What the start screen's cards, the media library, the inspector and the transition panel
/// write: every word through the string table with a Korean entry, and pixel sizes written plain.
@MainActor final class PanelWordsTests: XCTestCase {
    private func korean() throws -> [String:String] {
        let strings = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ko.lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf:strings) as? [String:String])
    }
    /// The format specifiers in a string, their positions aside ("%1$@" counts as "%@").
    private func specifiers(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern:"%(\\d+\\$)?(\\.\\d+)?(lld|ld|d|f|@|%)")
        return pattern.matches(in:text,range:NSRange(text.startIndex...,in:text)).map { match in
            (text as NSString).substring(with:match.range).replacingOccurrences(of:"\\d+\\$",with:"",options:.regularExpression)
        }.sorted()
    }
    private func assertKorean(_ keys: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let korean = try korean()
        for key in keys {
            guard let value = korean[key] else { XCTFail("no Korean for “\(key)”",file:file,line:line); continue }
            XCTAssertEqual(specifiers(value),specifiers(key),key,file:file,line:line)
        }
    }
    /// Runs `body` with Bundle.main answering from a bundle that holds only the app's Korean table,
    /// as Ara.app does in Korean: what goes through the table comes out in Korean.
    private func inKorean(_ body: () throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-korean-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at:folder) }
        let lproj = folder.appendingPathComponent("Contents/Resources/ko.lproj")
        try FileManager.default.createDirectory(at:lproj,withIntermediateDirectories:true)
        let strings = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ko.lproj/Localizable.strings")
        try FileManager.default.copyItem(at:strings,to:lproj.appendingPathComponent("Localizable.strings"))
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

    /// A card's second line, in each state, and the table's key for it.
    func testTheStartScreensCardsSayItInTheAppsLanguage() throws {
        var one = Project(); one.clips = [Clip(name:"A",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:1))]
        var two = one; two.clips.append(Clip(name:"B",kind:.text,lane:.v1,start:.init(seconds:1),duration:.init(seconds:1)))
        let date = Date(timeIntervalSinceNow:-7200), edited = date.formatted(.relative(presentation:.named))
        let cards: [(ProjectRegistry.Status?,String,String)] = [
            (.ready(ProjectSummary(one),modified:nil),"1 clip","1 clip"),
            (.ready(ProjectSummary(two),modified:nil),"2 clips","%lld clips"),
            (.ready(ProjectSummary(one),modified:date),"1 clip · Edited \(edited)","1 clip · Edited %@"),
            (.ready(ProjectSummary(two),modified:date),"2 clips · Edited \(edited)","%lld clips · Edited %@"),
            (.missing,"File not found · Right-click to remove","File not found · Right-click to remove"),
            (.unreadable("Bad data"),"Can’t open · Bad data","Can’t open · %@"),
            (.loading,"Reading…","Reading…"),(nil,"Reading…","Reading…")]
        for (status,shown,_) in cards { XCTAssertEqual(LauncherView.detail(status),shown) }
        try assertKorean(cards.map(\.2))
        try inKorean {
            XCTAssertEqual(LauncherView.detail(.ready(ProjectSummary(two),modified:nil)),"클립 2개")
            XCTAssertEqual(LauncherView.detail(.ready(ProjectSummary(one),modified:date)),"클립 1개 · \(edited) 편집")
            XCTAssertEqual(LauncherView.detail(.missing),"파일을 찾을 수 없음 · 오른쪽 클릭으로 목록에서 제거")
            XCTAssertEqual(LauncherView.detail(.unreadable("Bad data")),"열 수 없음 · Bad data")
            XCTAssertEqual(LauncherView.detail(.loading),"읽는 중…")
        }
    }

    /// Kinds and directions are named in the app's language; so are the library's badges and its
    /// tooltip, the inspector's lines and menus, and the transition panel's edges.
    func testThePanelsWordsHaveKoreanEntries() throws {
        try assertKorean([MediaKind.video,.audio,.image,.text].map(\.displayName))
        try assertKorean(TransitionDirection.allCases.map(\.displayName))
        try inKorean {
            XCTAssertEqual([MediaKind.video,.audio,.image,.text].map(\.displayName),["비디오","오디오","이미지","텍스트"])
            XCTAssertEqual(TransitionDirection.allCases.map(\.displayName),["왼쪽","오른쪽","위쪽","아래쪽"])
        }
        try assertKorean(["STILL","Preparing preview · %@","Preparing preview · %@ · %lld more","1x · Normal",
                          "Linked A/V","A title holds up to %lld characters.","Across a cut","Fade in","Fade out","%.2f s",
                          "%@ (missing)","Added","System","Font family","Font style",
                          "Outline width","Shadow opacity","Shadow distance","Shadow angle","Shadow blur",
                          "Start","End","Start · fade in","Start · from previous","End · fade out","End · to next",
                          "Click to add to the selected clip's start · or drag onto the timeline",
                          "Click to add to the selected clip's end · or drag onto the timeline",
                          "Untitled","Title","Your story starts here"])
    }

    /// The font menus' headers and the missing font's entry are AppKit titles: looked up before
    /// they are handed over, as the table has them.
    func testTheFontMenusWordsComeFromTheTable() throws {
        _ = NSApplication.shared
        let store = EditorStore()
        store.fontFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-words-fonts-\(UUID().uuidString)")
        var title = Clip(name:"T",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3)); title.style.fontName = "NoSuchFont-Heavy"
        store.edit("Fixture") { $0.clips = [title] }
        store.selectedClipID = title.id
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:300,height:900),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView:InspectorPanel(store:store))
        view.frame = NSRect(x:0,y:0,width:300,height:900)
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        RunLoop.main.run(until:Date().addingTimeInterval(0.2)); view.layoutSubtreeIfNeeded()
        func popUps(_ view: NSView) -> [NSPopUpButton] { ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap(popUps) }
        let family = try XCTUnwrap(popUps(view).first { $0.accessibilityLabel() == String(localized:"Font family") })
        let menu = try XCTUnwrap(family.menu)
        menu.delegate?.menuNeedsUpdate?(menu)
        let headers = menu.items.filter(\.isSectionHeader).map(\.title)
        XCTAssertTrue(headers.contains("System"),"\(headers)")
        let missing = try XCTUnwrap(menu.items.first { $0.representedObject as? String == FontMenu.missingTag }).title
        XCTAssertEqual(missing,"NoSuchFont-Heavy (missing)")
        try assertKorean(headers+[missing.replacingOccurrences(of:"NoSuchFont-Heavy",with:"%@")])
        // In Korean, as AppKit shows them.
        try inKorean {
            store.selectedClipID = nil; view.layoutSubtreeIfNeeded()
            store.selectedClipID = title.id; view.layoutSubtreeIfNeeded()
            let family = try XCTUnwrap(popUps(view).first { $0.accessibilityLabel() == "폰트 패밀리" })
            let menu = try XCTUnwrap(family.menu)
            menu.delegate?.menuNeedsUpdate?(menu)
            XCTAssertTrue(menu.items.filter(\.isSectionHeader).map(\.title).contains("시스템 폰트"))
            XCTAssertEqual(menu.items.first { $0.representedObject as? String == FontMenu.missingTag }?.title,"NoSuchFont-Heavy (없음)")
        }
    }

    /// A title added in the app gets its name and words from the table, not FrameCore's English.
    func testANewTitleReadsInTheAppsLanguage() throws {
        _ = NSApplication.shared
        let store = EditorStore()
        store.addText()
        let title = try XCTUnwrap(store.selectedClip)
        XCTAssertEqual(title.name,String(localized:"Title"))
        XCTAssertEqual(title.style.text,String(localized:"Your story starts here"))
        XCTAssertEqual(store.undoName,"Add text")
        try inKorean {
            store.seek(.init(seconds:3)); store.addText()
            XCTAssertEqual(store.selectedClip?.name,"자막"); XCTAssertEqual(store.selectedClip?.style.text,"이야기는 여기서 시작됩니다")
        }
    }

    /// A media card writes pixel sizes as PROGRAM and the sheets do: 2560 × 1440, not 2,560 × 1,440.
    func testMediaCardsWritePixelSizesPlain() throws {
        _ = NSApplication.shared
        let store = EditorStore()
        let still = MediaReference(name:"wide.png",path:"/nonexistent/ara-tests/wide.png",kind:.image,duration:.init(seconds:5),width:2560,height:1440,frameRate:0,hasAudio:false)
        let movie = MediaReference(name:"tall.mov",path:"/nonexistent/ara-tests/tall.mov",kind:.video,duration:.init(seconds:5),width:2160,height:3840,frameRate:30,hasAudio:false)
        store.edit("Fixture") { $0.media = [still,movie] }
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:400),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView:LibraryPanel(store:store).preferredColorScheme(.dark))
        view.frame = NSRect(x:0,y:0,width:520,height:400)
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        RunLoop.main.run(until:Date().addingTimeInterval(0.2)); view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:rep)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage:try XCTUnwrap(rep.cgImage)).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let read = lines.map { $0.replacingOccurrences(of:"×",with:"x").replacingOccurrences(of:" ",with:"") }
        XCTAssertTrue(read.contains("2560x1440"),"\(lines)")
        XCTAssertTrue(read.contains("2160x3840"),"\(lines)")
    }
}
