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
        // Bringing Split's default back takes ⌘B back, as recording it would: two commands never
        // keep one key.
        XCTAssertEqual(shortcuts.reset(.split),.addText)
        XCTAssertEqual(shortcuts.label(.split),"⌘B")
        XCTAssertNil(shortcuts.shortcut(.addText))
        XCTAssertTrue(shortcuts.clashes.isEmpty)
        XCTAssertEqual(shortcuts.command(matching:key("b",code:11,.command)),.split)
        XCTAssertNil(shortcuts.reset(.addText),"⇧⌘T was free")
        XCTAssertTrue(shortcuts.changes.isEmpty)
    }

    /// A clash kept by an earlier Ara (both on ⌘B): each row shows the other, and Restore default
    /// on either row settles it.
    func testRestoreDefaultSettlesAClashKeptFromBefore() throws {
        defaults.set(try JSONEncoder().encode(["addText":Shortcut("b",.command)] as [String:Shortcut?]),forKey:ShortcutSettings.storageKey)
        var shortcuts = ShortcutSettings(defaults:defaults)
        XCTAssertEqual(shortcuts.clashes,[.split,.addText])
        XCTAssertEqual(shortcuts.sharing(.split),.addText); XCTAssertEqual(shortcuts.sharing(.addText),.split)
        XCTAssertNil(shortcuts.sharing(.undo))
        // On the row whose default it is: the key comes back from the other command.
        XCTAssertEqual(shortcuts.reset(.split),.addText)
        XCTAssertTrue(shortcuts.clashes.isEmpty)
        XCTAssertEqual(shortcuts.label(.split),"⌘B"); XCTAssertEqual(shortcuts.label(.addText),"")
        XCTAssertTrue(ShortcutSettings(defaults:defaults).clashes.isEmpty,"settled for good")
        // On the other row: it takes its own default back and leaves ⌘B to Split.
        defaults.set(try JSONEncoder().encode(["addText":Shortcut("b",.command)] as [String:Shortcut?]),forKey:ShortcutSettings.storageKey)
        shortcuts = ShortcutSettings(defaults:defaults)
        XCTAssertNil(shortcuts.reset(.addText))
        XCTAssertTrue(shortcuts.clashes.isEmpty)
        XCTAssertEqual(shortcuts.label(.split),"⌘B"); XCTAssertEqual(shortcuts.label(.addText),"⇧⌘T")
    }

    /// Return, ⇧→ or ⇧Esc saved for a command by an earlier Ara (whose recorder took them) are not
    /// used: they would take the fixed keys over from the menus. The command gets its default back,
    /// or none when another command has that key now; other changes stay.
    func testFixedKeysSavedByAnEarlierAraAreNotUsed() throws {
        let stored: [String:Shortcut?] = ["addText":Shortcut("return"),"nextFrame":Shortcut("right",.shift),"delete":Shortcut("escape",.shift),
                                          "clipEnd":Shortcut("c",.command),"snapping":Shortcut("k")]
        defaults.set(try JSONEncoder().encode(stored),forKey:ShortcutSettings.storageKey)
        var shortcuts = ShortcutSettings(defaults:defaults)
        XCTAssertEqual(shortcuts.label(.addText),"⇧⌘T"); XCTAssertEqual(shortcuts.label(.nextFrame),"→")
        XCTAssertEqual(shortcuts.label(.delete),"⌫"); XCTAssertEqual(shortcuts.label(.clipEnd),"⌥→")
        XCTAssertEqual(shortcuts.label(.snapping),"K")
        XCTAssertNil(shortcuts.command(matching:key("\r",code:36)))
        XCTAssertTrue(shortcuts.clashes.isEmpty)
        defaults.set(try JSONEncoder().encode(["addText":Shortcut("return"),"split":Shortcut("t",[.command,.shift])] as [String:Shortcut?]),forKey:ShortcutSettings.storageKey)
        shortcuts = ShortcutSettings(defaults:defaults)
        XCTAssertNil(shortcuts.shortcut(.addText)); XCTAssertEqual(shortcuts.label(.split),"⇧⌘T")
        XCTAssertTrue(shortcuts.clashes.isEmpty)
    }

    /// Recording the key a command has by default is no change, so Restore Defaults stays off.
    func testAKeysOwnDefaultIsNoChange() throws {
        let shortcuts = ShortcutSettings(defaults:defaults)
        XCTAssertNil(shortcuts.set(Shortcut("b",.command),for:.split))
        XCTAssertTrue(shortcuts.changes.isEmpty)
        XCTAssertNil(defaults.data(forKey:ShortcutSettings.storageKey))
        // Nor is one saved that way by an earlier Ara.
        defaults.set(try JSONEncoder().encode(["split":Shortcut("b",.command)] as [String:Shortcut?]),forKey:ShortcutSettings.storageKey)
        XCTAssertTrue(ShortcutSettings(defaults:defaults).changes.isEmpty)
    }

    /// Keys macOS keeps (standard menu items, Spotlight, the app switcher, focus moves) and those
    /// the timeline and preview keep whatever the settings say.
    func testKeptKeys() {
        let mac = [Shortcut("f",[.command,.control]),Shortcut("w",[.command,.option]),Shortcut("m",[.command,.option]),Shortcut("/",[.command,.shift]),
                   Shortcut("v",[.command,.option,.shift]),Shortcut("space",[.command,.control]),Shortcut("`",.command),Shortcut("tab",.command),
                   Shortcut("space",.command),Shortcut("tab"),Shortcut("tab",.shift),Shortcut("q",.command),Shortcut("h",[.command,.option])]
        for shortcut in mac { XCTAssertTrue(shortcut.isReserved,shortcut.display) }
        let fixed = [Shortcut("left",.shift),Shortcut("right",.shift),Shortcut("return"),Shortcut("escape"),Shortcut("escape",.shift),
                     Shortcut("escape",.option),Shortcut("escape",[.command,.control])]
        for shortcut in fixed { XCTAssertTrue(shortcut.isFixed,shortcut.display) }
        for free in [Shortcut("return",.command),Shortcut("left",.option),Shortcut("left",[.shift,.command]),Shortcut("n"),Shortcut("f",.command),Shortcut("tab",.option)] {
            XCTAssertFalse(free.isReserved || free.isFixed,free.display)
        }
        // Quit, Close, Settings and the like are the app's own; copy and paste are not.
        XCTAssertTrue(Shortcut("w",.command).isAppKey); XCTAssertTrue(Shortcut(",",.command).isAppKey)
        XCTAssertFalse(Shortcut("v",.command).isAppKey); XCTAssertFalse(Shortcut("z",.command).isAppKey)
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

    /// The restart note and Restart Now follow what the choice shows at the next launch, System
    /// default included: set to English on a Korean Mac, going back to it shows Korean.
    func testSystemDefaultAsksForARestartWhenItChangesTheLanguage() {
        AppLanguage.english.apply(to:defaults)
        AppLanguage.system.apply(to:defaults)                         // what the picker does
        XCTAssertEqual(AppLanguage.current(in:defaults,domain:suite),.system)
        XCTAssertEqual(AppLanguage.system.resolved(macLanguages:["ko-KR"]),"ko")
        XCTAssertTrue(AppLanguage.system.needsRestart(running:"en",macLanguages:["ko-KR"]))
        XCTAssertFalse(AppLanguage.system.needsRestart(running:"ko",macLanguages:["ko-KR"]))
        XCTAssertTrue(AppLanguage.system.needsRestart(running:"ko",macLanguages:["en-US","ko-KR"]))
        // The first of the Mac's languages Ara has; English when it has none of them.
        XCTAssertEqual(AppLanguage.system.resolved(macLanguages:["ja-JP","ko-KR"]),"ko")
        XCTAssertEqual(AppLanguage.system.resolved(macLanguages:["ja-JP"]),"en")
        XCTAssertFalse(AppLanguage.system.needsRestart(running:"en",macLanguages:["ja-JP"]))
        // A language chosen outright, whatever the Mac's.
        XCTAssertTrue(AppLanguage.korean.needsRestart(running:"en",macLanguages:["ko-KR"]))
        XCTAssertFalse(AppLanguage.english.needsRestart(running:"en",macLanguages:["ko-KR"]))
    }

    func testEveryCommandHasItsOwnDefault() {
        let defaults = AppCommand.allCases.compactMap(\.standard)
        XCTAssertEqual(Set(defaults).count,defaults.count)
        XCTAssertFalse(defaults.contains(where:\.isReserved))
        XCTAssertFalse(defaults.contains(where:\.isFixed))
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
