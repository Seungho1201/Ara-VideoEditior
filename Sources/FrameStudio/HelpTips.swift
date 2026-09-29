import SwiftUI
import AppKit

/// Help mode: callouts over the editor naming what each control does, shown with the timeline's
/// ? button (or Help ▸ Show Tips) and closed by a click anywhere or Esc. Meanwhile other keys typed
/// in the editor do nothing.
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
    /// The anchors in `view`'s window that show, in `view`'s (flipped) coordinates. A control is
    /// named only while it shows whole: a control scrolled or clipped out of sight keeps its
    /// place, and its tip would point at whatever is there. An area is named where it shows.
    @MainActor static func tips(in view: NSView) -> [Tip] {
        guard let window = view.window else { return [] }
        return anchors.compactMap { anchor in
            guard let anchorView = anchor.view, anchorView.window === window, let shown = shownPart(of:anchorView) else { return nil }
            let rect = view.convert(anchorView.bounds,from:anchorView), part = view.convert(shown,from:anchorView).intersection(view.bounds)
            if anchorView.placement == .inside {
                guard part.width >= 40, part.height >= 30 else { return nil }
                return Tip(id:ObjectIdentifier(anchorView),text:anchorView.text,target:part,placement:.inside)
            }
            guard rect.width > 0, rect.height > 0, part.insetBy(dx:-1,dy:-1).contains(rect) else { return nil }
            return Tip(id:ObjectIdentifier(anchorView),text:anchorView.text,target:rect,placement:anchorView.placement)
        }
    }
    /// The part of `view` its ancestors let show, in its own coordinates; nil when one of them is
    /// hidden or see-through, or clips it away. Bounds, not visibleRect: inside SwiftUI's hosting
    /// views visibleRect is the whole panel. What clips is a scroll view, a split pane or a
    /// `.clipped()` SwiftUI view, each an AppKit view that clips to its bounds.
    @MainActor static func shownPart(of view: NSView) -> CGRect? {
        var shown = view.bounds, ancestor: NSView? = view
        while let current = ancestor {
            if current.isHidden || current.alphaValue < 0.01 { return nil }
            if current !== view, current.clipsToBounds || current.layer?.masksToBounds == true {
                shown = shown.intersection(view.convert(current.bounds,from:current))
            }
            ancestor = current.superview
        }
        return shown.isEmpty ? nil : shown
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
                // Outlines and lines first, under the bubbles.
                ForEach(placed) { item in
                    if let line = item.pointer {
                        RoundedRectangle(cornerRadius:4).stroke(Theme.accent.opacity(0.9),lineWidth:1)
                            .frame(width:item.tip.target.width+4,height:item.tip.target.height+4)
                            .position(x:item.tip.target.midX,y:item.tip.target.midY)
                        Rectangle().fill(Theme.accent).frame(width:line.width,height:line.height).position(x:line.midX,y:line.midY)
                    }
                }
                ForEach(placed) { item in
                    Text(verbatim:item.tip.text).font(HelpTips.swiftUIFont).foregroundStyle(Theme.background)
                        .lineLimit(HelpTips.lines(item.tip)).multilineTextAlignment(.center)
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
        .background(HelpKeys { isShown = false })
        .accessibilityElement(children:.contain)
        .accessibilityLabel("Tips. Click anywhere to close.")
        .transition(.opacity)
    }
}

/// While help is shown, keys typed in its window do nothing but Esc, which closes it: the tips are
/// read over a dimmed editor that must not change underneath, whatever has the keyboard (the
/// timeline, the preview, a text field) and whatever the menus would do with the key. Quit,
/// Hide, Minimise, Close, Settings and the like still answer.
struct HelpKeys: NSViewRepresentable {
    let close: () -> Void
    final class Guard: NSView {
        var close: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = window == nil ? nil : NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in self?.handle(event) ?? event }
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            if event.keyCode == 53 { close?(); return nil }
            return Shortcut(event:event)?.isAppKey == true ? event : nil
        }
    }
    func makeNSView(context: Context) -> Guard { let view = Guard(); view.close = close; return view }
    func updateNSView(_ view: Guard, context: Context) { view.close = close }
}

extension HelpTips {
    @MainActor static let font = NSFont.systemFont(ofSize:11,weight:.medium)
    static let swiftUIFont = Font.system(size:11,weight:.medium)
    static let padding: CGFloat = 9
    static let lineHeight: CGFloat = 22
    struct Placed: Identifiable {
        let tip: Tip
        let bubble: CGRect
        /// The line from the bubble to its control; none for an area's note.
        let pointer: CGRect?
        var id: ObjectIdentifier { tip.id }
    }
    /// The most lines a bubble shows: two beside a control, three over an area.
    static func lines(_ tip: Tip) -> Int { tip.placement == .inside ? 3 : 2 }
    /// The bubble's size. A control's note takes one line up to 300 pt, or else two about as even
    /// as its words allow; an area's note up to three lines 380 pt wide. The lines are measured a
    /// little narrower than the bubble gives them, as SwiftUI sets symbols such as ⌘ and ⇧ slightly
    /// wider than AppKit measures them, so it never needs more lines than counted here.
    @MainActor static func size(of tip: Tip) -> CGSize {
        let slack: CGFloat = 8, inside = tip.placement == .inside, widest: CGFloat = inside ? 380 : 300
        let text = tip.text as NSString, attributes: [NSAttributedString.Key:Any] = [.font:font]
        let natural = ceil(text.size(withAttributes:attributes).width)+2*padding+slack
        if !inside && natural <= widest { return CGSize(width:natural,height:lineHeight) }
        func height(_ width: CGFloat) -> CGFloat {
            ceil(text.boundingRect(with:CGSize(width:width-2*padding-slack,height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin],attributes:attributes).height)
        }
        let most = CGFloat(lines(tip))*height(.greatestFiniteMagnitude)
        var width = min(widest,natural)
        if !inside {
            width = ceil(natural/2+padding+slack/2)
            while width < widest && height(width) > most { width += 4 }
            width = min(width,widest)
        }
        return CGSize(width:width,height:max(lineHeight,min(height(width),most)+10))
    }
    /// The line from `bubble` to `target` through `at`: its x from a bubble above or below the
    /// control, its y from one beside it.
    static func pointer(from bubble: CGRect, to target: CGRect, at position: CGFloat) -> CGRect {
        if bubble.minX >= target.maxX || bubble.maxX <= target.minX {
            let (left,right) = bubble.minX >= target.maxX ? (target.maxX+2,bubble.minX) : (bubble.maxX,target.minX-2)
            return CGRect(x:left,y:position-0.75,width:max(0,right-left),height:1.5)
        }
        let (top,bottom) = bubble.midY < target.midY ? (bubble.maxY,target.minY-2) : (target.maxY+2,bubble.minY)
        return CGRect(x:position-0.75,y:top,width:1.5,height:max(0,bottom-top))
    }
    /// Where each bubble goes, and the line from it to its control. Area notes go first, in the
    /// middle of their area. A control's bubble starts next to it on the side asked for and moves
    /// away step by step, centred on its line or leaning to either side, until it covers no other
    /// bubble, control or line and its own line runs under no bubble; then it tries the other
    /// side, and last beside the control. The spot taken first also keeps its line off other
    /// controls and leaves each control still to come a way out to its own bubble; where no spot
    /// does, the line may cross a control, then another control may be hemmed in, and last lines
    /// may run under bubbles, which still never cover each other.
    @MainActor static func layout(_ tips: [Tip], in size: CGSize, measure: @MainActor (Tip) -> CGSize = HelpTips.size) -> [Placed] {
        let bounds = CGRect(origin:.zero,size:size).insetBy(dx:4,dy:4)
        let controls = tips.filter { $0.placement != .inside }
        var placed: [Placed] = []
        /// Covers no bubble or other control and, with `lines`, no line, while its own line runs
        /// under no bubble.
        func clear(_ bubble: CGRect, _ line: CGRect?, of tip: Tip, lines: Bool = true) -> Bool {
            guard bounds.contains(bubble) else { return false }
            let padded = bubble.insetBy(dx:-3,dy:-3)
            if placed.contains(where: { $0.bubble.intersects(padded) || lines && $0.pointer?.intersects(padded) == true }) { return false }
            if controls.contains(where: { $0.id != tip.id && $0.target.intersects(padded) }) { return false }
            guard lines, let line else { return true }
            return !placed.contains { $0.bubble.intersects(line.insetBy(dx:-2,dy:-2)) }
        }
        for tip in tips where tip.placement == .inside {
            let measured = measure(tip)
            let x = min(max(tip.target.midX-measured.width/2,bounds.minX),bounds.maxX-measured.width)
            var spot = CGRect(x:x,y:tip.target.midY-measured.height/2,width:measured.width,height:measured.height)
            // Nudged down past any bubble already there.
            while !clear(spot,nil,of:tip), spot.maxY < min(tip.target.maxY,bounds.maxY) { spot.origin.y += 6 }
            placed.append(Placed(tip:tip,bubble:spot,pointer:nil))
        }
        // A row at a time, top down: controls level with each other, with bubbles on the same side.
        // A group of controls close together goes from both ends inward: the outer bubbles lean
        // outward as they step away and those in the middle go on top, each clear of the lines
        // before it. It goes from one end only where the other has no room to lean out.
        var rows: [[Tip]] = []
        for tip in controls.sorted(by: { ($0.target.minY,$0.target.minX) < ($1.target.minY,$1.target.minX) }) {
            if let last = rows.last?.last, last.placement == tip.placement, tip.target.minY < last.target.maxY { rows[rows.count-1].append(tip) }
            else { rows.append([tip]) }
        }
        var groups: [[Tip]] = [], group: [ObjectIdentifier:Int] = [:]
        for row in rows {
            var members: [Tip] = []
            func close() {
                guard let first = members.first, let last = members.last else { return }
                for tip in members { group[tip.id] = groups.count }
                let left = first.target.midX+6-measure(first).width >= bounds.minX, right = last.target.midX-6+measure(last).width <= bounds.maxX
                var order: [Tip] = []
                if left != right { order = right ? members.reversed() : members }
                else { while !members.isEmpty { order.append(members.removeFirst()); if let last = members.popLast() { order.append(last) } } }
                groups.append(order); members = []
            }
            for tip in row.sorted(by: { $0.target.midX < $1.target.midX }) {
                if let last = members.last, tip.target.minX-last.target.maxX > 60 { close() }
                members.append(tip)
            }
            close()
        }
        /// Where the line of a control still to come runs on the side it asks for: 120 pt, or for a
        /// control in the same group as far as `bubble` if that is farther (its own bubble will
        /// stack beyond it).
        func lane(_ other: Tip, near tip: Tip, for bubble: CGRect) -> CGRect {
            let target = other.target, above = other.placement == .above
            let reach = max(120,group[other.id] == group[tip.id] ? above ? target.minY-bubble.minY : bubble.maxY-target.maxY : 0)
            return CGRect(x:target.minX,y:above ? target.minY-reach : target.maxY,width:target.width,height:reach)
        }
        /// Whether a control keeps a way out along `lane`, `extra` added: some part of it from
        /// which a line runs clear of bubbles and other controls.
        func wayOut(_ other: Tip, along lane: CGRect, adding extra: CGRect?) -> Bool {
            let target = other.target
            let blocking = (placed.map(\.bubble)+(extra.map { [$0] } ?? [])).filter { $0.intersects(lane) }.map { $0.insetBy(dx:-3,dy:0) }
                + controls.filter { $0.id != other.id && $0.target.intersects(lane) }.map { $0.target.insetBy(dx:-2,dy:0) }
            let inset = min(3,target.width/2)
            return stride(from:target.minX+inset,through:target.maxX-inset,by:1).contains { x in !blocking.contains { x > $0.minX && x < $0.maxX } }
        }
        /// The spot for `tip` with `later` still to come, and how much it gave up (0: nothing).
        func place(_ tip: Tip, before later: [Tip]) -> (Placed,Int) {
            let measured = measure(tip), target = tip.target, preferAbove = tip.placement == .above
            let inset = (x:min(3,target.width/2),y:min(3,target.height/2))
            // Where a way between the bubbles and controls about opens: just past their edges.
            let obstacles = placed.map(\.bubble)+controls.filter { $0.id != tip.id }.map(\.target)
            let edges = (x:obstacles.flatMap { [$0.minX-3,$0.maxX+3] },y:obstacles.flatMap { [$0.minY-3,$0.maxY+3] })
            /// Where along `low...high` the line may meet the control: the middle first, then the
            /// edges nearest to it.
            func positions(_ middle: CGFloat, _ low: CGFloat, _ high: CGFloat, _ edges: [CGFloat]) -> [CGFloat] {
                guard low <= high else { return [] }
                let middle = min(max(middle,low),high)
                return [middle]+Set(edges+[low,high]).filter { $0 >= low && $0 <= high && $0 != middle }.sorted { abs($0-middle) < abs($1-middle) }
            }
            /// The first spot, nearest first, that `fits`.
            func search(_ fits: (CGRect,CGRect) -> Bool) -> Placed? {
                for above in [preferAbove,!preferAbove] {
                    for step in 0..<60 {
                        let gap = 12+CGFloat(step)*6
                        let y = above ? target.minY-gap-measured.height : target.maxY+gap
                        guard y >= bounds.minY, y+measured.height <= bounds.maxY else { break }
                        // The bubble is centred on its line, or leans left or right of it.
                        for x in positions(target.midX,target.minX+inset.x,target.maxX-inset.x,edges.x) {
                            for left in [x-measured.width/2,x+6-measured.width,x-6] {
                                let bubble = CGRect(x:min(max(left,bounds.minX),bounds.maxX-measured.width),y:y,width:measured.width,height:measured.height)
                                guard x >= bubble.minX+6, x <= bubble.maxX-6 else { continue }
                                let line = pointer(from:bubble,to:target,at:x)
                                if fits(bubble,line) { return Placed(tip:tip,bubble:bubble,pointer:line) }
                            }
                        }
                    }
                }
                // Beside it, right then left, level with it.
                for right in [true,false] {
                    for step in 0..<10 {
                        let gap = 12+CGFloat(step)*6
                        let y = min(max(target.midY-measured.height/2,bounds.minY),bounds.maxY-measured.height)
                        let bubble = CGRect(x:right ? target.maxX+gap : target.minX-gap-measured.width,y:y,width:measured.width,height:measured.height)
                        guard bounds.contains(bubble) else { break }
                        for y in positions(target.midY,max(target.minY+inset.y,bubble.minY+4),min(target.maxY-inset.y,bubble.maxY-4),edges.y) {
                            let line = pointer(from:bubble,to:target,at:y)
                            if fits(bubble,line) { return Placed(tip:tip,bubble:bubble,pointer:line) }
                        }
                    }
                }
                return nil
            }
            let offControls = { (line: CGRect) in !controls.contains { $0.id != tip.id && $0.target.insetBy(dx:-2,dy:-2).intersects(line) } }
            /// Takes no way out that a control still to come had.
            let leavesWays = { (bubble: CGRect) in
                later.allSatisfy { other in
                    let lane = lane(other,near:tip,for:bubble)
                    return !bubble.intersects(lane) || wayOut(other,along:lane,adding:bubble) || !wayOut(other,along:lane,adding:nil)
                }
            }
            if let spot = search({ clear($0,$1,of:tip) && offControls($1) && leavesWays($0) }) { return (spot,0) }
            if let spot = search({ clear($0,$1,of:tip) && leavesWays($0) }) { return (spot,1) }
            if let spot = search({ clear($0,$1,of:tip) }) { return (spot,2) }
            if let spot = search({ clear($0,$1,of:tip,lines:false) }) { return (spot,5) }
            // Nowhere clear: next to the control, as asked.
            let y = preferAbove ? target.minY-12-measured.height : target.maxY+12
            let bubble = CGRect(x:min(max(target.midX-measured.width/2,bounds.minX),bounds.maxX-measured.width),y:y,width:measured.width,height:measured.height)
            return (Placed(tip:tip,bubble:bubble,pointer:pointer(from:bubble,to:target,at:min(max(target.midX,bubble.minX+6),bubble.maxX-6))),20)
        }
        // Where a group leaves a bubble short, it is placed again with that control first, as it
        // has the fewest ways to go, and the better layout of the group is kept.
        for (index,members) in groups.enumerated() {
            let after = groups[(index+1)...].flatMap { $0 }, before = placed
            var order = members, best: (placed: [Placed],cost: Int)?
            for _ in 0..<min(members.count,4) {
                var cost = 0, short: Tip?
                for (position,tip) in order.enumerated() {
                    let (spot,given) = place(tip,before:Array(order[(position+1)...])+after)
                    placed.append(spot); cost += given
                    if given > 0, short == nil { short = tip }
                }
                if cost < best?.cost ?? .max { best = (placed,cost) }
                guard let short, short.id != order[0].id else { break }
                placed = before; order = [short]+order.filter { $0.id != short.id }
            }
            placed = best?.placed ?? placed
        }
        return placed
    }
}
