import AppKit
import SwiftUI

/// Adds initial sizing and restoration to the existing native SwiftUI split views.
/// AppKit keeps ownership of divider dragging, minimum sizes and accessibility.
struct EditorSplitSizing: NSViewRepresentable {
    enum Axis {
        case columns, rows
        var isVertical: Bool { self == .columns }
        var defaults: [CGFloat] { self == .columns ? [496,613.5,328.5] : [1,1] }
        var key: String { self == .columns ? "editor.columnFractions.v1" : "editor.rowFractions.v1" }
    }
    let axis: Axis
    func makeNSView(context: Context) -> SplitSizingProbe { SplitSizingProbe(axis:axis) }
    func updateNSView(_ view: SplitSizingProbe, context: Context) { view.scheduleAttachment() }
    static func dismantleNSView(_ view: SplitSizingProbe, coordinator: ()) { view.detach() }
}

@MainActor final class SplitSizingProbe: NSView {
    private let axis: EditorSplitSizing.Axis
    private weak var split: NSSplitView?
    private var observer: NSObjectProtocol?
    private var attachmentPending = false
    private var restoring = false

    init(axis: EditorSplitSizing.Axis) {
        self.axis = axis
        super.init(frame:.zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detach() } else { scheduleAttachment() }
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleAttachment() }
    override func layout() { super.layout(); scheduleAttachment() }

    func scheduleAttachment() {
        guard window != nil, split == nil, !attachmentPending else { return }
        attachmentPending = true
        // SwiftUI must finish inserting all the split's children before setting dividers.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attachmentPending = false
            self.attach()
        }
    }
    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil; split = nil
    }
    private func attach() {
        guard window != nil, split == nil else { return }
        var ancestor = superview
        while let view = ancestor {
            if let candidate = view as? NSSplitView, candidate.isVertical == axis.isVertical,
               candidate.arrangedSubviews.count == axis.defaults.count {
                let extent = axis.isVertical ? candidate.bounds.width : candidate.bounds.height
                guard extent > 0, candidate.arrangedSubviews.allSatisfy({ $0.frame.width > 0 && $0.frame.height > 0 }) else { return }
                split = candidate
                let saved = UserDefaults.standard.array(forKey:axis.key) as? [Double]
                let sizes = saved.flatMap { values -> [CGFloat]? in
                    guard values.count == axis.defaults.count, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
                    return values.map { CGFloat($0) }
                } ?? axis.defaults
                let usable = extent-candidate.dividerThickness*CGFloat(sizes.count-1)
                var position: CGFloat = 0
                let positions = sizes.dropLast().map { size -> CGFloat in
                    position += usable*size/sizes.reduce(0,+)
                    defer { position += candidate.dividerThickness }
                    return position
                }
                restoring = true
                // Two passes let neighbouring panes release space when restoring a narrow window.
                for _ in 0..<2 {
                    for index in positions.indices.reversed() { candidate.setPosition(positions[index],ofDividerAt:index) }
                }
                restoring = false
                observer = NotificationCenter.default.addObserver(forName:NSSplitView.didResizeSubviewsNotification,object:candidate,queue:.main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.rememberSizes() }
                }
                return
            }
            ancestor = view.superview
        }
    }
    private func rememberSizes() {
        guard !restoring, let split, split.window != nil else { return }
        let sizes = split.arrangedSubviews.map { axis.isVertical ? $0.frame.width : $0.frame.height }
        let total = sizes.reduce(0,+)
        guard total > 0, sizes.count == axis.defaults.count, sizes.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        UserDefaults.standard.set(sizes.map { Double($0/total) },forKey:axis.key)
    }
}
