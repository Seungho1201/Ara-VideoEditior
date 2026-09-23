import SwiftUI
import AppKit
import AVKit
import Combine
import FrameCore

struct PreviewSurface: NSViewRepresentable {
    @ObservedObject var store: EditorStore
    func makeNSView(context: Context) -> PreviewEditorView { PreviewEditorView(store:store) }
    func updateNSView(_ view: PreviewEditorView, context: Context) { view.overlay.refresh() }
    static func dismantleNSView(_ view: PreviewEditorView, coordinator: ()) { view.overlay.finishDrag(); view.chrome.removeFromSuperview() }
}

@MainActor final class PreviewEditorView: NSView {
    let playerView = AVPlayerView()
    let overlay: PreviewTransformOverlay
    let chrome = TransformChromeView(frame:.zero)
    private var playheadWatch: AnyCancellable?
    init(store: EditorStore) {
        overlay = PreviewTransformOverlay(store:store)
        super.init(frame:.zero)
        chrome.overlay = overlay; overlay.chrome = chrome
        clipsToBounds = true
        playerView.controlsStyle = .none; playerView.videoGravity = .resizeAspect; playerView.player = store.player
        playerView.allowsVideoFrameAnalysis = false
        addSubview(playerView); addSubview(overlay)
        // The playhead no longer re-renders the editor; the transform chrome, which shows the
        // frame under the playhead and only while it is inside the clip, follows it directly.
        playheadWatch = store.clock.moved.sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.overlay.store?.previewTransformID != nil else { return }
                self.overlay.refresh()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); playerView.frame = bounds; overlay.frame = bounds; overlay.needsDisplay = true; chrome.needsDisplay = true }
    private var windowObserver: NSObjectProtocol?
    private var lastWindowRect = CGRect.null
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
        guard let window, let host = window.contentView else { chrome.removeFromSuperview(); return }
        chrome.install(in:host); chrome.isHidden = !overlay.isTransforming
        // The viewer can move without resizing (a split divider, a window resize that re-centres it);
        // layout() does not run then, so compare its window-space rect after each event.
        windowObserver = NotificationCenter.default.addObserver(forName:NSWindow.didUpdateNotification,object:window,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followWindowPosition() }
        }
    }
    private func followWindowPosition() {
        guard overlay.isTransforming else { lastWindowRect = .null; return }
        let rect = convert(bounds,to:nil)
        guard rect != lastWindowRect else { return }
        lastWindowRect = rect; chrome.needsDisplay = true; window?.invalidateCursorRects(for:chrome)
    }
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
    weak var chrome: TransformChromeView?
    private let ghost = TransformGhost()
    /// Share of the clip left visible outside the canvas while transforming (70 % transparent).
    static let offCanvasOpacity = 0.3
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
        ghost.onReady = { [weak self] in self?.chrome?.needsDisplay = true }
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
    var isTransforming: Bool { activeClip != nil }
    var isDragging: Bool { drag != nil || zoomOrigin != nil }
    func refresh() {
        if let drag, activeClip?.id != drag.id { finishDrag() }
        if let zoomOrigin, activeClip?.id != zoomOrigin.id { finishDrag() }
        if activeClip == nil { ghost.reset() }
        needsDisplay = true; window?.invalidateCursorRects(for:self)
        if let chrome {
            // Hidden views skip hit-testing, cursor rects and compositing: playback costs nothing.
            chrome.isHidden = !isTransforming
            if isTransforming {
                if let host = chrome.superview { chrome.install(in:host) }
                chrome.needsDisplay = true; chrome.window?.invalidateCursorRects(for:chrome)
            }
        }
        setAccessibilityValue(activeClip.map { "Transforming \($0.name). Drag to move; corner handles resize." } ?? "Double-click a visible clip to transform.")
    }
    // Everything visible is drawn by the chrome above the whole window; see drawChrome(in:).
    override func draw(_ dirtyRect: NSRect) {}
    /// A point (in this view's coordinates) the chrome should take: the clip itself, including
    /// its part outside the canvas, or one of its corner handles.
    func chromeAccepts(_ location: CGPoint) -> Bool {
        guard let clip = activeClip, let geometry = geometry(for:clip) else { return false }
        let point = CGPoint(x:location.x-canvas.minX,y:location.y-canvas.minY)
        // Handles and the outline itself win everywhere, so a clip pushed off-canvas can always be
        // resized or dragged back. Its body only takes clicks inside the viewer: outside it, the
        // off-canvas part is a picture, and the transport, inspector and timeline under it keep working.
        if geometry.corners.contains(where: { hypot($0.x-point.x,$0.y-point.y) <= 12 }) || geometry.isNearOutline(point) { return true }
        return bounds.contains(location) && geometry.contains(point)
    }
    func drawChrome(in chrome: NSView) {
        guard let store, let clip = activeClip, let geometry = geometry(for:clip),
              let context = NSGraphicsContext.current?.cgContext else { return }
        let area = chrome.convert(canvas,from:self)
        // 1. The part of the clip outside the canvas, at reduced opacity, placed by the renderer's own transform.
        let time = clip.sourceStart + (store.playhead - clip.start).scaled(by:clip.speed)
        if let picture = ghost.image(for:clip,sourceTime:time,sourceSize:geometry.sourceSize,store:store) {
            context.saveGState()
            let outside = CGMutablePath(); outside.addRect(chrome.bounds); outside.addRect(area)
            context.addPath(outside); context.clip(using:.evenOdd)
            context.setAlpha(Self.offCanvasOpacity * clip.style.opacity)
            context.interpolationQuality = .high
            context.translateBy(x:area.minX,y:area.maxY); context.scaleBy(x:1,y:-1)   // canvas space, y up
            context.concatenate(geometry.renderTransform)
            context.draw(picture,in:CGRect(origin:.zero,size:geometry.sourceSize))
            context.restoreGState()
        }
        // 2. Outline and handles on top of everything.
        let points = geometry.corners.map { chrome.convert(CGPoint(x:$0.x+canvas.minX,y:$0.y+canvas.minY),from:self) }
        let outline = NSBezierPath(); outline.move(to:points[0]); points.dropFirst().forEach { outline.line(to:$0) }; outline.close()
        NSColor.black.withAlphaComponent(0.6).setStroke(); outline.lineWidth = 3.5; outline.stroke()
        Theme.accentNS.setStroke(); outline.lineWidth = 1.5; outline.stroke()
        for point in points {
            let handle = NSBezierPath(roundedRect:CGRect(x:point.x-5,y:point.y-5,width:10,height:10),xRadius:2,yRadius:2)
            Theme.accentNS.setFill(); handle.fill(); NSColor.black.withAlphaComponent(0.65).setStroke(); handle.lineWidth = 1; handle.stroke()
        }
    }
    func addChromeCursorRects(to chrome: NSView) {
        guard let clip = activeClip, let geometry = geometry(for:clip) else { return }
        let points = geometry.corners.map { chrome.convert(CGPoint(x:$0.x+canvas.minX,y:$0.y+canvas.minY),from:self) }
        let xs = points.map(\.x), ys = points.map(\.y)
        let viewer = chrome.convert(bounds,from:self)
        let body = CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!).intersection(viewer)
        if !body.isEmpty { chrome.addCursorRect(body,cursor:.openHand) }
        for i in 0..<4 {                                            // the outline band, sampled along each edge
            let a = points[i], b = points[(i+1)%4], steps = max(1,Int(hypot(b.x-a.x,b.y-a.y)/8))
            for k in 0...steps {
                let t = CGFloat(k)/CGFloat(steps), q = CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)
                let rect = CGRect(x:q.x-6,y:q.y-6,width:12,height:12).intersection(chrome.bounds)
                if !rect.isEmpty { chrome.addCursorRect(rect,cursor:.openHand) }
            }
        }
        for p in points {
            let rect = CGRect(x:p.x-9,y:p.y-9,width:18,height:18).intersection(chrome.bounds)
            if !rect.isEmpty { chrome.addCursorRect(rect,cursor:.crosshair) }
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
                .sorted { $0.lane.number > $1.lane.number }          // the topmost track first
            if let clip = clips.first(where: { geometry(for:$0)?.contains(point) == true }),
               canvas.contains(location) || clip.id == store.previewTransformID {
                store.selectedClipID = clip.id; store.selectedGap = nil; store.previewTransformID = clip.id
                store.status = "Drag to move · Corners / pinch / ⌥ scroll to resize · Esc to finish"
            } else { store.previewTransformID = nil }
            refresh(); return
        }
        guard let clip = activeClip, let geometry = geometry(for:clip), !store.isBuilding else { return }
        let corner = geometry.corners.firstIndex { hypot($0.x-point.x,$0.y-point.y) <= 12 }
        guard corner != nil || geometry.contains(point) || geometry.isNearOutline(point) else { store.previewTransformID = nil; refresh(); return }
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
        store.updatePreviewTransform(drag.id,style:style); needsDisplay = true; chrome?.needsDisplay = true
        store.status = String(format:"Position %.0f%%, %.0f%% · Scale %.0f%%",style.x*100,style.y*100,style.scale*100)
    }
    override func mouseUp(with event: NSEvent) { finishDrag() }
    func finishDrag() {
        guard drag != nil || zoomOrigin != nil else { return }
        zoomEndTask?.cancel(); zoomEndTask = nil
        drag = nil; zoomOrigin = nil; store?.endInteraction(); window?.invalidateCursorRects(for:self)
        chrome?.needsDisplay = true; if let chrome { chrome.window?.invalidateCursorRects(for:chrome) }
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
        store.updatePreviewTransform(clip.id,style:style); chrome?.needsDisplay = true
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
