import AppKit
import XCTest
import SwiftUI
import FrameCore
@testable import FrameStudio

/// Shortcuts set in Settings: matching key presses, taking a key from another command, and
/// keeping the changes.
@MainActor final class ShortcutSettingsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    override func setUp() async throws {
        suite = "ara.tests.shortcuts.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName:suite)
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName:suite)
    }
    private func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,
                         characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
    }

    func testDefaultsMatchTheMenusKeys() {
        let shortcuts = ShortcutSettings(defaults:defaults)
        XCTAssertEqual(shortcuts.command(matching:key(" ",code:49)),.playPause)
        XCTAssertEqual(shortcuts.command(matching:key("b",code:11,.command)),.split)
        XCTAssertEqual(shortcuts.command(matching:key("\u{F702}",code:123,.option)),.clipStart)
        XCTAssertEqual(shortcuts.command(matching:key("\u{7F}",code:51,.command)),.closeGap)
        XCTAssertEqual(shortcuts.command(matching:key("t",code:17,[.command,.shift])),.addText)
        XCTAssertNil(shortcuts.command(matching:key("b",code:11)),"B alone is not Split")
        XCTAssertEqual(shortcuts.command(matching:key("!",code:18,[.command,.shift])),.startScreen,"⇧1 types ! but is the 1 key")
        XCTAssertEqual(shortcuts.label(.snapshot),"⇧⌘E")
        XCTAssertEqual(shortcuts.label(.playPause),"Space")
        XCTAssertTrue(shortcuts.clashes.isEmpty)
    }

    func testAKoreanInputSourceStillMatchesByKeyPosition() {
        let shortcuts = ShortcutSettings(defaults:defaults)
        // Dubeolsik types ㅜ on the N key and ㅠ on B.
        XCTAssertEqual(shortcuts.command(matching:key("ㅜ",code:45)),.snapping)
        XCTAssertEqual(shortcuts.command(matching:key("ㅠ",code:11,.command)),.split)
    }

    func testANewShortcutIsUsedAndTheOldOneIsFree() {
        let shortcuts = ShortcutSettings(defaults:defaults)
        XCTAssertNil(shortcuts.set(Shortcut("k"),for:.playPause))
        XCTAssertEqual(shortcuts.command(matching:key("k",code:40)),.playPause)
        XCTAssertNil(shortcuts.command(matching:key(" ",code:49)))
        XCTAssertEqual(shortcuts.keyboardShortcut(.playPause)?.key,KeyEquivalent("k"))
        XCTAssertTrue(shortcuts.isChanged(.playPause))
    }

    func testTakingAnotherCommandsKeyLeavesItWithout() {
        let shortcuts = ShortcutSettings(defaults:defaults)
        XCTAssertEqual(shortcuts.set(Shortcut("b",.command),for:.addText),.split)
        XCTAssertEqual(shortcuts.command(matching:key("b",code:11,.command)),.addText)
        XCTAssertNil(shortcuts.shortcut(.split))
        XCTAssertNil(shortcuts.keyboardShortcut(.split))
        XCTAssertTrue(shortcuts.clashes.isEmpty)
        // Bringing Split's default back makes the clash visible rather than silently doubling it.
        shortcuts.reset(.split)
        XCTAssertEqual(shortcuts.clashes,[.split,.addText])
    }

    func testClearingAndResetting() {
        let shortcuts = ShortcutSettings(defaults:defaults)
        shortcuts.set(nil,for:.snapping)
        XCTAssertNil(shortcuts.command(matching:key("n",code:45)))
        XCTAssertEqual(shortcuts.label(.snapping),"")
        shortcuts.reset(.snapping)
        XCTAssertEqual(shortcuts.command(matching:key("n",code:45)),.snapping)
        shortcuts.set(Shortcut("j"),for:.previousFrame); shortcuts.set(Shortcut("l"),for:.nextFrame)
        shortcuts.resetAll()
        XCTAssertTrue(shortcuts.changes.isEmpty)
        XCTAssertNil(defaults.data(forKey:ShortcutSettings.storageKey))
        XCTAssertEqual(shortcuts.label(.previousFrame),"←")
    }

    func testChangesAreKept() {
        let first = ShortcutSettings(defaults:defaults)
        first.set(Shortcut("d",[.command,.option]),for:.split)
        first.set(nil,for:.snapping)
        let again = ShortcutSettings(defaults:defaults)
        XCTAssertEqual(again.shortcut(.split),Shortcut("d",[.command,.option]))
        XCTAssertNil(again.shortcut(.snapping))
        XCTAssertEqual(again.shortcut(.playPause),Shortcut("space"))
        XCTAssertEqual(again.label(.split),"⌥⌘D")
    }

    func testRecordedKeysIgnoreCapsLockAndFunctionFlags() {
        let pressed = Shortcut(event:key("S",code:1,[.command,.shift,.capsLock]))
        XCTAssertEqual(pressed,Shortcut("s",[.command,.shift]))
        let arrow = Shortcut(event:key("\u{F703}",code:124,[.option,.function,.numericPad]))
        XCTAssertEqual(arrow,Shortcut("right",.option))
        XCTAssertTrue(Shortcut("q",.command).isReserved)
        XCTAssertTrue(Shortcut("c",.command).isReserved)
        XCTAssertFalse(Shortcut("c",[.command,.shift]).isReserved)
    }

    func testTheLanguageSettingIsThisAppsOwn() {
        XCTAssertEqual(AppLanguage.current(in:defaults,domain:suite),.system)
        AppLanguage.korean.apply(to:defaults)
        XCTAssertEqual(defaults.stringArray(forKey:"AppleLanguages"),["ko"])
        XCTAssertEqual(AppLanguage.current(in:defaults,domain:suite),.korean)
        AppLanguage.system.apply(to:defaults)
        XCTAssertEqual(AppLanguage.current(in:defaults,domain:suite),.system)
    }

    func testEveryCommandHasItsOwnDefault() {
        let defaults = AppCommand.allCases.compactMap(\.standard)
        XCTAssertEqual(Set(defaults).count,defaults.count)
        XCTAssertFalse(defaults.contains(where:\.isReserved))
    }
}

/// A speed typed into the inspector or the toolbar's Custom… field.
@MainActor final class CustomSpeedTests: XCTestCase {
    func testTypedSpeeds() {
        XCTAssertEqual(EditorStore.parseSpeed("2.5"),2.5)
        XCTAssertEqual(EditorStore.parseSpeed(" 2.5x "),2.5)
        XCTAssertEqual(EditorStore.parseSpeed("5X"),5)
        XCTAssertEqual(EditorStore.parseSpeed("1,75"),1.75)
        XCTAssertEqual(EditorStore.parseSpeed("250%"),2.5)
        XCTAssertEqual(EditorStore.parseSpeed("10"),10)
        XCTAssertEqual(EditorStore.parseSpeed("0.1"),0.1)
        XCTAssertEqual(EditorStore.parseSpeed("1.234"),1.23,"two decimals, as shown")
        for bad in ["","x","abc","0","0.05","11","-2","nan","inf","1e400"] { XCTAssertNil(EditorStore.parseSpeed(bad),bad) }
        XCTAssertTrue(EditorStore.speedPresets.contains(5))
        XCTAssertTrue(EditorStore.speedPresets.allSatisfy(Clip.speedRange.contains))
    }
}

/// Each kind of trackpad haptic can be turned off in Settings, under the overall switch.
@MainActor final class HapticSettingsTests: XCTestCase {
    func testKindsTurnOffOneByOneAndAllTogether() {
        let store = EditorStore()
        let saved = (store.scrubHaptics,store.hapticsOff)
        defer { store.scrubHaptics = saved.0; store.hapticsOff = saved.1 }
        store.scrubHaptics = true; store.hapticsOff = []
        XCTAssertTrue(HapticKind.allCases.allSatisfy(store.haptics))
        store.hapticsOff = [.skimming]
        XCTAssertFalse(store.haptics(.skimming))
        XCTAssertTrue(store.haptics(.snapping))
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey:"haptics.off"),["skimming"])
        store.hapticsOff = []; store.scrubHaptics = false
        XCTAssertFalse(HapticKind.allCases.contains(where:store.haptics))
    }
}
