import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

/// While playing, a playhead that runs off the visible timeline turns the page.
final class TimelinePageTurnTests: XCTestCase {
    @MainActor private func withTimeline(_ check: (EditorStore, TimelineCanvas, NSScrollView) throws -> Void) rethrows {
        _ = NSApplication.shared
        let store = EditorStore()
        store.edit("Fixture") { project in
            project.frameRate = .init(30)
            project.clips = [Clip(name:"Title",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:60))]
        }
        store.isBuilding = false                        // only the model and the view are needed
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:800,height:300))
        let canvas = TimelineCanvas(frame:NSRect(x:0,y:0,width:(60+8)*60,height:300))
        canvas.pixelsPerSecond = 60
        scroll.documentView = canvas
        canvas.store = store
        defer { store.isPlaying = false }
        try check(store,canvas,scroll)
    }
    @MainActor private func scrolled(_ scroll: NSScrollView) -> CGFloat { scroll.contentView.bounds.minX }

    @MainActor func testPlayingPastTheRightEdgeBringsTheNextPage() {
        withTimeline { store, canvas, scroll in
            store.isPlaying = true
            store.playhead = .init(seconds:12)                          // x 720: on screen
            XCTAssertEqual(scrolled(scroll),0)
            store.playhead = .init(seconds:13)                          // x 780: past 800 - 40
            XCTAssertEqual(scrolled(scroll),780-40,accuracy:0.5,"the playhead starts the new page 40 pt in")
            // Page after page.
            store.playhead = .init(seconds:24.9)                        // 1494: still short of 740 + 800 - 40
            XCTAssertEqual(scrolled(scroll),740,accuracy:0.5)
            store.playhead = .init(seconds:25.5)                        // 1530: past it
            XCTAssertEqual(scrolled(scroll),1530-40,accuracy:0.5)
            // Playing on from the start again: back to the beginning.
            store.playhead = .zero
            XCTAssertEqual(scrolled(scroll),0,accuracy:0.5)
        }
    }

    @MainActor func testNoPageTurnWhenPausedOrWhenTheUserScrolledAway() {
        withTimeline { store, canvas, scroll in
            // Paused (stepping, scrubbing, seeking): the view stays where it is.
            store.isPlaying = false
            store.playhead = .init(seconds:12); store.playhead = .init(seconds:14)
            XCTAssertEqual(scrolled(scroll),0)
            // Scrolled away to look at something else while it plays: not dragged back.
            store.isPlaying = true
            scroll.contentView.scroll(to:NSPoint(x:2000,y:0)); scroll.reflectScrolledClipView(scroll.contentView)
            store.playhead = .init(seconds:14.5); store.playhead = .init(seconds:15)
            XCTAssertEqual(scrolled(scroll),2000,accuracy:0.5)
        }
    }
}
