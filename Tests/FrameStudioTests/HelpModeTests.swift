import AppKit
import XCTest
import SwiftUI
import Combine
import FrameCore
@testable import FrameStudio

/// A hidden window: real responder methods, without taking the user's input focus.
@MainActor private final class HelpTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
/// Help mode shown or not, as the store holds it.
@MainActor private final class Shown: ObservableObject { @Published var value = true }
private struct Overlaid: View {
    @ObservedObject var shown: Shown
    var body: some View { Color.clear.overlay { if shown.value { HelpOverlay(isShown:$shown.value) } } }
}

/// Help mode over the whole editor: every note readable and clear of the others, controls out of
/// view left unnamed, and no key but Esc acting while the tips are read.
@MainActor final class HelpModeTests: XCTestCase {
    private static let keys = ["timeline.snapping","timeline.scrubHaptics","haptics.off","haptics.skimStrength","editor.columnFractions.v1","editor.rowFractions.v1","timeline.foldedSound"]
    private var windows: [NSWindow] = []
    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
    }
    private func window(_ size: CGSize) -> NSWindow {
        let window = HelpTestWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; windows.append(window)
        return window
    }
    private func settle(_ view: NSView, _ steps: Int = 30) async throws {
        for _ in 0..<steps { view.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(25)) }
    }
    /// The editor at `size` with a title selected, help shown, the app's settings put back afterwards.
    private func withHelp(_ size: CGSize, tracks: Bool = false, _ check: @MainActor (EditorStore, NSView) async throws -> Void) async throws {
        _ = NSApplication.shared
        let saved = Self.keys.reduce(into:[String:Any]()) { values, key in values[key] = UserDefaults.standard.object(forKey:key) }
        let suite = "ara.tests.help-mode.\(UUID().uuidString)"
        let store = EditorStore(registry:ProjectRegistry(defaults:UserDefaults(suiteName:suite)!))
        store.pasteboard = NSPasteboard(name:.init("ara-help-mode-\(UUID().uuidString)"))
        store.runAlert = { alert in XCTFail("Unexpected question: \(alert.messageText)"); return .alertSecondButtonReturn }
        defer {
            store.pause(); store.pasteboard.releaseGlobally()
            UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
            for key in Self.keys { if let value = saved[key] { UserDefaults.standard.set(value,forKey:key) } else { UserDefaults.standard.removeObject(forKey:key) } }
        }
        // The panes at their default sizes, as on a first launch.
        for key in Self.keys where key.hasPrefix("editor.") { UserDefaults.standard.removeObject(forKey:key) }
        var title = Clip(name:"Title",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:4)); title.style.text = "Hello"
        XCTAssertTrue(store.edit("Fixture") { project in
            project.clips = [title]
            if tracks { for n in 3...8 { try? project.ensureLane(Lane(.video,n)); try? project.ensureLane(Lane(.audio,n)) } }
        })
        store.resumeEditing(); store.selectedClipID = title.id
        let host = NSHostingView(rootView:EditorView(store:store).frame(width:size.width,height:size.height))
        host.frame = NSRect(origin:.zero,size:size)
        window(size).contentView = host
        try await settle(host)
        for _ in 0..<1500 where store.isBuilding { try await Task.sleep(for:.milliseconds(10)) }
        if tracks, let scroll = find(NSScrollView.self,in:host,where: { $0.documentView is TimelineCanvas }) {
            scroll.contentView.scroll(to:NSPoint(x:0,y:(scroll.documentView!.frame.height-scroll.contentView.bounds.height)/2))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        store.showHelp = true
        try await settle(host)
        let probe = try XCTUnwrap(find(NSView.self,in:host,where: { String(describing:type(of:$0)) == "Probe" }),"the overlay's probe")
        try await check(store,probe)
        store.showHelp = false
        try await settle(host,4)
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView, where test: (T) -> Bool = { _ in true }) -> T? {
        if let hit = view as? T, test(hit) { return hit }
        for sub in view.subviews { if let hit = find(type,in:sub,where:test) { return hit } }
        return nil
    }
    /// The tips as the Korean interface words them: each through the table, a shortcut kept.
    private func korean(_ tips: [HelpTips.Tip]) throws -> [HelpTips.Tip] {
        let strings = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ko.lproj/Localizable.strings")
        let table = try XCTUnwrap(NSDictionary(contentsOf:strings) as? [String:String])
        return try tips.map { tip in
            let parts = tip.text.components(separatedBy:"  ")
            let text = try XCTUnwrap(table[parts[0]],"no Korean for “\(parts[0])”")
            return HelpTips.Tip(id:tip.id,text:([text]+parts.dropFirst()).joined(separator:"  "),target:tip.target,placement:tip.placement)
        }
    }
    /// Bubbles clear of each other, of other controls and of lines; lines clear of other
    /// controls; every note whole in its bubble.
    private func assertReadable(_ tips: [HelpTips.Tip], in size: CGSize, _ name: String) {
        let placed = HelpTips.layout(tips,in:size)
        XCTAssertEqual(placed.count,tips.count)
        XCTAssertEqual(HelpTipsLayoutTests.faults(placed,in:size),[],name)
        for item in placed {
            if let line = item.pointer {
                for other in tips where other.id != item.tip.id && other.placement != .inside {
                    XCTAssertFalse(other.target.insetBy(dx:-2,dy:-2).intersects(line),"\(name): line of \(item.tip.text) crosses \(other.text)")
                }
            }
            let width = item.bubble.width-2*HelpTips.padding
            XCTAssertLessThanOrEqual(HelpTipsLayoutTests.linesDrawn(item.tip.text,width:width),HelpTips.lines(item.tip),"\(name): \(item.tip.text)")
            XCTAssertLessThanOrEqual(HelpTipsLayoutTests.textHeight(item.tip.text,width:width),item.bubble.height,"\(name): \(item.tip.text)")
        }
    }

    func testEveryNoteIsReadableAtTheSmallestAndTheDefaultWindow() async throws {
        for size in [CGSize(width:1060,height:760),CGSize(width:1440,height:920)] {
            try await withHelp(size) { _, probe in
                let tips = HelpTips.tips(in:probe)
                XCTAssertGreaterThanOrEqual(tips.count,25)
                XCTAssertTrue(tips.contains { $0.text == "Drag media onto the timeline, or double-click to add it at the end" })
                assertReadable(tips,in:probe.bounds.size,"\(size) English")
                assertReadable(try korean(tips),in:probe.bounds.size,"\(size) Korean")
            }
        }
    }

    /// With more tracks than fit, scrolled half way: the track buttons out of view get no tip
    /// (it would point at the panels above), and the rest still read clearly.
    func testTrackButtonsScrolledOutOfViewAreNotNamed() async throws {
        try await withHelp(CGSize(width:1060,height:760),tracks:true) { store, probe in
            XCTAssertEqual(store.project.videoTrackCount,8)
            let tips = HelpTips.tips(in:probe)
            XCTAssertFalse(tips.contains { $0.text.hasPrefix("Add a video track") || $0.text.hasPrefix("Add an audio track") },"\(tips.map(\.text))")
            assertReadable(tips,in:probe.bounds.size,"scrolled tracks")
        }
    }

    /// While help is shown, keys typed in its window do nothing but Esc, which closes it; the
    /// app's own keys (Quit, Close, Settings, …) and keys for other windows go on. Once help is
    /// closed, keys work again.
    func testKeysDoNothingWhileHelpIsShown() async throws {
        _ = NSApplication.shared
        let shown = Shown(), editor = window(CGSize(width:600,height:400)), other = window(CGSize(width:100,height:100))
        let host = NSHostingView(rootView:Overlaid(shown:shown).frame(width:600,height:400))
        host.frame = NSRect(x:0,y:0,width:600,height:400); editor.contentView = host
        try await settle(host,10)
        func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow? = nil) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:(window ?? editor).windowNumber,
                             context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
        }
        let guardView = try XCTUnwrap(find(HelpKeys.Guard.self,in:host))
        for (characters,code,flags) in [("n",UInt16(45),NSEvent.ModifierFlags()),("\u{7F}",51,[]),(" ",49,[]),("a",0,[]),("z",6,.command),("b",11,.command),("v",9,.command),("t",17,[.command,.shift])] {
            XCTAssertNil(guardView.handle(key(characters,code,flags)),"\(characters) \(flags) does nothing")
        }
        for (characters,code,flags) in [("q",UInt16(12),NSEvent.ModifierFlags.command),("w",13,.command),(",",43,.command),("h",4,.command),("m",46,.command)] {
            XCTAssertNotNil(guardView.handle(key(characters,code,flags)),"\(characters) is the app's")
        }
        XCTAssertNotNil(guardView.handle(key("n",45,in:other)),"another window's keys go on")
        XCTAssertTrue(shown.value)
        // Esc through the app's own event path, which calls the guard's monitor: help closes.
        NSApp.sendEvent(key("\u{1B}",53))
        XCTAssertFalse(shown.value)
        try await settle(host,6)
        XCTAssertNil(find(HelpKeys.Guard.self,in:host),"the guard leaves with the overlay")
        shown.value = true
        try await settle(host,6)
        NSApp.sendEvent(key("\u{1B}",53,in:other))
        XCTAssertTrue(shown.value,"Esc in another window leaves it")
        shown.value = false
        try await settle(host,6)
        // Nothing listens once help is closed.
        var closedAgain = false
        let watch = shown.$value.dropFirst().sink { _ in closedAgain = true }
        NSApp.sendEvent(key("\u{1B}",53))
        watch.cancel()
        XCTAssertFalse(closedAgain)
    }
}
