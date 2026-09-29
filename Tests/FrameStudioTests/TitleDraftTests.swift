import AppKit
import SwiftUI
import XCTest
import FrameCore
@testable import FrameStudio

@MainActor private final class DraftTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// A title's TEXT field commits a short moment after the last key. ⌘Z or Reset appearance within
/// that moment must leave the field and the title agreeing, and must not lose or revive typing.
final class TitleDraftTests: XCTestCase {
    private let caret = NSRange(location:NSNotFound,length:0)
    @MainActor private func spin(_ milliseconds: Int) async throws { try await Task.sleep(for:.milliseconds(milliseconds)) }
    /// A title reading "Base", selected, with its inspector in an offscreen window and the caret at
    /// the end of its focused TEXT field.
    @MainActor private func typing() async throws -> (EditorStore, NSWindow, NSTextView) {
        _ = NSApplication.shared
        let store = EditorStore()
        var title = Clip(name:"T",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3)); title.style.text = "Base"
        store.edit("Fixture") { $0.clips = [title] }
        store.selectedClipID = title.id
        for _ in 0..<1000 where store.isBuilding || store.player.currentItem == nil { try await spin(10) }
        let window = DraftTestWindow(contentRect:NSRect(x:0,y:0,width:300,height:1400),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView:InspectorPanel(store:store))
        view.frame = NSRect(x:0,y:0,width:300,height:1400)
        window.contentView = view
        try await spin(120); view.layoutSubtreeIfNeeded()
        var fields: [NSTextView] = []
        func collect(_ view: NSView) { if let text = view as? NSTextView, text.isEditable { fields.append(text) }; view.subviews.forEach(collect) }
        collect(view)
        let field = try XCTUnwrap(fields.first,"the title's text field")
        XCTAssertEqual(field.string,"Base")
        XCTAssertTrue(window.makeFirstResponder(field)); try await spin(60)
        field.setSelectedRange(NSRange(location:4,length:0))
        return (store,window,field)
    }
    @MainActor private func text(_ store: EditorStore) -> String? { store.project.clips.first?.style.text }

    /// ⌘Z 40 ms after the last key: the typing lands and is undone in one call, so the title's text
    /// ends where it was last drawn. The field still follows it.
    @MainActor func testUndoRightAfterTypingPutsTheFieldBackToo() async throws {
        let (store,window,field) = try await typing()
        defer { window.contentView = nil; window.close() }
        field.insertText("QQ",replacementRange:caret)
        try await spin(40)
        store.undo()
        try await spin(300)
        XCTAssertEqual(text(store),"Base"); XCTAssertEqual(field.string,"Base","the field follows the undo")
        store.redo(); try await spin(300)
        XCTAssertEqual(text(store),"BaseQQ"); XCTAssertEqual(field.string,"BaseQQ")
        store.undo(); try await spin(300)
        XCTAssertEqual(field.string,"Base")
        // Typing on: the undone letters do not come back with the next key.
        field.setSelectedRange(NSRange(location:4,length:0))
        field.insertText("R",replacementRange:caret)
        try await spin(400)
        XCTAssertEqual(text(store),"BaseR"); XCTAssertEqual(field.string,"BaseR")
    }

    /// Reset appearance 60 ms after the last key keeps what was typed, in the title and the field.
    @MainActor func testResetAppearanceRightAfterTypingKeepsTheText() async throws {
        let (store,window,field) = try await typing()
        defer { window.contentView = nil; window.close() }
        field.insertText("YZ",replacementRange:caret)
        try await spin(60)
        store.updateStyle { style in let text = style.text; style = ClipStyle(); style.text = text }     // the button's action
        try await spin(300)
        XCTAssertEqual(text(store),"BaseYZ"); XCTAssertEqual(field.string,"BaseYZ")
        window.makeFirstResponder(nil); try await spin(200)
        XCTAssertEqual(text(store),"BaseYZ"); XCTAssertEqual(field.string,"BaseYZ")
    }

    /// The store alone: the draft still waiting in the inspector lands before the style is read.
    @MainActor func testStyleChangesStartFromTheTextJustTyped() throws {
        _ = NSApplication.shared
        let store = EditorStore()
        var title = Clip(name:"T",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3)); title.style.text = "Old"; title.style.fontSize = 120
        store.edit("Fixture") { $0.clips = [title] }
        store.selectedClipID = title.id
        var waiting = true           // the inspector's draft, "Old and new", not yet committed
        store.flushPendingEdits = { [weak store] in
            guard waiting else { return }
            waiting = false
            store?.updateStyleLive(title.id,name:"Edit text",closesWhenIdle:false) { $0.text = "Old and new" }
        }
        store.updateStyle { style in let text = style.text; style = ClipStyle(); style.text = text }
        store.flushPendingEdits = nil
        let reset = try XCTUnwrap(store.selectedClip).style
        XCTAssertEqual(reset.text,"Old and new"); XCTAssertEqual(reset.fontSize,ClipStyle().fontSize)
        // The typing and the reset are two steps, in that order.
        XCTAssertEqual(store.undoName,"Adjust clip")
        store.undo()
        XCTAssertEqual(store.selectedClip?.style.text,"Old and new"); XCTAssertEqual(store.selectedClip?.style.fontSize,120)
        XCTAssertEqual(store.undoName,"Edit text")
        store.undo()
        XCTAssertEqual(store.selectedClip?.style.text,"Old")
    }
}
