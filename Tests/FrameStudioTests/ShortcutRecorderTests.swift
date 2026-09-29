import AppKit
import XCTest
import SwiftUI
@testable import FrameStudio

/// A hidden window: real responder methods, without taking the user's input focus.
@MainActor private final class RecorderTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// Recording a shortcut in Settings: which keys it takes, which it refuses and why, that it only
/// listens to the Settings window, and what the rows say and do.
@MainActor final class ShortcutRecorderTests: XCTestCase {
    private var suite = ""
    private var shortcuts: ShortcutSettings!
    private var windows: [NSWindow] = []
    override func setUp() async throws {
        _ = NSApplication.shared
        suite = "ara.tests.recorder.\(UUID().uuidString)"
        shortcuts = ShortcutSettings(defaults:UserDefaults(suiteName:suite)!)
    }
    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
    }
    private func window(_ size: CGSize = CGSize(width:200,height:100)) -> NSWindow {
        let window = RecorderTestWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; windows.append(window)
        return window
    }
    /// A recorder listening to its own Settings window, recording `command`.
    private func recording(_ command: AppCommand) -> (ShortcutRecorder,NSWindow) {
        let recorder = ShortcutRecorder(shortcuts:shortcuts), settings = window()
        recorder.window = settings
        recorder.start(command)
        addTeardownBlock { recorder.stop() }
        return (recorder,settings)
    }
    private func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,
                         context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
    }

    func testTheNextKeyBecomesTheShortcut() {
        let (recorder,settings) = recording(.newProject)
        XCTAssertNil(recorder.record(key("k",code:40,.command,in:settings)),"taken, not typed")
        XCTAssertEqual(shortcuts.label(.newProject),"⌘K")
        XCTAssertNil(recorder.recording); XCTAssertNil(recorder.note)
        recorder.start(.addText)
        _ = recorder.record(key("b",code:11,.command,in:settings))
        XCTAssertEqual(recorder.note,"⌘B moved here from “Split at Playhead”, which now has none.")
        XCTAssertEqual(shortcuts.label(.split),"")
    }

    /// Shift-arrows, Return or Enter, and Esc with a modifier keep their jobs in the timeline and
    /// preview; the recorder says so and keeps waiting.
    func testKeysTheTimelineKeepsAreRefused() {
        let (recorder,settings) = recording(.clipStart)
        let kept = [key("\u{F702}",code:123,[.shift,.function,.numericPad],in:settings),key("\u{F703}",code:124,[.shift,.function,.numericPad],in:settings),
                    key("\r",code:36,in:settings),key("\u{3}",code:76,[.numericPad],in:settings),
                    key("\u{1B}",code:53,.shift,in:settings),key("\u{1B}",code:53,.option,in:settings)]
        for event in kept {
            XCTAssertNil(recorder.record(event))
            XCTAssertEqual(recorder.recording,.clipStart,"still waiting after \(event.keyCode)")
            XCTAssertTrue(recorder.note?.hasSuffix("is kept for the timeline and preview. Choose another.") == true,recorder.note ?? "no note")
        }
        XCTAssertEqual(shortcuts.label(.clipStart),"⌥←")
        XCTAssertTrue(shortcuts.changes.isEmpty)
        // With ⌘, Return is free.
        _ = recorder.record(key("\r",code:36,.command,in:settings))
        XCTAssertEqual(shortcuts.label(.clipStart),"⌘↩")
    }

    /// macOS's own menu keys are refused with the reason; a key Ara can't name is explained rather
    /// than swallowed; Esc alone stops recording.
    func testMacKeysAndUnknownKeysAreExplained() {
        let (recorder,settings) = recording(.addText)
        let mac: [(String,UInt16,NSEvent.ModifierFlags)] = [("f",3,[.command,.control]),("w",13,[.command,.option]),("m",46,[.command,.option]),
            ("/",44,[.command,.shift]),("v",9,[.command,.option,.shift]),(" ",49,[.command,.control]),("`",50,.command),("\t",48,.command),(" ",49,.command),("\t",48,[])]
        for (characters,code,flags) in mac {
            XCTAssertNil(recorder.record(key(characters,code:code,flags,in:settings)))
            XCTAssertTrue(recorder.note?.hasSuffix("is kept for macOS or copy and paste. Choose another.") == true,"\(characters) \(flags): \(recorder.note ?? "no note")")
        }
        XCTAssertNil(recorder.record(key("\u{F708}",code:96,[.function],in:settings)),"F5")
        XCTAssertEqual(recorder.note,"This key can't be used for a shortcut. Choose another.")
        XCTAssertEqual(recorder.recording,.addText)
        XCTAssertTrue(shortcuts.changes.isEmpty)
        XCTAssertNil(recorder.record(key("\u{1B}",code:53,in:settings)))
        XCTAssertNil(recorder.recording)
        XCTAssertEqual(shortcuts.label(.addText),"⇧⌘T")
    }

    /// Recording listens to the Settings window only, and stops once that window is left or
    /// closed: a key typed in the editor is never taken for a shortcut.
    func testRecordingStopsOnLeavingTheSettingsWindow() {
        let (recorder,settings) = recording(.newProject)
        let editor = window()
        // Through the app's own event path, which calls the recorder's monitor.
        NSApp.sendEvent(key(" ",code:49,in:editor))
        XCTAssertEqual(recorder.recording,.newProject,"a key for the editor is not the recorder's")
        XCTAssertEqual(shortcuts.label(.playPause),"Space"); XCTAssertEqual(shortcuts.label(.newProject),"⌘N")
        XCTAssertNotNil(recorder.record(key(" ",code:49,in:editor)),"passed on")
        NSApp.sendEvent(key("j",code:38,.command,in:settings))
        XCTAssertEqual(shortcuts.label(.newProject),"⌘J","one for the Settings window is")
        // Clicking another window ends recording; so does closing Settings.
        recorder.start(.newProject)
        NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:settings)
        XCTAssertNil(recorder.recording)
        NSApp.sendEvent(key("u",code:32,.command,in:settings))
        XCTAssertEqual(shortcuts.label(.newProject),"⌘J","its monitor is gone")
        recorder.start(.newProject)
        NotificationCenter.default.post(name:NSWindow.willCloseNotification,object:settings)
        XCTAssertNil(recorder.recording)
        // Another window resigning changes nothing; the tab leaving its window does.
        recorder.start(.newProject)
        NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:editor)
        XCTAssertEqual(recorder.recording,.newProject)
        recorder.window = nil
        XCTAssertNil(recorder.recording)
        recorder.start(.newProject)
        XCTAssertNil(recorder.recording,"no window, no recording")
    }

    /// What a row shows and says: the key, the wait for one, none, or a clash with the command it
    /// shares its key with.
    func testRowsSayWhatTheyShow() throws {
        UserDefaults(suiteName:suite)!.set(try JSONEncoder().encode(["addText":Shortcut("b",.command)] as [String:Shortcut?]),forKey:ShortcutSettings.storageKey)
        shortcuts = ShortcutSettings(defaults:UserDefaults(suiteName:suite)!)
        let (recorder,_) = recording(.newProject)
        XCTAssertEqual(recorder.shown(.newProject),"Type a shortcut…")
        XCTAssertEqual(recorder.spoken(.newProject),"Type a shortcut…")
        XCTAssertEqual(recorder.spoken(.undo),"⌘Z")
        shortcuts.set(nil,for:.snapping)
        XCTAssertEqual(recorder.shown(.snapping),"None"); XCTAssertEqual(recorder.spoken(.snapping),"None")
        XCTAssertEqual(recorder.spoken(.split),"⌘B · Also set for “Add Text Clip”")
        XCTAssertEqual(recorder.spoken(.addText),"⌘B · Also set for “Split at Playhead”")
        // Restore default on the clashing row says where the key came from, as recording does.
        recorder.restore(.split)
        XCTAssertEqual(recorder.note,"⌘B moved here from “Add Text Clip”, which now has none.")
        XCTAssertEqual(recorder.spoken(.split),"⌘B")
        recorder.restore(.snapping)
        XCTAssertNil(recorder.note)
    }

    /// The Shortcuts tab itself: on a clash kept from an earlier Ara, Restore default is on for
    /// both rows and settles it from either.
    func testRestoreDefaultOnAClashingRowSettlesIt() async throws {
        UserDefaults(suiteName:suite)!.set(try JSONEncoder().encode(["addText":Shortcut("b",.command)] as [String:Shortcut?]),forKey:ShortcutSettings.storageKey)
        shortcuts = ShortcutSettings(defaults:UserDefaults(suiteName:suite)!)
        let settings = window(CGSize(width:560,height:1400))
        let host = NSHostingView(rootView:ShortcutSettingsView(shortcuts:shortcuts).frame(width:560,height:1400))
        host.frame = settings.contentLayoutRect; settings.contentView = host
        /// Each row's ✕ and ↺, in the rows' order (the commands' own).
        func rows() async throws -> [(remove: NSButton, restore: NSButton)] {
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(20)) }
            func buttons(_ view: NSView) -> [NSButton] { ((view as? NSButton).map { [$0] } ?? [])+view.subviews.flatMap(buttons) }
            let found = buttons(host)
            return stride(from:0,to:found.count-1,by:2).map { (found[$0],found[$0+1]) }
        }
        var found = try await rows()
        XCTAssertEqual(found.count,AppCommand.allCases.count)
        let split = try XCTUnwrap(AppCommand.allCases.firstIndex(of:.split)), addText = try XCTUnwrap(AppCommand.allCases.firstIndex(of:.addText))
        let undo = try XCTUnwrap(AppCommand.allCases.firstIndex(of:.undo))
        XCTAssertTrue(found[split].restore.isEnabled,"Split still has its default, but shares it")
        XCTAssertTrue(found[addText].restore.isEnabled)
        XCTAssertFalse(found[undo].restore.isEnabled)
        found[split].restore.performClick(nil)
        found = try await rows()
        XCTAssertTrue(shortcuts.clashes.isEmpty)
        XCTAssertEqual(shortcuts.label(.split),"⌘B"); XCTAssertEqual(shortcuts.label(.addText),"")
        XCTAssertFalse(found[split].restore.isEnabled); XCTAssertFalse(found[addText].remove.isEnabled)
        XCTAssertTrue(found[addText].restore.isEnabled,"Add Text Clip can take ⇧⌘T back")
    }

    /// Every new or changed word, in Korean in the table's formal style, with the same format
    /// specifiers.
    func testTheWordsHaveKoreanEntries() throws {
        let strings = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ko.lproj/Localizable.strings")
        let korean = try XCTUnwrap(NSDictionary(contentsOf:strings) as? [String:String])
        let entries = ["This key can't be used for a shortcut. Choose another.":"",
                       "%@ is kept for the timeline and preview. Choose another.":"%@",
                       "Also set for “%@”":"%@","Remove shortcut for %@":"%@","Restore default for %@":"%@",
                       "When a clip's alignment point lines up with the centre or another clip's in the preview, or catches the centre, a corner or an edge as you place it.":""]
        for (key,specifiers) in entries {
            let value = try XCTUnwrap(korean[key],"no Korean for “\(key)”")
            XCTAssertEqual(value.components(separatedBy:"%@").count-1,specifiers.isEmpty ? 0 : 1,key)
        }
        // The alignment haptic follows the alignment point, and says so.
        let alignment = Mirror(reflecting:HapticKind.alignment.detail).children.first { $0.label == "key" }?.value as? String
        XCTAssertTrue(alignment?.contains("alignment point") == true,alignment ?? "no key")
        XCTAssertTrue(alignment.flatMap { korean[$0] }?.contains("정렬점") == true)
        // "System default" reads as the Mac's language, not as the System Settings app.
        XCTAssertEqual(korean["System default"],"시스템 언어")
        XCTAssertTrue(korean["“System default” follows the language set for your Mac."]!.hasPrefix("“시스템 언어”"))
        XCTAssertNil(korean.values.first { $0.contains("시스템 설정") && !$0.contains("시스템 설정에서") && !$0.contains("시스템 설정 →") },"the System Settings app only where it is meant")
        // Sentences end in the formal style.
        for key in ["FHD preview media unavailable for %@ · Previewing the original",
                    "This project uses fonts that aren't on this Mac: %@. Titles in them are shown in Helvetica Neue Bold until you add the fonts (Add Font… in a title's inspector)."] {
            let value = try XCTUnwrap(korean[key])
            XCTAssertFalse(value.contains("했어") || value.contains("였어") || value.contains("보여 "),value)
        }
    }
}
