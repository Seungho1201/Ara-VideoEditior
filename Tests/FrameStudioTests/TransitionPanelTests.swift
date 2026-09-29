import AppKit
import SwiftUI
import XCTest
import FrameCore
@testable import FrameStudio

@MainActor private final class PanelTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// A selected transition and the panels around it: tiles clicked one after another try kinds on
/// its edge, Delete removes it from the menu or the toolbar, and the key named for removing it is
/// the one Delete is set to.
final class TransitionPanelTests: XCTestCase {
    /// Titles A (V1 0–3 s) and B (V1 3–6 s) meeting at a cut.
    @MainActor private func makeStore() -> (EditorStore, UUID, UUID) {
        _ = NSApplication.shared
        let store = EditorStore()
        let a = Clip(name:"A",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3))
        let b = Clip(name:"B",kind:.text,lane:.v1,start:.init(seconds:3),duration:.init(seconds:3))
        store.edit("Fixture") { $0.frameRate = .init(30); $0.clips = [a,b] }
        store.isBuilding = false
        return (store,a.id,b.id)
    }
    /// `root` in an offscreen window, laid out.
    @MainActor private func host<Root: View>(_ root: Root, height: CGFloat) -> (NSWindow, NSHostingView<Root>) {
        let window = PanelTestWindow(contentRect:NSRect(x:0,y:0,width:300,height:height),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView:root)
        view.frame = NSRect(x:0,y:0,width:300,height:height)
        window.contentView = view
        settle(view)
        return (window,view)
    }
    @MainActor private func settle(_ view: NSView) {
        for _ in 0..<5 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.03)) }
    }
    @MainActor private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let hit = view as? T { found.append(hit) }
        for sub in view.subviews { found += all(type,in:sub) }
        return found
    }
    /// A click on a tile, as its AppKit view takes it (the tiles' order is the panel's).
    @MainActor private func click(_ kind: TransitionKind, in view: NSView) throws {
        let order = TransitionKind.Category.allCases.flatMap { category in TransitionKind.allCases.filter { $0.category == category } }
        let tiles = all(NSView.self,in:view).filter { String(describing:type(of:$0)).contains("TransitionDragView") }.sorted { a, b in
            let fa = a.convert(a.bounds,to:nil), fb = b.convert(b.bounds,to:nil)
            return fa.maxY != fb.maxY ? fa.maxY > fb.maxY : fa.minX < fb.minX
        }
        XCTAssertEqual(tiles.count,order.count)
        let tile = tiles[try XCTUnwrap(order.firstIndex(of:kind))], window = try XCTUnwrap(tile.window)
        let centre = tile.convert(NSPoint(x:tile.bounds.midX,y:tile.bounds.midY),to:nil)
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            let event = NSEvent.mouseEvent(with:type,location:centre,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                                           windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            if type == .leftMouseDown { tile.mouseDown(with:event) } else { tile.mouseUp(with:event) }
        }
        settle(view)
    }

    @MainActor func testClickingTilesTriesKindsOnTheSameEdge() throws {
        let (store,a,b) = makeStore()
        let (window,view) = host(TransitionLibrary(store:store),height:900)
        defer { window.contentView = nil; window.close() }
        store.selectedClipID = a; settle(view)
        try click(.crossDissolve,in:view)
        let added = try XCTUnwrap(store.selectedTransition)
        XCTAssertEqual(added.kind,.crossDissolve); XCTAssertEqual(added.from,a); XCTAssertEqual(added.to,b)
        XCTAssertNil(store.selectedClip,"the new transition is selected")
        store.updateSelectedTransition(direction:.up)
        // Straight away another tile: the same transition takes its kind, keeping its length and direction.
        try click(.wipe,in:view)
        XCTAssertEqual(store.project.transitions.count,1)
        let swapped = try XCTUnwrap(store.selectedTransition)
        XCTAssertEqual(swapped.id,added.id); XCTAssertEqual(swapped.kind,.wipe)
        XCTAssertEqual(swapped.duration,added.duration); XCTAssertEqual(swapped.direction,.up)
        XCTAssertEqual(store.undoName,"Transition kind")
        try click(.iris,in:view)
        XCTAssertEqual(store.selectedTransition?.kind,.iris)
        store.undo()
        XCTAssertEqual(store.selectedTransition?.kind,.wipe,"one undo step per kind tried")
        // A clip selected again: a click goes on its chosen edge, as before (B's end is free: a fade out).
        store.selectedClipID = b; settle(view)
        try click(.zoom,in:view)
        let fade = try XCTUnwrap(store.project.transitions.first { $0.from == b })
        XCTAssertEqual(fade.kind,.zoom); XCTAssertNil(fade.to)
        XCTAssertEqual(store.project.transitions.count,2)
    }

    /// App.swift enables Timeline ▸ Delete Linked Selection and the timeline's trash button with
    /// canDeleteSelection, and both run deleteSelection: a transition alone is enough, wherever the
    /// keyboard focus is (applying one from the panel leaves it where it was).
    @MainActor func testDeleteRemovesATransitionSelectedAlone() {
        let (store,a,b) = makeStore()
        XCTAssertFalse(store.canDeleteSelection,"nothing selected")
        XCTAssertTrue(store.applyTransition(.crossDissolve,from:a,to:b))
        XCTAssertNil(store.selectedClip); XCTAssertFalse(store.hasMultipleSelection)
        XCTAssertTrue(store.canDeleteSelection)
        store.deleteSelection()
        XCTAssertTrue(store.project.transitions.isEmpty)
        XCTAssertFalse(store.canDeleteSelection)
        store.selectedClipID = a
        XCTAssertTrue(store.canDeleteSelection,"a clip still counts")
    }

    /// The status after adding one names the key Delete is set to now, or none.
    @MainActor func testTheStatusNamesTheDeleteKeyAsSet() throws {
        let suite = "ara.tests.transition-panel", defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defaults.removePersistentDomain(forName:suite)
        defer { defaults.removePersistentDomain(forName:suite) }
        let (store,a,b) = makeStore()
        store.shortcuts = ShortcutSettings(defaults:defaults)
        store.applyTransition(.crossDissolve,from:a,to:b)
        XCTAssertEqual(store.status,"Cross Dissolve added · ⌫ to remove")
        store.shortcuts.set(Shortcut("x"),for:.delete)
        store.applyTransition(.wipe,from:a,to:b)
        XCTAssertEqual(store.status,"Wipe added · X to remove")
        store.shortcuts.set(nil,for:.delete)
        store.applyTransition(.iris,from:a,to:b)
        XCTAssertEqual(store.status,"Iris added")
    }

    /// The inspector's Remove transition button names the key Delete is set to now, or none. SwiftUI
    /// draws the button itself, so the check is on the drawn panel: it changes with the key alone.
    @MainActor func testTheRemoveButtonNamesTheDeleteKeyAsSet() throws {
        let shared = ShortcutSettings.shared, key = ShortcutSettings.storageKey, saved = UserDefaults.standard.object(forKey:key)
        try XCTSkipUnless(shared.changes.isEmpty,"this test process already has changed shortcuts")
        defer {
            shared.resetAll()
            if let saved { UserDefaults.standard.set(saved,forKey:key) } else { UserDefaults.standard.removeObject(forKey:key) }
        }
        let (store,a,b) = makeStore()
        XCTAssertTrue(store.applyTransition(.crossDissolve,from:a,to:b))
        let (window,view) = host(InspectorPanel(store:store),height:700)
        defer { window.contentView = nil; window.close() }
        func drawn() throws -> Data {
            settle(view)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:rep)
            return Data(bytes:try XCTUnwrap(rep.bitmapData),count:rep.bytesPerRow*rep.pixelsHigh)
        }
        let standard = try drawn()
        XCTAssertEqual(try drawn(),standard,"drawn the same way twice")
        shared.set(Shortcut("x"),for:.delete)
        let changed = try drawn()
        XCTAssertNotEqual(changed,standard,"X in place of ⌫")
        shared.set(nil,for:.delete)
        let none = try drawn()
        XCTAssertNotEqual(none,standard); XCTAssertNotEqual(none,changed)
        shared.reset(.delete)
        XCTAssertEqual(try drawn(),standard,"⌫ again")
    }
}
