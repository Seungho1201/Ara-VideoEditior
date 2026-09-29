import AppKit
import SwiftUI
import XCTest
import FrameCore
@testable import FrameStudio

@MainActor private final class HostWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// What the timeline writes, and where: every word through the string table (with a Korean
/// entry), the empty-timeline hint inside a row, the clip-end badge clear of the ruler's times,
/// and help tips only for the track buttons in view.
@MainActor final class TimelineLabelTests: XCTestCase {
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

    func testEveryWordTheCanvasShowsHasAKoreanEntry() throws {
        let korean = try korean()
        let keys = ["Drag media onto a video (V) or audio (A) track","CLIP END","Track occupied","%.2f s · %lldf","%@ · in","%@ · out",
                    "A timeline has at most %lld video tracks","A timeline has at most %lld audio tracks",
                    "Multitrack timeline. Video tracks above audio tracks, up to %lld of each. Linked audio is on the audio track numbered like its video."]
        for key in keys {
            let value = try XCTUnwrap(korean[key],"no Korean for “\(key)”")
            XCTAssertEqual(specifiers(value),specifiers(key),key)
        }
        // Transition strips and the drop pill name a kind as the panels do.
        for kind in TransitionKind.allCases { XCTAssertNotNil(korean[kind.name],kind.name) }
        XCTAssertNil(korean["A timeline has at most %lld %@ tracks"],"no English word goes into the Korean sentence")
        XCTAssertNotEqual(korean["Span"],korean["RANGE"],"a multiple selection's length is not named like its section")
        XCTAssertEqual(TimelineCanvas(frame:.zero).accessibilityLabel(),
                       "Multitrack timeline. Video tracks above audio tracks, up to 8 of each. Linked audio is on the audio track numbered like its video.")
    }

    func testTheEmptyTimelineHintSitsInsideARow() throws {
        let rig = TimelineRig(width:900,height:340) { _ in }
        defer { rig.close() }
        let image = rig.paint()
        // The hint's letters are far brighter than the rows, the lines between them and the second marks.
        let lit = (Int(TimelineCanvas.ruler)..<340).filter { y in (20..<420).contains { x in TimelineRig.color(image,Double(x),Double(y)).red > 80 } }
        let top = try XCTUnwrap(lit.first), bottom = try XCTUnwrap(lit.last)
        let inside = (0..<4).contains { index in
            let rowTop = TimelineCanvas.ruler+TimelineCanvas.addBand+Double(index)*TimelineCanvas.rowHeight
            return Double(top) > rowTop && Double(bottom) < rowTop+TimelineCanvas.rowHeight-1
        }
        XCTAssertTrue(inside,"the hint spans y \(top)–\(bottom), across a line between rows")
    }

    func testTheClipEndBadgeStaysClearOfTheRulersTimes() {
        let rig = TimelineRig(width:900,height:340) { project in
            project.clips = [Clip(name:"A",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3)),
                             Clip(name:"B",kind:.text,lane:.v1,start:.init(seconds:3),duration:.init(seconds:3))]
        }
        defer { rig.close() }
        // Skimming the ruler onto B's end (6 s, beside the 00:06 mark) catches it, and the badge says so.
        rig.down(5.9,TimelineRig.rulerY); rig.drag(5.95,TimelineRig.rulerY)
        XCTAssertEqual(rig.store.playhead,.init(seconds:6))
        let image = rig.paint(), x = 6*TimelineRig.pps+12
        XCTAssertTrue(TimelineRig.isAccent(image,x,TimelineCanvas.ruler+4),"the badge, just under the ruler")
        XCTAssertFalse((13..<28).contains { TimelineRig.isAccent(image,x,Double($0)) },"none of it over the ruler's times")
        rig.up(5.95,TimelineRig.rulerY)
    }

    func testTheTrackButtonsHaveTipsOnlyWhileInView() throws {
        let rig = TimelineRig { project in
            for n in 3...8 { try project.ensureLane(Lane(.video,n)); try project.ensureLane(Lane(.audio,n)) }
            project.clips = [Clip(name:"T",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3))]
        }
        // The timeline in the middle of a taller view, as in the editor: a button scrolled out of the
        // track names would otherwise report a place over whatever is above or below.
        let window = HostWindow(contentRect:NSRect(x:0,y:0,width:900,height:1402),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView:VStack(spacing:0) {
            Color.clear.frame(height:300); TimelineView(store:rig.store).frame(height:302); Color.clear.frame(height:800)
        }.frame(width:900,height:1402))
        host.frame = NSRect(x:0,y:0,width:900,height:1402)
        window.contentView = host
        defer { window.contentView = nil; window.close(); rig.close() }
        /// The tips once SwiftUI has caught up (it updates on the run loop): what is expected, or after
        /// three seconds whatever is there.
        func tips(settlingOn expected: Set<String>) -> Set<String> {
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.1))
                if Set(HelpTips.tips(in:host).map(\.text)) == expected { break }
            }
            return Set(HelpTips.tips(in:host).map(\.text))
        }
        func scroll(to y: (NSScrollView) -> CGFloat) throws {
            let scroll = try XCTUnwrap(find(NSScrollView.self,in:host))
            scroll.contentView.scroll(to:NSPoint(x:0,y:y(scroll))); scroll.reflectScrolledClipView(scroll.contentView)
        }
        XCTAssertEqual(tips(settlingOn:["Add a video track"]),["Add a video track"],"at the top: the + above the tracks, not the one below the view")
        try scroll { _ in 200 }
        XCTAssertEqual(tips(settlingOn:[]),[],"part way down: neither")
        try scroll { $0.documentView!.frame.height-$0.contentView.bounds.height }
        XCTAssertEqual(tips(settlingOn:["Add an audio track"]),["Add an audio track"],"at the bottom: the + below the tracks")
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews { if let hit = find(type,in:sub) { return hit } }
        return nil
    }
}
