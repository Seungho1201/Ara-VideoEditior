import AppKit
import SwiftUI
import XCTest
import FrameCore
@testable import FrameStudio

/// The Export and New Project sheets line their pickers up on one leading edge, whatever width
/// the system gives a pop-up. Under the current SDK SwiftUI draws the pop-ups itself, each with a
/// focus ring view of its frame; under the macOS 15 SDK they are pop-up buttons filling the column.
@MainActor final class SheetLayoutTests: XCTestCase {
    private func host<Root: View>(_ root: Root) -> (NSWindow, NSHostingView<Root>) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:470,height:520),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView:root)
        view.frame = NSRect(x:0,y:0,width:470,height:520)
        window.contentView = view
        for _ in 0..<4 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.03)) }
        return (window,view)
    }
    /// The sheet's pop-up menus, top first, in window coordinates (the Grid's rows come before the
    /// buttons at the bottom, which have focus rings too), and whether SwiftUI draws them.
    private func pickers(in view: NSView, count: Int) -> (frames: [CGRect], drawn: Bool) {
        var buttons: [CGRect] = [], rings: [CGRect] = []
        func visit(_ view: NSView) {
            if view is NSPopUpButton { buttons.append(view.convert(view.bounds,to:nil)); return }
            if String(describing:type(of:view)).contains("FocusRing") { rings.append(view.convert(view.bounds,to:nil)) }
            view.subviews.forEach(visit)
        }
        visit(view)
        return (Array((buttons.isEmpty ? rings : buttons).sorted { $0.maxY > $1.maxY }.prefix(count)),buttons.isEmpty)
    }
    private func edges(_ frames: [CGRect]) -> CGFloat { (frames.map(\.minX).max() ?? 0)-(frames.map(\.minX).min() ?? 0) }

    func testTheExportSheetsPickersShareALeadingEdge() {
        let (window,view) = host(ExportSettingsView(store:EditorStore()))
        defer { window.contentView = nil; window.close() }
        let frames = pickers(in:view,count:3).frames
        XCTAssertEqual(frames.count,3,"aspect ratio, frame rate and resolution")
        XCTAssertEqual(edges(frames),0,accuracy:0.5,"\(frames)")
    }

    func testTheNewProjectSheetsPickersShareALeadingEdge() {
        let (window,view) = host(NewProjectView(store:EditorStore()))
        defer { window.contentView = nil; window.close() }
        let (frames,drawn) = pickers(in:view,count:3)
        XCTAssertEqual(frames.count,3,"quality, aspect ratio and frame rate")
        XCTAssertEqual(edges(frames),0,accuracy:0.5,"\(frames)")
        // Drawn by SwiftUI, they start where the name field does.
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        if drawn, let field = fields(view).first(where: \.isEditable) {
            XCTAssertEqual(field.convert(field.bounds,to:nil).minX,frames.first?.minX ?? 0,accuracy:0.5)
        }
    }
}
