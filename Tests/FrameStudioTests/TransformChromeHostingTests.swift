import AppKit
import XCTest
import SwiftUI
import FrameCore
@testable import FrameStudio

/// A hidden window: real responder methods, without taking the user's input focus.
@MainActor private final class HostingTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// The transform outline inside the whole editor, hosted by SwiftUI as in the app. SwiftUI does
/// not support AppKit views added straight to its hosting view: linked against a current SDK it
/// leaves them out of what is drawn, and the outline and its centre never showed.
@MainActor final class TransformChromeHostingTests: XCTestCase {
    private static let keys = ["timeline.snapping","timeline.scrubHaptics","haptics.off","haptics.skimStrength","editor.columnFractions.v1","editor.rowFractions.v1"]

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type,in:$0) }
    }

    func testTheOutlineLivesInTheEditorsChromeLayerAndOtherClicksGoThrough() async throws {
        _ = NSApplication.shared
        let saved = Self.keys.reduce(into:[String:Any]()) { values, key in values[key] = UserDefaults.standard.object(forKey:key) }
        let suite = "ara.tests.chrome-hosting.\(UUID().uuidString)"
        let store = EditorStore(registry:ProjectRegistry(defaults:UserDefaults(suiteName:suite)!))
        store.pasteboard = NSPasteboard(name:.init("ara-chrome-hosting-\(UUID().uuidString)"))
        store.runAlert = { alert in XCTFail("Unexpected question: \(alert.messageText)"); return .alertSecondButtonReturn }
        let size = CGSize(width:1440,height:920)
        let window = HostingTestWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        defer {
            store.pause(); store.pasteboard.releaseGlobally()
            window.contentView = nil; window.close()
            UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)
            for key in Self.keys { if let value = saved[key] { UserDefaults.standard.set(value,forKey:key) } else { UserDefaults.standard.removeObject(forKey:key) } }
        }
        for key in Self.keys where key.hasPrefix("editor.") { UserDefaults.standard.removeObject(forKey:key) }
        var title = Clip(name:"Title",kind:.text,lane:.v2,start:.zero,duration:.init(seconds:4)); title.style.text = "Hello"
        XCTAssertTrue(store.edit("Fixture") { $0.clips = [title] })
        store.resumeEditing(); store.selectedClipID = title.id
        let host = NSHostingView(rootView:EditorView(store:store).frame(width:size.width,height:size.height))
        host.frame = NSRect(origin:.zero,size:size)
        window.contentView = host
        func settle() async throws { for _ in 0..<30 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(25)) } }
        try await settle()
        for _ in 0..<1500 where store.isBuilding || store.player.currentItem == nil { try await Task.sleep(for:.milliseconds(10)) }
        store.previewTransformID = title.id
        try await settle()

        let preview = try XCTUnwrap(all(PreviewEditorView.self,in:host).first)
        let chrome = preview.chrome
        XCTAssertTrue(chrome.superview is TransformChromeLayerView,"in the editor's chrome layer, not on SwiftUI's hosting view (\(String(describing:chrome.superview.map { type(of:$0) })))")
        XCTAssertFalse(host.subviews.contains { $0 === chrome })
        XCTAssertTrue(chrome.window === window)
        XCTAssertFalse(chrome.isHidden,"shown while the title is transformed")
        XCTAssertEqual(chrome.frame.size,try XCTUnwrap(chrome.superview).bounds.size,"covering the whole editor")
        // Drawn: its layer is in the window's layer tree. On the hosting view it was not.
        func root(_ layer: CALayer?) -> CALayer? { var top = layer; while let up = top?.superlayer { top = up }; return top }
        XCTAssertNotNil(chrome.layer)
        XCTAssertTrue(root(chrome.layer) === root(host.layer),"the outline's layer is part of what the window draws")

        // Clicks: the chrome takes the title in the middle of the preview; elsewhere they reach
        // the views underneath, never the layer itself.
        func hit(_ view: NSView, _ point: CGPoint) -> NSView? {
            let inWindow = view.convert(point,to:nil)
            return host.hitTest(host.superview?.convert(inWindow,from:nil) ?? inWindow)
        }
        let overlay = preview.overlay
        XCTAssertTrue(hit(overlay,CGPoint(x:overlay.bounds.midX,y:overlay.bounds.midY)) === chrome,"the title under the outline")
        let timeline = try XCTUnwrap(all(TimelineCanvas.self,in:host).first)
        let below = hit(timeline,CGPoint(x:timeline.visibleRect.midX,y:timeline.visibleRect.maxY-12))
        XCTAssertFalse(below is TransformChromeLayerView); XCTAssertFalse(below === chrome)
        XCTAssertTrue(below.map { $0 === timeline || $0.isDescendant(of:timeline) } == true,"the timeline still takes its clicks (\(String(describing:below.map { type(of:$0) })))")
        // Out of transform mode the chrome is hidden and takes nothing.
        store.previewTransformID = nil; try await settle()
        XCTAssertTrue(chrome.isHidden)
        XCTAssertFalse(hit(overlay,CGPoint(x:overlay.bounds.midX,y:overlay.bounds.midY)) === chrome)
    }
}
