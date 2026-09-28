import AppKit
import XCTest
@testable import FrameStudio

/// Help-mode callouts: neighbouring controls' bubbles never overlap or cover another control.
@MainActor final class HelpTipsLayoutTests: XCTestCase {
    private var owners: [NSObject] = []
    private func tip(_ text: String, _ target: CGRect, _ placement: HelpTipPlacement = .above) -> HelpTips.Tip {
        let owner = NSObject(); owners.append(owner)
        return HelpTips.Tip(id:ObjectIdentifier(owner),text:text,target:target,placement:placement)
    }
    func testCrowdedToolbarBubblesStepAwayInsteadOfOverlapping() {
        let size = CGSize(width:1400,height:800)
        // A toolbar row: 14 pt icons 30 pt apart, long names, plus a note over the area above.
        var tips = (0..<9).map { tip("Control number \($0) with a long name  ⇧⌘\($0)",CGRect(x:100+CGFloat($0)*30,y:500,width:14,height:14)) }
        tips.append(tip("A note about the whole area above the toolbar",CGRect(x:0,y:100,width:1400,height:380),.inside))
        tips.append(tip("Below",CGRect(x:40,y:40,width:40,height:20),.below))
        let placed = HelpTips.layout(tips,in:size)
        XCTAssertEqual(placed.count,tips.count)
        let bounds = CGRect(origin:.zero,size:size)
        for (i,a) in placed.enumerated() {
            XCTAssertTrue(bounds.contains(a.bubble),"\(a.tip.text) stays on screen")
            for b in placed[(i+1)...] { XCTAssertFalse(a.bubble.intersects(b.bubble),"\(a.tip.text) / \(b.tip.text)") }
            for other in tips where other.id != a.tip.id && other.placement != .inside {
                XCTAssertFalse(a.bubble.intersects(other.target),"\(a.tip.text) covers \(other.text)")
            }
        }
        // The first control keeps the spot right next to it.
        let first = placed.first { $0.tip.id == tips[0].id }!
        XCTAssertEqual(first.bubble.maxY,500-12,accuracy:0.5)
        XCTAssertGreaterThan(placed.first { $0.tip.text == "Below" }!.bubble.minY,60,"a below tip stays below")
    }
}
