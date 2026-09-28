import SwiftUI
import AppKit

/// Help mode: callouts over the editor naming what each control does, shown with the timeline's
/// ? button (or Help ▸ Show Tips) and closed by a click anywhere or Esc.
///
/// Each control marks itself with `.helpTip(…)`: a small AppKit view in its background that the
/// overlay measures. The panels live in split views (separate hosting views), where SwiftUI
/// geometry and preferences do not reach across; window coordinates do.

/// Where a callout sits: above or below the control, or over the middle of a large area.
enum HelpTipPlacement { case above, below, inside }

@MainActor final class HelpAnchorView: NSView {
    var text = ""
    var placement = HelpTipPlacement.above
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        HelpTips.anchors.removeAll { $0.view == nil || $0.view === self }
        if window != nil { HelpTips.anchors.append(.init(view:self)) }
    }
}

enum HelpTips {
    struct Anchor { weak var view: HelpAnchorView? }
    @MainActor static var anchors: [Anchor] = []
    struct Tip: Identifiable {
        let id: ObjectIdentifier
        let text: String
        let target: CGRect
        let placement: HelpTipPlacement
    }
    /// The visible anchors in `view`'s window, in `view`'s (flipped) coordinates.
    @MainActor static func tips(in view: NSView) -> [Tip] {
        guard let window = view.window else { return [] }
        return anchors.compactMap { anchor in
            guard let anchorView = anchor.view, anchorView.window === window, !anchorView.isHiddenOrHasHiddenAncestor else { return nil }
            // Bounds, not visibleRect: inside SwiftUI's hosting views visibleRect is the whole
            // panel. A control scrolled out of sight lies outside the overlay and is left out.
            let rect = view.convert(anchorView.bounds,from:anchorView)
            guard rect.width > 0, rect.height > 0, view.bounds.insetBy(dx:-1,dy:-1).contains(rect) else { return nil }
            return Tip(id:ObjectIdentifier(anchorView),text:anchorView.text,target:rect,placement:anchorView.placement)
        }
    }
}

private struct HelpAnchor: NSViewRepresentable {
    let text: String
    let placement: HelpTipPlacement
    func makeNSView(context: Context) -> HelpAnchorView { HelpAnchorView() }
    func updateNSView(_ view: HelpAnchorView, context: Context) {
        view.text = text; view.placement = placement
    }
}

extension View {
    /// Names this control in help mode. `text` is a key in the string table; a shortcut, if
    /// given, is added as it is set now.
    func helpTip(_ text: String, _ placement: HelpTipPlacement = .above, shortcut: String = "") -> some View {
        let localized = Bundle.main.localizedString(forKey:text,value:text,table:nil)
        return background(HelpAnchor(text:shortcut.isEmpty ? localized : "\(localized)  \(shortcut)",placement:placement))
    }
}

/// Measures the overlay's own place in the window, and again whenever it is laid out.
private struct HelpProbe: NSViewRepresentable {
    let onLayout: (NSView) -> Void
    final class Probe: NSView {
        var onLayout: ((NSView) -> Void)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); report() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        private func report() { DispatchQueue.main.async { [weak self] in if let self { self.onLayout?(self) } } }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.onLayout = onLayout }
}

struct HelpOverlay: View {
    @Binding var isShown: Bool
    @State private var tips: [HelpTips.Tip] = []
    var body: some View {
        GeometryReader { geometry in
            let placed = HelpTips.layout(tips,in:geometry.size)
            ZStack(alignment:.topLeading) {
                Color.black.opacity(0.38)
                // Outlines and pointers first, so no line crosses a bubble.
                ForEach(placed) { item in
                    if item.tip.placement != .inside {
                        RoundedRectangle(cornerRadius:4).stroke(Theme.accent.opacity(0.9),lineWidth:1)
                            .frame(width:item.tip.target.width+4,height:item.tip.target.height+4)
                            .position(x:item.tip.target.midX,y:item.tip.target.midY)
                        pointer(item)
                    }
                }
                ForEach(placed) { item in
                    Text(verbatim:item.tip.text).font(HelpTips.swiftUIFont).foregroundStyle(Theme.background)
                        .lineLimit(item.tip.placement == .inside ? 3 : 1).multilineTextAlignment(.center)
                        .frame(width:item.bubble.width-2*HelpTips.padding,height:item.bubble.height)
                        .padding(.horizontal,HelpTips.padding)
                        .background(Theme.accent,in:RoundedRectangle(cornerRadius:5))
                        .shadow(color:.black.opacity(0.35),radius:3,y:1)
                        .position(x:item.bubble.midX,y:item.bubble.midY)
                }
            }
            .background(HelpProbe { probe in tips = HelpTips.tips(in:probe) })
        }
        .contentShape(Rectangle())
        .onTapGesture { isShown = false }
        .overlay { Button("") { isShown = false }.keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false) }
        .accessibilityElement(children:.contain)
        .accessibilityLabel("Tips. Click anywhere to close.")
        .transition(.opacity)
    }
    /// A line from the bubble to the control, down (or up) from wherever the bubble ended up.
    private func pointer(_ item: HelpTips.Placed) -> some View {
        let target = item.tip.target, bubble = item.bubble
        let above = bubble.midY < target.midY
        let from = above ? bubble.maxY : bubble.minY, to = above ? target.minY-2 : target.maxY+2
        let x = min(max(target.midX,bubble.minX+6),bubble.maxX-6)
        return Rectangle().fill(Theme.accent).frame(width:1.5,height:max(0,abs(to-from)))
            .position(x:x,y:(from+to)/2)
    }
}

extension HelpTips {
    @MainActor static let font = NSFont.systemFont(ofSize:11,weight:.medium)
    static let swiftUIFont = Font.system(size:11,weight:.medium)
    static let padding: CGFloat = 9
    static let lineHeight: CGFloat = 22
    struct Placed: Identifiable {
        let tip: Tip
        let bubble: CGRect
        var id: ObjectIdentifier { tip.id }
    }
    /// The bubble's size: one line beside a control, up to three over an area.
    @MainActor static func size(of tip: Tip) -> CGSize {
        let inside = tip.placement == .inside
        let text = tip.text as NSString
        // A little slack: SwiftUI sets symbols such as ⌘ and ⇧ slightly wider than AppKit measures.
        let width = min(inside ? 380 : 300,ceil(text.size(withAttributes:[.font:font]).width)+2*padding+8)
        guard inside else { return CGSize(width:width,height:lineHeight) }
        let height = ceil(text.boundingRect(with:CGSize(width:width-2*padding,height:.greatestFiniteMagnitude),
                                            options:[.usesLineFragmentOrigin],attributes:[.font:font]).height)
        return CGSize(width:width,height:max(lineHeight,height+10))
    }
    /// Where each bubble goes. A bubble starts next to its control, on the side asked for, and
    /// moves away from it step by step until it covers no other bubble and no other control;
    /// if that side runs out of room it tries the other. Area notes go first, in the middle of
    /// their area, and the rest keep clear of them.
    @MainActor static func layout(_ tips: [Tip], in size: CGSize, measure: @MainActor (Tip) -> CGSize = HelpTips.size) -> [Placed] {
        let bounds = CGRect(origin:.zero,size:size).insetBy(dx:4,dy:4)
        let controls = tips.filter { $0.placement != .inside }
        var placed: [Placed] = []
        func clear(_ rect: CGRect, of tip: Tip) -> Bool {
            guard bounds.contains(rect) else { return false }
            let padded = rect.insetBy(dx:-3,dy:-3)
            if placed.contains(where: { $0.bubble.intersects(padded) }) { return false }
            return !controls.contains { $0.id != tip.id && $0.target.intersects(padded) }
        }
        let ordered = tips.filter { $0.placement == .inside }
            + controls.sorted { ($0.target.minY,$0.target.minX) < ($1.target.minY,$1.target.minX) }
        for tip in ordered {
            let measured = measure(tip)
            func rect(centreY: CGFloat) -> CGRect {
                let x = min(max(tip.target.midX-measured.width/2,bounds.minX),bounds.maxX-measured.width)
                return CGRect(x:x,y:centreY-measured.height/2,width:measured.width,height:measured.height)
            }
            if tip.placement == .inside {
                var spot = rect(centreY:tip.target.midY)
                // Nudged down past any bubble already there.
                while !clear(spot,of:tip), spot.maxY < min(tip.target.maxY,bounds.maxY) { spot.origin.y += 6 }
                placed.append(Placed(tip:tip,bubble:spot)); continue
            }
            func spot(on above: Bool, gap: CGFloat) -> CGRect {
                rect(centreY:above ? tip.target.minY-gap-measured.height/2 : tip.target.maxY+gap+measured.height/2)
            }
            let preferAbove = tip.placement == .above
            var chosen: CGRect?
            search: for side in [preferAbove,!preferAbove] {
                for step in 0..<60 {
                    let candidate = spot(on:side,gap:12+CGFloat(step)*6)
                    if !bounds.contains(candidate) { break }
                    if clear(candidate,of:tip) { chosen = candidate; break search }
                }
            }
            placed.append(Placed(tip:tip,bubble:chosen ?? spot(on:preferAbove,gap:12)))
        }
        return placed
    }
}
