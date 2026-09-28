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
        var rotating = false
        /// The centres a move lines up with: the frame's and those of the other clips showing.
        var centers: [CGPoint] = []
    }
    private var drag: Drag?
    /// The centre guides a move is on right now (x of a vertical line, y of a horizontal one).
    private(set) var guides: (vertical: CGFloat?, horizontal: CGFloat?) = (nil,nil)
    private var verticalFeedback = CatchFeedback<CGFloat>(), horizontalFeedback = CatchFeedback<CGFloat>()
    /// Kept at the AppKit boundary so tests can capture cues without vibrating hardware.
    var performHaptic: (NSHapticFeedbackManager.FeedbackPattern) -> Void = { pattern in
        NSHapticFeedbackManager.defaultPerformer.perform(pattern,performanceTime:.now)
    }
    static let guideColor = NSColor.systemYellow
    /// Centres a moving clip can line up with: the frame's, and every other clip showing now
    /// (its linked partner aside).
    private func alignmentCenters(excluding clip: Clip, in canvas: CGRect) -> [CGPoint] {
        guard let store else { return [] }
        let own = Set(store.project.group(for:clip.id).map(\.id)), size = canvas.size
        var centers = [CGPoint(x:size.width/2,y:size.height/2)]
        for other in store.project.clips where other.lane.isVideo && !own.contains(other.id) && other.style.opacity > 0
            && store.playhead >= other.start && store.playhead < other.end {
            centers.append(CGPoint(x:size.width*(0.5+other.style.x),y:size.height*(0.5+other.style.y)))
        }
        return centers
    }
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
        toolTip = "Double-click to transform. Drag to move; corners, pinch or Option-scroll to resize; the top handle rotates (Shift: 15° steps). Return or Esc to finish."
        ghost.onReady = { [weak self] in self?.chrome?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var canvas: CGRect {
        let ratio = store?.project.aspectRatio.value ?? 16.0/9
        let width = min(bounds.width,bounds.height*ratio), height = min(bounds.height,bounds.width/ratio)
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
        setAccessibilityValue(activeClip.map { "Transforming \($0.name). Drag to move; corner handles resize; the top handle rotates." } ?? "Double-click a visible clip to transform.")
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
        if geometry.corners.contains(where: { hypot($0.x-point.x,$0.y-point.y) <= 12 }) || geometry.isNearOutline(point) || isOnRotationHandle(point,geometry) { return true }
        return bounds.contains(location) && geometry.contains(point)
    }
    private static let handleRadius: CGFloat = 11
    /// Where the knob may sit, in canvas space: the viewer, the PROGRAM title strip above it and
    /// the padding beside it. Not below it: the transport buttons are there, and a knob over
    /// them would take their clicks.
    private var rotationHandleArea: CGRect {
        CGRect(x:-canvas.minX-44,y:-canvas.minY-40,width:bounds.width+88,height:bounds.height+40)
    }
    /// The rotation handle for this clip, kept where it can be (in canvas space).
    private func rotationHandle(_ geometry: VisualGeometry) -> (edge: CGPoint, knob: CGPoint) {
        geometry.rotationHandle(within:rotationHandleArea)
    }
    /// A knob with nowhere allowed to go (a clip far bigger than the frame) is not shown.
    private func showsRotationHandle(_ geometry: VisualGeometry) -> Bool {
        rotationHandleArea.contains(rotationHandle(geometry).knob)
    }
    /// The active clip's rotation handle in this view's coordinates, when it shows.
    func activeRotationHandle() -> (edge: CGPoint, knob: CGPoint)? {
        guard let clip = activeClip, let geometry = geometry(for:clip), showsRotationHandle(geometry) else { return nil }
        let (edge,knob) = rotationHandle(geometry)
        return (CGPoint(x:edge.x+canvas.minX,y:edge.y+canvas.minY),CGPoint(x:knob.x+canvas.minX,y:knob.y+canvas.minY))
    }
    /// The knob, or its stem: the whole drawn handle turns the clip.
    private func isOnRotationHandle(_ point: CGPoint, _ geometry: VisualGeometry) -> Bool {
        guard showsRotationHandle(geometry) else { return false }
        let (edge,knob) = rotationHandle(geometry)
        if hypot(knob.x-point.x,knob.y-point.y) <= Self.handleRadius { return true }
        let dx = knob.x-edge.x, dy = knob.y-edge.y, length = dx*dx+dy*dy
        guard length > 0 else { return false }
        let t = max(0,min(1,((point.x-edge.x)*dx+(point.y-edge.y)*dy)/length))
        return hypot(point.x-(edge.x+t*dx),point.y-(edge.y+t*dy)) <= 5
    }
    /// Cursor rects covering what isOnRotationHandle takes: the square inside the knob's circle
    /// and small squares along the stem, clear of the outline band at its start.
    private func rotationCursorRects(_ geometry: VisualGeometry) -> [CGRect] {
        guard showsRotationHandle(geometry) else { return [] }
        let (edge,knob) = rotationHandle(geometry), inner = Self.handleRadius/2.squareRoot()
        var rects = [CGRect(x:knob.x-inner,y:knob.y-inner,width:2*inner,height:2*inner)]
        let length = hypot(knob.x-edge.x,knob.y-edge.y)
        for d in stride(from:CGFloat(8),to:length-Self.handleRadius,by:3) {
            let t = d/length, p = CGPoint(x:edge.x+(knob.x-edge.x)*t,y:edge.y+(knob.y-edge.y)*t)
            rects.append(CGRect(x:p.x-3,y:p.y-3,width:6,height:6))
        }
        return rects.map { $0.offsetBy(dx:canvas.minX,dy:canvas.minY) }  // overlay space
    }
    /// A turning-arrow pointer for the rotation handle (AppKit has none), black with a white rim.
    static let rotateCursor: NSCursor = {
        let configuration = NSImage.SymbolConfiguration(pointSize:12,weight:.heavy)
        func arrow(_ color: NSColor) -> NSImage? {
            NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:nil)?.withSymbolConfiguration(configuration.applying(.init(paletteColors:[color])))
        }
        let image = NSImage(size:NSSize(width:22,height:22),flipped:false) { rect in
            guard let rim = arrow(.white), let body = arrow(.black) else { return false }
            let box = CGRect(x:(rect.width-rim.size.width)/2,y:(rect.height-rim.size.height)/2,width:rim.size.width,height:rim.size.height)
            for dx in [-1.5,0,1.5] { for dy in [-1.5,0,1.5] where dx != 0 || dy != 0 { rim.draw(in:box.offsetBy(dx:dx,dy:dy)) } }
            body.draw(in:box); return true
        }
        return NSCursor(image:image,hotSpot:NSPoint(x:11,y:11))
    }()
    private static let rotateGlyph = NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"Rotate")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:9,weight:.bold).applying(.init(paletteColors:[.black])))
    func drawChrome(in chrome: NSView) {
        guard let store, let clip = activeClip, let geometry = geometry(for:clip),
              let context = NSGraphicsContext.current?.cgContext else { return }
        let area = chrome.convert(canvas,from:self)
        // 1. The part of the clip outside the canvas, at reduced opacity, placed by the renderer's own transform.
        let time = clip.sourceStart + (store.playhead - clip.start).scaled(by:clip.speed)
        // A title's outline and shadow reach past its box; the ghost is kept per drawn size, so one
        // made before an effect changed is never drawn stretched into the new one.
        let margin = store.previewSourceMargin(for:clip)
        let drawn = CGRect(origin:.zero,size:geometry.sourceSize).insetBy(dx:-margin,dy:-margin)
        if let picture = ghost.image(for:clip,sourceTime:time,sourceSize:drawn.size,store:store) {
            context.saveGState()
            let outside = CGMutablePath(); outside.addRect(chrome.bounds); outside.addRect(area)
            context.addPath(outside); context.clip(using:.evenOdd)
            context.setAlpha(Self.offCanvasOpacity * clip.style.opacity)
            context.interpolationQuality = .high
            context.translateBy(x:area.minX,y:area.maxY); context.scaleBy(x:1,y:-1)   // canvas space, y up
            context.concatenate(geometry.renderTransform)
            context.draw(picture,in:drawn)
            context.restoreGState()
        }
        // 2. Centre guides a move has lined up on, across the frame.
        if guides.vertical != nil || guides.horizontal != nil {
            Self.guideColor.setStroke()
            if let x = guides.vertical {
                let top = chrome.convert(CGPoint(x:canvas.minX+x,y:canvas.minY),from:self), bottom = chrome.convert(CGPoint(x:canvas.minX+x,y:canvas.maxY),from:self)
                let line = NSBezierPath(); line.move(to:top); line.line(to:bottom); line.lineWidth = 1; line.stroke()
            }
            if let y = guides.horizontal {
                let left = chrome.convert(CGPoint(x:canvas.minX,y:canvas.minY+y),from:self), right = chrome.convert(CGPoint(x:canvas.maxX,y:canvas.minY+y),from:self)
                let line = NSBezierPath(); line.move(to:left); line.line(to:right); line.lineWidth = 1; line.stroke()
            }
        }
        // 3. Outline and handles on top of everything.
        let points = geometry.corners.map { chrome.convert(CGPoint(x:$0.x+canvas.minX,y:$0.y+canvas.minY),from:self) }
        let outline = NSBezierPath(); outline.move(to:points[0]); points.dropFirst().forEach { outline.line(to:$0) }; outline.close()
        NSColor.black.withAlphaComponent(0.6).setStroke(); outline.lineWidth = 3.5; outline.stroke()
        Theme.accentNS.setStroke(); outline.lineWidth = 1.5; outline.stroke()
        for point in points {
            let handle = NSBezierPath(roundedRect:CGRect(x:point.x-5,y:point.y-5,width:10,height:10),xRadius:2,yRadius:2)
            Theme.accentNS.setFill(); handle.fill(); NSColor.black.withAlphaComponent(0.65).setStroke(); handle.lineWidth = 1; handle.stroke()
        }
        // 4. The centre, as a small cross: yellow while it sits on a guide.
        let middle = chrome.convert(CGPoint(x:geometry.center.x+canvas.minX,y:geometry.center.y+canvas.minY),from:self)
        let cross = NSBezierPath(), arm: CGFloat = 7
        cross.move(to:CGPoint(x:middle.x-arm,y:middle.y)); cross.line(to:CGPoint(x:middle.x+arm,y:middle.y))
        cross.move(to:CGPoint(x:middle.x,y:middle.y-arm)); cross.line(to:CGPoint(x:middle.x,y:middle.y+arm))
        NSColor.black.withAlphaComponent(0.6).setStroke(); cross.lineWidth = 3.5; cross.stroke()
        (guides.vertical != nil || guides.horizontal != nil ? Self.guideColor : Theme.accentNS).setStroke(); cross.lineWidth = 1.5; cross.stroke()
        // 5. The rotation handle: a stem from the middle of the top edge to a round knob.
        guard showsRotationHandle(geometry) else { return }
        let rotation = rotationHandle(geometry)
        let edge = chrome.convert(CGPoint(x:rotation.edge.x+canvas.minX,y:rotation.edge.y+canvas.minY),from:self)
        let knob = chrome.convert(CGPoint(x:rotation.knob.x+canvas.minX,y:rotation.knob.y+canvas.minY),from:self)
        let stem = NSBezierPath(); stem.move(to:edge); stem.line(to:knob)
        NSColor.black.withAlphaComponent(0.6).setStroke(); stem.lineWidth = 3.5; stem.stroke()
        Theme.accentNS.setStroke(); stem.lineWidth = 1.5; stem.stroke()
        let r: CGFloat = 8, disc = NSBezierPath(ovalIn:CGRect(x:knob.x-r,y:knob.y-r,width:2*r,height:2*r))
        Theme.accentNS.setFill(); disc.fill(); NSColor.black.withAlphaComponent(0.65).setStroke(); disc.lineWidth = 1; disc.stroke()
        if let glyph = Self.rotateGlyph {
            let size = glyph.size
            glyph.draw(in:CGRect(x:knob.x-size.width/2,y:knob.y-size.height/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        }
        // While turning, the angle just past the knob, away from the stem and the clip.
        if drag?.rotating == true {
            let label = NSAttributedString(string:String(format:"%.0f°",clip.style.rotation),attributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:11,weight:.semibold),.foregroundColor:NSColor.white])
            let size = label.size(), pill = CGSize(width:size.width+10,height:size.height+4)
            let length = max(1,hypot(knob.x-edge.x,knob.y-edge.y)), out = CGPoint(x:(knob.x-edge.x)/length,y:(knob.y-edge.y)/length)
            // Far enough along the stem's direction that the pill's nearest corner clears the knob.
            let reach = r+4+abs(out.x)*pill.width/2+abs(out.y)*pill.height/2
            var box = CGRect(x:knob.x+out.x*reach-pill.width/2,y:knob.y+out.y*reach-pill.height/2,width:pill.width,height:pill.height)
            box.origin.x = min(max(box.minX,chrome.bounds.minX+2),chrome.bounds.maxX-box.width-2)
            box.origin.y = min(max(box.minY,chrome.bounds.minY+2),chrome.bounds.maxY-box.height-2)
            NSColor.black.withAlphaComponent(0.7).setFill(); NSBezierPath(roundedRect:box,xRadius:5,yRadius:5).fill()
            label.draw(at:CGPoint(x:box.minX+5,y:box.minY+2))
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
        for rect in rotationCursorRects(geometry) {
            let r = chrome.convert(rect,from:self).intersection(chrome.bounds)
            if !r.isEmpty { chrome.addCursorRect(r,cursor:Self.rotateCursor) }
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
            for rect in rotationCursorRects(geometry) {
                let r = rect.intersection(bounds)
                if !r.isEmpty { addCursorRect(r,cursor:Self.rotateCursor) }
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let store else { return }
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow,from:nil)
        let point = CGPoint(x:location.x-canvas.minX,y:location.y-canvas.minY)
        if event.clickCount == 2 {
            // The knob lies outside the clip: a double-click there must not end the transform.
            if let clip = activeClip, let geometry = geometry(for:clip), isOnRotationHandle(point,geometry) { return }
            finishDrag(); store.pause()
            let clips = store.project.clips.filter { $0.lane.isVideo && $0.style.opacity > 0 && store.playhead >= $0.start && store.playhead < $0.end }
                .sorted { $0.lane.number > $1.lane.number }          // the topmost track first
            if let clip = clips.first(where: { geometry(for:$0)?.contains(point) == true }),
               canvas.contains(location) || clip.id == store.previewTransformID {
                store.selectedClipID = clip.id; store.selectedGap = nil; store.previewTransformID = clip.id
                store.status = String(localized:"Drag to move · Corners / pinch / ⌥ scroll to resize · Top handle to rotate · Return or Esc to finish")
            } else { store.previewTransformID = nil }
            refresh(); return
        }
        guard let clip = activeClip, let geometry = geometry(for:clip), !store.isBuilding else { return }
        let rotating = isOnRotationHandle(point,geometry)
        let corner = rotating ? nil : geometry.corners.firstIndex { hypot($0.x-point.x,$0.y-point.y) <= 12 }
        guard rotating || corner != nil || geometry.contains(point) || geometry.isNearOutline(point) else { store.previewTransformID = nil; refresh(); return }
        finishDrag(); store.pause(); store.beginInteraction()
        drag = Drag(id:clip.id,origin:point,geometry:geometry,corner:corner,canvas:canvas,rotating:rotating,
                    centers:alignmentCenters(excluding:clip,in:canvas))
        verticalFeedback = CatchFeedback(); horizontalFeedback = CatchFeedback()
        store.status = rotating ? String(localized:"Rotating clip in preview") : corner == nil ? String(localized:"Moving clip in preview") : String(localized:"Resizing clip in preview")
        (rotating ? Self.rotateCursor : NSCursor.closedHand).set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag, let store, activeClip?.id == drag.id else { return }
        let p = convert(event.locationInWindow,from:nil)
        let point = CGPoint(x:p.x-drag.canvas.minX,y:p.y-drag.canvas.minY)
        if drag.rotating {
            // Shift turns in 15° steps; with snapping on, a right angle catches within 2°.
            // On the centre there is no angle to read: keep the one already applied.
            guard let style = drag.geometry.rotated(from:drag.origin,to:point,step:event.modifierFlags.contains(.shift) ? 15 : nil,magnet:store.snapping ? 2 : 0) else { return }
            store.updatePreviewTransform(drag.id,style:style); needsDisplay = true; chrome?.needsDisplay = true
            store.status = String(format:String(localized:"Rotation %.0f°"),style.rotation)
            return
        }
        var style = drag.corner.map { drag.geometry.resized(corner:$0,to:point) }
            ?? drag.geometry.moved(by:CGSize(width:point.x-drag.origin.x,height:point.y-drag.origin.y))
        guides = (nil,nil)
        // A move lines the clip's centre up with the frame's or another clip's, within 5 pt: a
        // yellow guide shows it, and a tick is felt. Shift during the drag, or snapping off, lets go.
        if drag.corner == nil, store.snapping, !event.modifierFlags.contains(.shift) {
            let moving = VisualGeometry(sourceSize:drag.geometry.sourceSize,canvasSize:drag.geometry.canvasSize,style:style,isText:drag.geometry.isText)
            let aligned = moving.aligned(to:drag.centers,threshold:5)
            style = aligned.style; guides = (aligned.vertical,aligned.horizontal)
        }
        let caught = verticalFeedback.cue(for:guides.vertical,at:event.timestamp,enabled:store.haptics(.alignment))
        let caughtAcross = horizontalFeedback.cue(for:guides.horizontal,at:event.timestamp,enabled:store.haptics(.alignment))
        if caught || caughtAcross { performHaptic(.alignment) }
        store.updatePreviewTransform(drag.id,style:style); needsDisplay = true; chrome?.needsDisplay = true
        store.status = String(format:String(localized:"Position %.0f%%, %.0f%% · Scale %.0f%%"),style.x*100,style.y*100,style.scale*100)
    }
    override func mouseUp(with event: NSEvent) { finishDrag() }
    func finishDrag() {
        guard drag != nil || zoomOrigin != nil else { return }
        zoomEndTask?.cancel(); zoomEndTask = nil
        drag = nil; zoomOrigin = nil; guides = (nil,nil); store?.endInteraction(); window?.invalidateCursorRects(for:self)
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
    /// Return or the keypad's Enter, with no modifier.
    static func isReturn(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.intersection([.command,.shift,.option,.control]).isEmpty
    }
    override func keyDown(with event: NSEvent) {
        if ShortcutSettings.shared.command(matching:event) == .snapping { if !event.isARepeat { store?.snapping.toggle() }; return }
        if event.keyCode == 53 {
            if store?.dragSelectArmed == true { store?.dragSelectArmed = false }
            if let drag { store?.updatePreviewTransform(drag.id,style:drag.geometry.style) }
            if let zoomOrigin { store?.updatePreviewTransform(zoomOrigin.id,style:zoomOrigin.style) }
            finishDrag(); store?.previewTransformID = nil; refresh()
        } else if Self.isReturn(event), store?.previewTransformID != nil {
            // Return (or Enter) is done: keep what is there, a drag in progress included.
            finishDrag(); store?.previewTransformID = nil; refresh()
        } else { super.keyDown(with:event) }
    }
}
