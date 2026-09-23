import SwiftUI
import AppKit
import AVKit
import FrameCore

struct PreviewSurface: NSViewRepresentable {
    @ObservedObject var store: EditorStore
    func makeNSView(context: Context) -> PreviewEditorView { PreviewEditorView(store:store) }
    func updateNSView(_ view: PreviewEditorView, context: Context) { view.overlay.refresh() }
    static func dismantleNSView(_ view: PreviewEditorView, coordinator: ()) { view.overlay.finishDrag() }
}

@MainActor final class PreviewEditorView: NSView {
    let playerView = AVPlayerView()
    let overlay: PreviewTransformOverlay
    init(store: EditorStore) {
        overlay = PreviewTransformOverlay(store:store)
        super.init(frame:.zero)
        clipsToBounds = true
        playerView.controlsStyle = .none; playerView.videoGravity = .resizeAspect; playerView.player = store.player
        playerView.allowsVideoFrameAnalysis = false
        addSubview(playerView); addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); playerView.frame = bounds; overlay.frame = bounds; overlay.needsDisplay = true }
}

@MainActor final class PreviewTransformOverlay: NSView {
    weak var store: EditorStore?
    private struct Drag {
        let id: UUID
        let origin: CGPoint
        let geometry: VisualGeometry
        let corner: Int?
        let canvas: CGRect
    }
    private var drag: Drag?
    private var zoomOrigin: Clip?
    private var zoomEndTask: Task<Void,Never>?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(store: EditorStore) {
        self.store = store; super.init(frame:.zero)
        clipsToBounds = true
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Preview transform canvas")
        toolTip = "Double-click to transform. Drag to move; corners, pinch or Option-scroll to resize. Esc to finish."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var canvas: CGRect {
        let width = min(bounds.width,bounds.height*16/9), height = min(bounds.height,bounds.width*9/16)
        return CGRect(x:(bounds.width-width)/2,y:(bounds.height-height)/2,width:width,height:height)
    }
    private func geometry(for clip: Clip) -> VisualGeometry? {
        guard let size = store?.previewSourceSize(for:clip), size.width > 0, size.height > 0,
              canvas.width > 0, canvas.height > 0 else { return nil }
        return VisualGeometry(sourceSize:size,canvasSize:canvas.size,style:clip.style,isText:clip.kind == .text)
    }
    private var activeClip: Clip? {
        guard let store, let id = store.previewTransformID, id == store.selectedClipID, !store.isPlaying else { return nil }
        return store.project.clips.first { $0.id == id && $0.lane.isVideo && store.playhead >= $0.start && store.playhead < $0.end }
    }
    func refresh() {
        if let drag, activeClip?.id != drag.id { finishDrag() }
        if let zoomOrigin, activeClip?.id != zoomOrigin.id { finishDrag() }
        needsDisplay = true; window?.invalidateCursorRects(for:self)
        setAccessibilityValue(activeClip.map { "Transforming \($0.name). Drag to move; corner handles resize." } ?? "Double-click a visible clip to transform.")
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let clip = activeClip, let geometry = geometry(for:clip) else { return }
        let points = geometry.corners.map { CGPoint(x:$0.x+canvas.minX,y:$0.y+canvas.minY) }
        let outline = NSBezierPath(); outline.move(to:points[0]); points.dropFirst().forEach { outline.line(to:$0) }; outline.close()
        NSColor.black.withAlphaComponent(0.6).setStroke(); outline.lineWidth = 3.5; outline.stroke()
        Theme.accentNS.setStroke(); outline.lineWidth = 1.5; outline.stroke()
        for point in points {
            let rect = CGRect(x:point.x-5,y:point.y-5,width:10,height:10)
            let handle = NSBezierPath(roundedRect:rect,xRadius:2,yRadius:2)
            Theme.accentNS.setFill(); handle.fill(); NSColor.black.withAlphaComponent(0.65).setStroke(); handle.lineWidth = 1; handle.stroke()
        }
    }
    override func resetCursorRects() {
        guard activeClip != nil else { return }
        addCursorRect(bounds,cursor:.openHand)
        if let clip = activeClip, let geometry = geometry(for:clip) {
            for p in geometry.corners {
                let rect = CGRect(x:p.x+canvas.minX-9,y:p.y+canvas.minY-9,width:18,height:18).intersection(bounds)
                if !rect.isEmpty { addCursorRect(rect,cursor:.crosshair) }
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let store else { return }
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow,from:nil)
        let point = CGPoint(x:location.x-canvas.minX,y:location.y-canvas.minY)
        if event.clickCount == 2 {
            finishDrag(); store.pause()
            let clips = store.project.clips.filter { $0.lane.isVideo && $0.style.opacity > 0 && store.playhead >= $0.start && store.playhead < $0.end }
                .sorted { $0.lane == .v2 && $1.lane != .v2 }
            if canvas.contains(location), let clip = clips.first(where: { geometry(for:$0)?.contains(point) == true }) {
                store.selectedClipID = clip.id; store.selectedGap = nil; store.previewTransformID = clip.id
                store.status = "Drag to move · Corners / pinch / ⌥ scroll to resize · Esc to finish"
            } else { store.previewTransformID = nil }
            refresh(); return
        }
        guard let clip = activeClip, let geometry = geometry(for:clip), !store.isBuilding else { return }
        let corner = geometry.corners.firstIndex { hypot($0.x-point.x,$0.y-point.y) <= 12 }
        guard corner != nil || geometry.contains(point) else { store.previewTransformID = nil; refresh(); return }
        finishDrag(); store.pause(); store.beginInteraction()
        drag = Drag(id:clip.id,origin:point,geometry:geometry,corner:corner,canvas:canvas)
        store.status = corner == nil ? "Moving clip in preview" : "Resizing clip in preview"
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag, let store, activeClip?.id == drag.id else { return }
        let p = convert(event.locationInWindow,from:nil)
        let point = CGPoint(x:p.x-drag.canvas.minX,y:p.y-drag.canvas.minY)
        let style = drag.corner.map { drag.geometry.resized(corner:$0,to:point) }
            ?? drag.geometry.moved(by:CGSize(width:point.x-drag.origin.x,height:point.y-drag.origin.y))
        store.updatePreviewTransform(drag.id,style:style); needsDisplay = true
        store.status = String(format:"Position %.0f%%, %.0f%% · Scale %.0f%%",style.x*100,style.y*100,style.scale*100)
    }
    override func mouseUp(with event: NSEvent) { finishDrag() }
    func finishDrag() {
        guard drag != nil || zoomOrigin != nil else { return }
        zoomEndTask?.cancel(); zoomEndTask = nil
        drag = nil; zoomOrigin = nil; store?.endInteraction(); window?.invalidateCursorRects(for:self)
    }
    override func magnify(with event: NSEvent) { scaleBy(max(0.1,1+event.magnification)) }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) { scaleBy(exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08))) }
        else { super.scrollWheel(with:event) }
    }
    private func scaleBy(_ factor: Double) {
        guard drag == nil, let store, !store.isBuilding, let clip = activeClip else { return }
        if zoomOrigin == nil { store.pause(); store.beginInteraction(); zoomOrigin = clip }
        var style = clip.style; style.scale = min(4,max(0.05,style.scale*factor))
        store.updatePreviewTransform(clip.id,style:style)
        zoomEndTask?.cancel()
        zoomEndTask = Task { [weak self] in
            do { try await Task.sleep(for:.milliseconds(250)); self?.finishDrag() } catch {}
        }
    }
    override func resignFirstResponder() -> Bool { finishDrag(); return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if let drag { store?.updatePreviewTransform(drag.id,style:drag.geometry.style) }
            if let zoomOrigin { store?.updatePreviewTransform(zoomOrigin.id,style:zoomOrigin.style) }
            finishDrag(); store?.previewTransformID = nil; refresh()
        } else { super.keyDown(with:event) }
    }
}
