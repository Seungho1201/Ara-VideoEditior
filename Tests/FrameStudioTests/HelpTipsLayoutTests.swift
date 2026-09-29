import AppKit
import XCTest
import SwiftUI
@testable import FrameStudio

@MainActor private final class TipsTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// Help-mode callouts: bubbles never overlap or cover another control, lines never run under a
/// bubble, long notes wrap instead of being cut short, and only controls in view are named.
@MainActor final class HelpTipsLayoutTests: XCTestCase {
    private var owners: [NSObject] = []
    private func tip(_ text: String, _ target: CGRect, _ placement: HelpTipPlacement = .above) -> HelpTips.Tip {
        let owner = NSObject(); owners.append(owner)
        return HelpTips.Tip(id:ObjectIdentifier(owner),text:text,target:target,placement:placement)
    }
    /// What anyone reading the tips would object to, as "kind: tip / other".
    static func faults(_ placed: [HelpTips.Placed], in size: CGSize) -> [String] {
        var faults: [String] = []
        let bounds = CGRect(origin:.zero,size:size)
        for (i,a) in placed.enumerated() {
            if !bounds.contains(a.bubble) { faults.append("off screen: \(a.tip.text)") }
            for b in placed[(i+1)...] where a.bubble.intersects(b.bubble) { faults.append("overlap: \(a.tip.text) / \(b.tip.text)") }
            for b in placed where b.tip.id != a.tip.id {
                if b.tip.placement != .inside, a.bubble.intersects(b.tip.target) { faults.append("covers control: \(a.tip.text) / \(b.tip.text)") }
                if let line = b.pointer, a.bubble.intersects(line) { faults.append("line under bubble: \(b.tip.text) / \(a.tip.text)") }
            }
            if let line = a.pointer {
                // The line runs from the bubble's edge to the control's outline.
                XCTAssertTrue(line.insetBy(dx:-1,dy:-1).intersects(a.bubble) && line.insetBy(dx:-3,dy:-3).intersects(a.tip.target),"line of \(a.tip.text) joins its bubble to its control")
            }
        }
        return faults
    }

    func testCrowdedToolbarBubblesStepAwayInsteadOfOverlapping() {
        let size = CGSize(width:1400,height:800)
        // A toolbar row: 14 pt icons 30 pt apart, long names, plus a note over the area above.
        var tips = (0..<9).map { tip("Control number \($0) with a long name  ⇧⌘\($0)",CGRect(x:100+CGFloat($0)*30,y:500,width:14,height:14)) }
        tips.append(tip("A note about the whole area above the toolbar",CGRect(x:0,y:100,width:1400,height:380),.inside))
        tips.append(tip("Below",CGRect(x:40,y:40,width:40,height:20),.below))
        let placed = HelpTips.layout(tips,in:size)
        XCTAssertEqual(placed.count,tips.count)
        XCTAssertEqual(Self.faults(placed,in:size),[])
        // The row leans away from the window's edge: the control at its open end keeps the spot
        // right next to it, and the others stack up clear of each other's lines.
        let last = placed.first { $0.tip.id == tips[8].id }!
        XCTAssertEqual(last.bubble.maxY,500-12,accuracy:0.5)
        XCTAssertGreaterThan(placed.first { $0.tip.text == "Below" }!.bubble.minY,60,"a below tip stays below")
    }

    /// The editor's crowded places, drawn to scale: a row of transport buttons, a toolbar with
    /// icons close together, a toolbar button right above a panel title (the Projects icon over
    /// MEDIA), and toolbar buttons right above a panel's tabs. No line runs under a bubble, and
    /// none crosses another control.
    func testLinesRunClearOfBubblesAndControls() {
        let size = CGSize(width:1680,height:1050)
        var tips = ["Selected clip: first frame  ⌥←","Previous frame  ←","Play / Pause  Space","Next frame  →","Selected clip: last frame  ⌥→"].enumerated().map {
            tip($0.element,CGRect(x:864+CGFloat($0.offset)*30,y:518,width:26,height:28))
        }
        tips += ["Undo  ⌘Z","Redo  ⇧⌘Z","Split at playhead  ⌘B","Save frame as PNG  ⇧⌘E","Clip speed","Add title  ⇧⌘T","Rectangle select","Delete  ⌫"].enumerated().map {
            tip($0.element,CGRect(x:95+CGFloat($0.offset)*32,y:573,width:15,height:15))
        }
        tips += [tip("Projects  ⇧⌘1",CGRect(x:18,y:10,width:44,height:44),.below),
                 tip("Drag media onto the timeline, or double-click to add it at the end",CGRect(x:16,y:81,width:43,height:14),.below)]
        tips += ["New project  ⌘N","Open project  ⌘O","Save project  ⌘S","Import media  ⌘I"].enumerated().map {
            tip($0.element,CGRect(x:[1253,1324,1404,1493][$0.offset],y:24,width:[58,66,60,70][$0.offset],height:16),.below)
        }
        tips += [tip("Export movie  ⌘E",CGRect(x:1576,y:16,width:86,height:32),.below),
                 tip("Settings of the selected clip",CGRect(x:1312,y:81,width:76,height:17),.below),
                 tip("Transitions: drag onto a cut",CGRect(x:1404,y:81,width:91,height:17),.below),
                 tip("Double-click a clip to move, resize and rotate it",CGRect(x:690,y:160,width:500,height:320),.inside)]
        let placed = HelpTips.layout(tips,in:size)
        XCTAssertEqual(Self.faults(placed,in:size),[])
        for item in placed { if let line = item.pointer {
            for other in tips where other.id != item.tip.id && other.placement != .inside {
                XCTAssertFalse(other.target.insetBy(dx:-2,dy:-2).intersects(line),"line of \(item.tip.text) crosses \(other.text)")
            }
        } }
        // Where no line could miss the MEDIA title, the Projects note sits beside its icon.
        let projects = placed.first { $0.tip.text.hasPrefix("Projects") }!
        XCTAssertGreaterThan(projects.bubble.minX,62); XCTAssertLessThan(projects.bubble.minY,54)
    }

    /// A note too long for one line wraps onto two about as even as its words allow, and the
    /// bubble is sized for the lines SwiftUI draws: none is cut short. Short notes keep one line.
    func testALongNoteWrapsOntoTwoLines() {
        let media = tip("Drag media onto the timeline, or double-click to add it at the end",CGRect(x:16,y:81,width:43,height:14),.below)
        let size = HelpTips.size(of:media)
        XCTAssertLessThanOrEqual(size.width,300)
        XCTAssertLessThan(size.width,260,"two even lines, not one full one and a word")
        XCTAssertEqual(Self.linesDrawn(media.text,width:size.width-2*HelpTips.padding),2)
        XCTAssertGreaterThanOrEqual(size.height,Self.textHeight(media.text,width:size.width-2*HelpTips.padding))
        let short = tip("Undo  ⌘Z",.zero)
        XCTAssertEqual(HelpTips.size(of:short).height,HelpTips.lineHeight)
        XCTAssertEqual(Self.linesDrawn(short.text,width:HelpTips.size(of:short).width-2*HelpTips.padding),1)
        for text in ["클립을 드래그하여 이동, 가장자리를 드래그하여 다듬기 · Shift-드래그로 여러 개 선택 · 눈금자를 드래그하여 스키밍",
                     "Drag clips to move, their edges to trim · Shift-drag selects several · drag the ruler to skim"] {
            let area = tip(text,CGRect(x:0,y:0,width:900,height:300),.inside), size = HelpTips.size(of:area)
            XCTAssertLessThanOrEqual(Self.linesDrawn(text,width:size.width-2*HelpTips.padding),3)
            XCTAssertGreaterThanOrEqual(size.height,Self.textHeight(text,width:size.width-2*HelpTips.padding))
        }
    }
    /// How tall SwiftUI sets `text` in the bubbles' font, centred, `width` wide.
    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        NSHostingView(rootView:Text(verbatim:text).font(HelpTips.swiftUIFont).multilineTextAlignment(.center)
            .fixedSize(horizontal:false,vertical:true).frame(width:width)).fittingSize.height
    }
    /// How many lines SwiftUI takes for `text` at `width`.
    static func linesDrawn(_ text: String, width: CGFloat) -> Int {
        Int((textHeight(text,width:width)/textHeight("X",width:width)).rounded())
    }

    /// Only controls that show whole are named: not one scrolled out of a clipped column or a
    /// scroll view, nor one cut in half, nor one in a see-through view. An area is named where it
    /// shows.
    func testOnlyControlsInViewAreNamed() throws {
        _ = NSApplication.shared
        let window = TipsTestWindow(contentRect:NSRect(x:0,y:0,width:400,height:700),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView:VStack(spacing:0) {
            Color.clear.frame(height:200).helpTip("Above the column")
            // A column scrolled 100 pt up in a clipped frame, as the timeline's track names are.
            VStack(spacing:0) {
                Color.clear.frame(height:30).helpTip("Scrolled out")
                Color.clear.frame(height:60).helpTip("Cut in half")
                Color.clear.frame(height:30).helpTip("In view")
                Color.clear.frame(height:300).helpTip("An area",.inside)
            }
            .offset(y:-75).frame(height:150,alignment:.top).clipped()
            ScrollView { VStack(spacing:0) { ForEach(0..<6) { row in Color.clear.frame(height:40).helpTip("Row \(row)") } } }.frame(height:100)
            VStack { Color.clear.frame(height:30).helpTip("See-through") }.opacity(0)
            Spacer()
        }.frame(width:400,height:700))
        host.frame = NSRect(x:0,y:0,width:400,height:700)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        let tips = HelpTips.tips(in:host)
        XCTAssertEqual(Set(tips.map(\.text)),["Above the column","In view","An area","Row 0","Row 1"])
        // The area is named where it shows: the column's part of it.
        let area = try XCTUnwrap(tips.first { $0.text == "An area" })
        XCTAssertEqual(area.target.minY,245,accuracy:0.5); XCTAssertEqual(area.target.maxY,350,accuracy:0.5)
    }
}
