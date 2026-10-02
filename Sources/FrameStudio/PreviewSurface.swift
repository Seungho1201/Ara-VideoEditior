import SwiftUI
import AppKit
import AVKit
import Combine
import FrameCore

struct PreviewSurface: NSViewRepresentable {
    @ObservedObject var store: EditorStore
    func makeNSView(context: Context) -> PreviewEditorView { PreviewEditorView(store:store) }
    func updateNSView(_ view: PreviewEditorView, context: Context) {
        view.overlay.refresh()
        // Placing the alignment point from the inspector: Return and Esc come here, as after a click.
        if view.overlay.focusRequest != store.previewFocusRequest {
            view.overlay.focusRequest = store.previewFocusRequest; view.window?.makeFirstResponder(view.overlay)
        }
    }
    static func dismantleNSView(_ view: PreviewEditorView, coordinator: ()) { view.overlay.finishDrag(); view.chrome.removeFromSuperview() }
}

@MainActor final class PreviewEditorView: NSView {
    let playerView = AVPlayerView()
    /// The last frame, over the player while a rebuilt item comes up (`EditorStore.heldFrame`).
    let held = HeldFrameView()
    let overlay: PreviewTransformOverlay
    let chrome = TransformChromeView(frame:.zero)
    private var playheadWatch: AnyCancellable?
    private var heldWatch: AnyCancellable?
    private var buildWatch: AnyCancellable?
    private var colourWatch: AnyCancellable?
    init(store: EditorStore) {
        overlay = PreviewTransformOverlay(store:store)
        super.init(frame:.zero)
        chrome.overlay = overlay; overlay.chrome = chrome
        clipsToBounds = true
        playerView.controlsStyle = .none; playerView.videoGravity = .resizeAspect; playerView.player = store.player
        playerView.allowsVideoFrameAnalysis = false
        addSubview(playerView); addSubview(held); addSubview(overlay)
        heldWatch = store.heldFrame.sink { [weak self] frame in MainActor.assumeIsolated { self?.held.show(frame) } }
        // Colours chosen in Settings show at once (after the change: the publisher tells before it).
        colourWatch = PreviewChromeColors.shared.objectWillChange.receive(on:DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.chrome.needsDisplay = true }
        }
        // A build ending no longer redraws the editor: the outline, which waits for the new player
        // item's pictures, looks again here (after the change; `$active` tells before it).
        buildWatch = store.building.$active.dropFirst().filter { !$0 }.receive(on:DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.overlay.refresh() }
        }
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
    override func layout() { super.layout(); playerView.frame = bounds; held.frame = bounds; overlay.frame = bounds; overlay.needsDisplay = true; chrome.needsDisplay = true }
    private var windowObserver: NSObjectProtocol?
    private var layerObserver: NSObjectProtocol?
    private var lastWindowRect = CGRect.null
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in [windowObserver,layerObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        windowObserver = nil; layerObserver = nil
        guard let window else { chrome.removeFromSuperview(); return }
        installChrome()
        // The viewer can move without resizing (a split divider, a window resize that re-centres it);
        // layout() does not run then, so compare its window-space rect after each event.
        windowObserver = NotificationCenter.default.addObserver(forName:NSWindow.didUpdateNotification,object:window,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followWindowPosition() }
        }
        // The editor's chrome layer can reach the window after the viewer does.
        layerObserver = NotificationCenter.default.addObserver(forName:TransformChromeLayerView.didMoveToWindow,object:window,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.installChrome() }
        }
    }
    /// The chrome goes into the editor's chrome layer. A plain AppKit window (the tests') takes it
    /// on its content view; SwiftUI's hosting view never does, as SwiftUI would not draw it there.
    private func installChrome() {
        guard let window else { return }
        if let layer = TransformChromeLayerView.layer(in:window) { chrome.install(in:layer) }
        else if let content = window.contentView, window.contentViewController == nil,
                !NSStringFromClass(type(of:content)).contains("Hosting") { chrome.install(in:content) }
        else { return }
        chrome.isHidden = !overlay.showsChrome
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
        /// Stretching from the middle of this edge (`VisualGeometry.edgeMiddles`).
        var edge: Int? = nil
        var rotating = false
        /// Placing the alignment point rather than moving the clip.
        var anchoring = false
        /// The lines a move lines up with (`VisualGeometry.alignmentLines`).
        var lines: (vertical: [CGFloat], horizontal: [CGFloat]) = ([],[])
        /// The lines its edges catch on (`VisualGeometry.edgeLines`).
        var edges: (vertical: [CGFloat], horizontal: [CGFloat]) = ([],[])
    }
    private var drag: Drag?
    private var anchorFeedback = CatchFeedback<Int>()
    /// The centre guides a move is on right now (x of a vertical line, y of a horizontal one).
    private(set) var guides: (vertical: CGFloat?, horizontal: CGFloat?) = (nil,nil)
    private var verticalFeedback = CatchFeedback<CGFloat>(), horizontalFeedback = CatchFeedback<CGFloat>()
    /// A stretch coming back to the picture's own proportions.
    private var proportionFeedback = CatchFeedback<Bool>()
    /// A stretch on the picture's own proportions right now: its outline is drawn in that colour.
    private(set) var proportional = false
    /// Kept at the AppKit boundary so tests can capture cues without vibrating hardware.
    var performHaptic: (NSHapticFeedbackManager.FeedbackPattern) -> Void = { pattern in
        NSHapticFeedbackManager.defaultPerformer.perform(pattern,performanceTime:.now)
    }
    /// The chrome's colours, as chosen in Settings ▸ Preview.
    static var guideColor: NSColor { PreviewChromeColors.shared.nsColor(.guide) }
    static var centreColor: NSColor { PreviewChromeColors.shared.nsColor(.point) }
    static var outlineColor: NSColor { PreviewChromeColors.shared.nsColor(.outline) }
    static var proportionColor: NSColor { PreviewChromeColors.shared.nsColor(.proportion) }
    /// The outline's and handles' colour now: green while a stretch sits on its own proportions.
    var frameColor: NSColor { proportional ? Self.proportionColor : Self.outlineColor }
    /// How solid the centre is drawn while transforming (30% less than whole).
    static let centreOpacity: CGFloat = 0.7
    /// Points a moving clip's alignment point can line up with: the frame's centre, and the
    /// alignment point of every other clip showing now (its linked partner aside).
    /// How near a move's alignment point catches a line, in points of the preview.
    static let alignmentReach: CGFloat = 5
    /// The frame's edges and middle and the boxes of the other clips showing, for edges to catch.
    private func edgeLines(excluding clip: Clip, in canvas: CGRect) -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        guard let store else { return ([],[]) }
        let own = Set(store.project.group(for:clip.id).map(\.id))
        let others = store.project.clips.filter { other in
            other.lane.isVideo && !own.contains(other.id) && other.style.opacity > 0 && store.playhead >= other.start && store.playhead < other.end
        }.compactMap { geometry(for:$0)?.bounds }
        return VisualGeometry.edgeLines(frame:canvas.size,others:others,reach:Self.alignmentReach)
    }
    private func alignmentLines(excluding clip: Clip, in canvas: CGRect) -> (vertical: [CGFloat], horizontal: [CGFloat]) {
        guard let store else { return ([],[]) }
        let own = Set(store.project.group(for:clip.id).map(\.id)), size = canvas.size
        let others = store.project.clips.filter { other in
            other.lane.isVideo && !own.contains(other.id) && other.style.opacity > 0 && store.playhead >= other.start && store.playhead < other.end
        }.map { geometry(for:$0)?.anchor ?? CGPoint(x:size.width*(0.5+$0.style.x),y:size.height*(0.5+$0.style.y)) }
        return VisualGeometry.alignmentLines(middle:CGPoint(x:size.width/2,y:size.height/2),others:others,reach:Self.alignmentReach)
    }
    weak var chrome: TransformChromeView?
    private let ghost = TransformGhost()
    /// Share of the clip left visible outside the canvas while transforming (70 % transparent).
    static let offCanvasOpacity = 0.3
    private var zoomOrigin: Clip?
    private var zoomEndTask: Task<Void,Never>?
    /// The store's focus request last acted on; taken from the store when made, so a preview
    /// that appears later does not take the keys for an old one.
    var focusRequest: Int
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(store: EditorStore) {
        self.store = store; focusRequest = store.previewFocusRequest; super.init(frame:.zero)
        clipsToBounds = true
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized:"Preview transform canvas"))
        toolTip = String(localized:"Double-click a clip to transform it. Drag to move; corners, pinch or Option-scroll to resize; a picture's edge middles stretch it one way; the top handle rotates (Shift: 15° steps). Turning, pinch and Option-scroll go about the alignment point; move it with Adjust alignment point in the inspector. Return or Esc to finish.")
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
    /// The chrome sits above the whole window, help mode's tips included: under them it would
    /// show through the dimming and take their clicks, so it waits until they close.
    var showsChrome: Bool { isTransforming && store?.showHelp != true }
    var isDragging: Bool { drag != nil || zoomOrigin != nil }
    func refresh() {
        dropStaleGesture()
        if let drag, activeClip?.id != drag.id { finishDrag() }
        if let zoomOrigin, activeClip?.id != zoomOrigin.id { finishDrag() }
        if activeClip == nil { ghost.reset() }
        needsDisplay = true; window?.invalidateCursorRects(for:self)
        if let chrome {
            // Hidden views skip hit-testing, cursor rects and compositing: playback costs nothing.
            chrome.isHidden = !showsChrome
            if showsChrome {
                if let host = chrome.superview { chrome.install(in:host) }
                chrome.needsDisplay = true; chrome.window?.invalidateCursorRects(for:chrome)
            }
        }
        setAccessibilityValue(activeClip.map { clip in
            store?.anchorEditID == clip.id ? String(localized:"Placing the alignment point of \(clip.name). Click or drag to place it; Return or Esc to finish.")
                                           : clip.kind == .text ? String(localized:"Transforming \(clip.name). Drag to move; corner handles resize; the top handle rotates.")
                                           : String(localized:"Transforming \(clip.name). Drag to move; corner handles resize; edge handles stretch; the top handle rotates.")
        } ?? String(localized:"Double-click a visible clip to transform."))
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
        // While the alignment point is placed the knob is hidden, and takes nothing.
        let knob = store?.anchorEditID != clip.id && isOnRotationHandle(point,geometry)
        if (geometry.corners+edgeHandles(clip,geometry)).contains(where: { hypot($0.x-point.x,$0.y-point.y) <= 12 }) || geometry.isNearOutline(point) || knob { return true }
        return bounds.contains(location) && geometry.contains(point)
    }
    private static let handleRadius: CGFloat = 11
    /// The handles in the middles of the outline's edges, which stretch a picture one way. A title
    /// has none: its letters only scale.
    private func edgeHandles(_ clip: Clip, _ geometry: VisualGeometry) -> [CGPoint] { clip.kind == .text ? [] : geometry.edgeMiddles }
    /// The cursor for stretching from `edge`: across or down, whichever the turned edge is nearer.
    private static func stretchCursor(_ geometry: VisualGeometry, _ edge: Int) -> NSCursor {
        let middles = geometry.edgeMiddles, a = middles[edge], b = middles[(edge+2)%4]
        return abs(a.x-b.x) >= abs(a.y-b.y) ? .resizeLeftRight : .resizeUpDown
    }
    /// The cursor for resizing from `corner`: the double arrow along the diagonal it pulls on (the
    /// clip's own, turned with it), whichever of the four ways (two diagonals, across, down) it is nearest.
    static func cornerCursor(_ geometry: VisualGeometry, _ corner: Int) -> NSCursor {
        let corners = geometry.corners, p = corners[corner]
        func away(_ q: CGPoint) -> CGVector {
            let dx = p.x-q.x, dy = p.y-q.y, length = hypot(dx,dy)
            return length > 0 ? CGVector(dx:dx/length,dy:dy/length) : .zero
        }
        let a = away(corners[(corner+1)%4]), b = away(corners[(corner+3)%4])
        switch Int((atan2(a.dy+b.dy,a.dx+b.dx)/(.pi/4)).rounded()) & 3 {   // y down
        case 0: return .resizeLeftRight
        case 2: return .resizeUpDown
        case 1: return .frameResize(position:.bottomRight,directions:.all)  // ↖ ↘
        default: return .frameResize(position:.topRight,directions:.all)    // ↙ ↗
        }
    }
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
    /// A knob with nowhere allowed to go (a clip far bigger than the frame) is not shown, nor
    /// while an edge stretches the clip.
    private func showsRotationHandle(_ geometry: VisualGeometry) -> Bool {
        !isStretching && rotationHandleArea.contains(rotationHandle(geometry).knob)
    }
    /// An edge's middle is being dragged.
    var isStretching: Bool { drag?.edge != nil }
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
        frameColor.setStroke(); outline.lineWidth = 1.5; outline.stroke()
        for point in points {
            let handle = NSBezierPath(roundedRect:CGRect(x:point.x-5,y:point.y-5,width:10,height:10),xRadius:2,yRadius:2)
            frameColor.setFill(); handle.fill(); NSColor.black.withAlphaComponent(0.65).setStroke(); handle.lineWidth = 1; handle.stroke()
        }
        // The stretch handles, rounder than the corners', which scale.
        if let clip = activeClip {
            for middle in edgeHandles(clip,geometry) {
                let point = chrome.convert(CGPoint(x:middle.x+canvas.minX,y:middle.y+canvas.minY),from:self)
                let handle = NSBezierPath(ovalIn:CGRect(x:point.x-4.5,y:point.y-4.5,width:9,height:9))
                frameColor.setFill(); handle.fill(); NSColor.black.withAlphaComponent(0.65).setStroke(); handle.lineWidth = 1; handle.stroke()
            }
        }
        // 4. The centre, as a red crosshair in a ring: yellow while it sits on a guide.
        let placing = store.anchorEditID == clip.id
        if placing {
            // The places the point catches on: the centre, the corners and the edge middles.
            for stop in VisualGeometry.anchorStops {
                let p = geometry.point(atShare:stop), q = chrome.convert(CGPoint(x:p.x+canvas.minX,y:p.y+canvas.minY),from:self)
                let dot = NSBezierPath(ovalIn:CGRect(x:q.x-3,y:q.y-3,width:6,height:6))
                NSColor.black.withAlphaComponent(0.6).setStroke(); dot.lineWidth = 3; dot.stroke()
                NSColor.white.setStroke(); dot.lineWidth = 1.2; dot.stroke()
            }
        }
        let anchor = geometry.anchor
        let middle = chrome.convert(CGPoint(x:anchor.x+canvas.minX,y:anchor.y+canvas.minY),from:self)
        let cross = NSBezierPath(), arm: CGFloat = placing ? 12 : 9, radius: CGFloat = placing ? 7 : 5
        cross.move(to:CGPoint(x:middle.x-arm,y:middle.y)); cross.line(to:CGPoint(x:middle.x+arm,y:middle.y))
        cross.move(to:CGPoint(x:middle.x,y:middle.y-arm)); cross.line(to:CGPoint(x:middle.x,y:middle.y+arm))
        cross.appendOval(in:CGRect(x:middle.x-radius,y:middle.y-radius,width:2*radius,height:2*radius))
        // Toned down so it does not cover the picture it sits on; whole while it is being placed.
        // One layer, so its dark edge and colour fade together rather than showing through each other.
        let layer = NSGraphicsContext.current?.cgContext
        layer?.saveGState(); layer?.setAlpha(placing ? 1 : Self.centreOpacity); layer?.beginTransparencyLayer(auxiliaryInfo:nil)
        NSColor.black.withAlphaComponent(0.6).setStroke(); cross.lineWidth = 3.5; cross.stroke()
        (guides.vertical != nil || guides.horizontal != nil ? Self.guideColor : Self.centreColor).setStroke(); cross.lineWidth = 1.5; cross.stroke()
        layer?.endTransparencyLayer(); layer?.restoreGState()
        // 5. The rotation handle: a stem from the middle of the top edge to a round knob.
        guard !placing, showsRotationHandle(geometry) else { return }
        let rotation = rotationHandle(geometry)
        let edge = chrome.convert(CGPoint(x:rotation.edge.x+canvas.minX,y:rotation.edge.y+canvas.minY),from:self)
        let knob = chrome.convert(CGPoint(x:rotation.knob.x+canvas.minX,y:rotation.knob.y+canvas.minY),from:self)
        let stem = NSBezierPath(); stem.move(to:edge); stem.line(to:knob)
        NSColor.black.withAlphaComponent(0.6).setStroke(); stem.lineWidth = 3.5; stem.stroke()
        frameColor.setStroke(); stem.lineWidth = 1.5; stem.stroke()
        let r: CGFloat = 8, disc = NSBezierPath(ovalIn:CGRect(x:knob.x-r,y:knob.y-r,width:2*r,height:2*r))
        frameColor.setFill(); disc.fill(); NSColor.black.withAlphaComponent(0.65).setStroke(); disc.lineWidth = 1; disc.stroke()
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
        // Placing the alignment point, a click anywhere the chrome takes one puts it there: the
        // crosshair only, as the viewer under it shows, and no knob.
        let placing = store?.anchorEditID == clip.id, hand: NSCursor = placing ? .crosshair : .openHand
        let points = geometry.corners.map { chrome.convert(CGPoint(x:$0.x+canvas.minX,y:$0.y+canvas.minY),from:self) }
        let xs = points.map(\.x), ys = points.map(\.y)
        let viewer = chrome.convert(bounds,from:self)
        let body = CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!).intersection(viewer)
        if !body.isEmpty { chrome.addCursorRect(body,cursor:hand) }
        for i in 0..<4 {                                            // the outline band, sampled along each edge
            let a = points[i], b = points[(i+1)%4], steps = max(1,Int(hypot(b.x-a.x,b.y-a.y)/8))
            for k in 0...steps {
                let t = CGFloat(k)/CGFloat(steps), q = CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)
                let rect = CGRect(x:q.x-6,y:q.y-6,width:12,height:12).intersection(chrome.bounds)
                if !rect.isEmpty { chrome.addCursorRect(rect,cursor:hand) }
            }
        }
        for (corner,p) in points.enumerated() {
            let rect = CGRect(x:p.x-9,y:p.y-9,width:18,height:18).intersection(chrome.bounds)
            if !rect.isEmpty { chrome.addCursorRect(rect,cursor:placing ? .crosshair : Self.cornerCursor(geometry,corner)) }
        }
        guard !placing else { return }
        for (edge,middle) in edgeHandles(clip,geometry).enumerated() {
            let p = chrome.convert(CGPoint(x:middle.x+canvas.minX,y:middle.y+canvas.minY),from:self)
            let rect = CGRect(x:p.x-9,y:p.y-9,width:18,height:18).intersection(chrome.bounds)
            if !rect.isEmpty { chrome.addCursorRect(rect,cursor:Self.stretchCursor(geometry,edge)) }
        }
        for rect in rotationCursorRects(geometry) {
            let r = chrome.convert(rect,from:self).intersection(chrome.bounds)
            if !r.isEmpty { chrome.addCursorRect(r,cursor:Self.rotateCursor) }
        }
    }
    override func resetCursorRects() {
        guard let clip = activeClip, store?.showHelp != true else { return }
        if store?.anchorEditID == clip.id { addCursorRect(bounds,cursor:.crosshair); return }
        addCursorRect(bounds,cursor:.openHand)
        if let clip = activeClip, let geometry = geometry(for:clip) {
            for (corner,p) in geometry.corners.enumerated() {
                let rect = CGRect(x:p.x+canvas.minX-9,y:p.y+canvas.minY-9,width:18,height:18).intersection(bounds)
                if !rect.isEmpty { addCursorRect(rect,cursor:Self.cornerCursor(geometry,corner)) }
            }
            for rect in rotationCursorRects(geometry) {
                let r = rect.intersection(bounds)
                if !r.isEmpty { addCursorRect(r,cursor:Self.rotateCursor) }
            }
            for (edge,middle) in edgeHandles(clip,geometry).enumerated() {
                let rect = CGRect(x:middle.x+canvas.minX-9,y:middle.y+canvas.minY-9,width:18,height:18).intersection(bounds)
                if !rect.isEmpty { addCursorRect(rect,cursor:Self.stretchCursor(geometry,edge)) }
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let store else { return }
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow,from:nil)
        let point = CGPoint(x:location.x-canvas.minX,y:location.y-canvas.minY)
        // Placing the alignment point, every click places it: a double-click neither picks another
        // clip nor ends the transform.
        let placing = activeClip.map { store.anchorEditID == $0.id } ?? false
        if event.clickCount == 2, !placing {
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
        if store.anchorEditID == clip.id {
            // Anywhere in the preview, on the clip or off it.
            finishDrag(); store.pause(); store.beginInteraction()
            drag = Drag(id:clip.id,origin:point,geometry:geometry,corner:nil,canvas:canvas,anchoring:true)
            anchorFeedback = CatchFeedback()
            placeAnchor(drag!,at:point,event:event); return
        }
        // The knob first, then a corner, then an edge's middle (a small clip brings them within
        // reach of each other), then the knob's stem: the top edge's middle is where the stem starts.
        let knob = showsRotationHandle(geometry) && { let k = rotationHandle(geometry).knob; return hypot(k.x-point.x,k.y-point.y) <= Self.handleRadius }()
        let corner = knob ? nil : geometry.corners.firstIndex { hypot($0.x-point.x,$0.y-point.y) <= 12 }
        let edge = knob || corner != nil ? nil : edgeHandles(clip,geometry).firstIndex { hypot($0.x-point.x,$0.y-point.y) <= 12 }
        let rotating = knob || (corner == nil && edge == nil && isOnRotationHandle(point,geometry))
        guard rotating || corner != nil || edge != nil || geometry.contains(point) || geometry.isNearOutline(point) else { store.previewTransformID = nil; refresh(); return }
        finishDrag(); store.pause(); store.beginInteraction()
        drag = Drag(id:clip.id,origin:point,geometry:geometry,corner:corner,canvas:canvas,edge:edge,rotating:rotating,
                    lines:alignmentLines(excluding:clip,in:canvas),edges:edgeLines(excluding:clip,in:canvas))
        verticalFeedback = CatchFeedback(); horizontalFeedback = CatchFeedback(); proportionFeedback = CatchFeedback()
        store.status = rotating ? String(localized:"Rotating clip in preview") : edge != nil ? String(localized:"Stretching clip in preview")
            : corner == nil ? String(localized:"Moving clip in preview") : String(localized:"Resizing clip in preview")
        (rotating ? Self.rotateCursor : edge.map { Self.stretchCursor(geometry,$0) } ?? corner.map { Self.cornerCursor(geometry,$0) } ?? NSCursor.closedHand).set()
        // Stretching, the rotation knob steps aside until the drag ends.
        if edge != nil { chrome?.needsDisplay = true }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag, let store, activeClip?.id == drag.id, !dropStaleGesture() else { return }
        let p = convert(event.locationInWindow,from:nil)
        let point = CGPoint(x:p.x-drag.canvas.minX,y:p.y-drag.canvas.minY)
        if drag.anchoring { placeAnchor(drag,at:point,event:event); return }
        if drag.rotating {
            // Shift turns in 15° steps; with snapping on, a right angle catches within 2°.
            // On the centre there is no angle to read: keep the one already applied.
            guard let style = drag.geometry.rotated(from:drag.origin,to:point,step:event.modifierFlags.contains(.shift) ? 15 : nil,magnet:store.snapping ? 2 : 0) else { return }
            apply(drag.id,style)
            store.status = String(format:String(localized:"Rotation %.0f°"),style.rotation)
            return
        }
        // Snapping lines things up within 5 pt, with a yellow guide and a tick: a move's alignment
        // point (or, square to the frame, its edges) with the frame's middle and edges and the other
        // clips'; a resized corner or a stretched edge with those lines too. Shift during the drag,
        // or snapping off, lets go.
        let snaps = store.snapping && !event.modifierFlags.contains(.shift)
        guides = (nil,nil); proportional = false
        var style: ClipStyle
        if let edge = drag.edge {
            if snaps {
                let caught = drag.geometry.stretched(edge:edge,to:point,catching:drag.edges,threshold:Self.alignmentReach)
                style = caught.style; guides = (caught.vertical,caught.horizontal); proportional = caught.proportional
            } else { style = drag.geometry.stretched(edge:edge,to:point) }
        } else if let corner = drag.corner {
            if snaps {
                let caught = drag.geometry.resized(corner:corner,to:point,catching:drag.edges,threshold:Self.alignmentReach)
                style = caught.style; guides = (caught.vertical,caught.horizontal)
            } else { style = drag.geometry.resized(corner:corner,to:point) }
        } else {
            style = drag.geometry.moved(by:CGSize(width:point.x-drag.origin.x,height:point.y-drag.origin.y))
            if snaps {
                let moving = VisualGeometry(sourceSize:drag.geometry.sourceSize,canvasSize:drag.geometry.canvasSize,style:style,isText:drag.geometry.isText)
                let aligned = moving.aligned(vertical:drag.lines.vertical,horizontal:drag.lines.horizontal,edges:drag.edges,threshold:Self.alignmentReach)
                style = aligned.style; guides = (aligned.vertical,aligned.horizontal)
            }
        }
        let caught = verticalFeedback.cue(for:guides.vertical,at:event.timestamp,enabled:store.haptics(.alignment))
        let caughtAcross = horizontalFeedback.cue(for:guides.horizontal,at:event.timestamp,enabled:store.haptics(.alignment))
        // Back to its own proportions while stretching: a tick too.
        let even = proportionFeedback.cue(for:proportional ? true : nil,at:event.timestamp,enabled:store.haptics(.alignment))
        if caught || caughtAcross || even { performHaptic(.alignment) }
        apply(drag.id,style)
        store.status = drag.edge != nil
            ? (proportional ? String(format:String(localized:"Width %.0f%% · Height %.0f%% · Its own proportions"),style.stretchX*100,style.stretchY*100)
                            : String(format:String(localized:"Width %.0f%% · Height %.0f%%"),style.stretchX*100,style.stretchY*100))
            : String(format:String(localized:"Position %.0f%%, %.0f%% · Scale %.0f%%"),style.x*100,style.y*100,style.scale*100)
    }
    override func mouseUp(with event: NSEvent) { finishDrag() }
    /// One step of a drag or pinch.
    private func apply(_ id: UUID, _ style: ClipStyle) {
        store?.updatePreviewTransform(id,style:style)
        needsDisplay = true; chrome?.needsDisplay = true
    }
    /// Ends a drag or pinch whose interaction something else closed (⌘Z mid-drag: what it did so
    /// far is its own undo step), without touching the project again. Other changes (media
    /// imported meanwhile) leave it going. True when there was one.
    @discardableResult private func dropStaleGesture() -> Bool {
        guard isDragging, store?.isInteracting == false else { return false }
        finishDrag(); return true
    }
    /// The alignment point at `point`, catching the centre, corners and edge middles within
    /// 8 pt (with a tick) unless snapping is off or Shift is held.
    private func placeAnchor(_ drag: Drag, at point: CGPoint, event: NSEvent) {
        guard let store else { return }
        let snaps = store.snapping && !event.modifierFlags.contains(.shift)
        let placed = drag.geometry.anchorMoved(to:point,snap:snaps ? 8 : nil)
        if anchorFeedback.cue(for:placed.stop,at:event.timestamp,enabled:store.haptics(.alignment)) { performHaptic(.alignment) }
        apply(drag.id,placed.style)
        store.status = String(format:String(localized:"Alignment point %.0f%%, %.0f%% from the centre"),placed.style.anchorX*100,placed.style.anchorY*100)
    }
    func finishDrag() {
        guard drag != nil || zoomOrigin != nil else { return }
        zoomEndTask?.cancel(); zoomEndTask = nil
        drag = nil; zoomOrigin = nil; guides = (nil,nil); proportional = false; store?.endInteraction(); window?.invalidateCursorRects(for:self)
        chrome?.needsDisplay = true; if let chrome { chrome.window?.invalidateCursorRects(for:chrome) }
    }
    override func magnify(with event: NSEvent) { scaleBy(max(0.1,1+event.magnification)) }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) { scaleBy(exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08))) }
        else { super.scrollWheel(with:event) }
    }
    private func scaleBy(_ factor: Double) {
        // A pinch the project changed under is over; one going on after it is a new undo step.
        dropStaleGesture()
        // Placing the alignment point, the pointer only places it: a pinch or ⌥-scroll resizes nothing.
        guard drag == nil, let store, !store.isBuilding, let clip = activeClip, store.anchorEditID != clip.id else { return }
        if zoomOrigin == nil { store.pause(); store.beginInteraction(); zoomOrigin = clip }
        var style = clip.style; style.scale = min(4,max(0.05,style.scale*factor))
        if let geometry = geometry(for:clip) { style = geometry.keepingAnchor(style) }     // about the alignment point
        apply(clip.id,style)
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
        // Help mode dims the editor while its tips are read: no key acts behind it, and Esc closes it.
        if store?.showHelp == true {
            if event.keyCode == 53 { store?.showHelp = false } else { super.keyDown(with:event) }
            return
        }
        // A drag the project changed under has nothing left to keep or put back.
        dropStaleGesture()
        // The fixed keys come before the shortcuts set in Settings, as in the timeline.
        if store?.anchorEditID != nil, event.keyCode == 53 || Self.isReturn(event) {
            // Esc puts back a point being dragged; either key ends placing it, not the transform.
            if event.keyCode == 53, let drag { store?.updatePreviewTransform(drag.id,style:drag.geometry.style) }
            finishDrag(); store?.anchorEditID = nil; refresh(); return
        }
        if event.keyCode == 53 {
            if store?.dragSelectArmed == true { store?.dragSelectArmed = false }
            if let drag { store?.updatePreviewTransform(drag.id,style:drag.geometry.style) }
            if let zoomOrigin { store?.updatePreviewTransform(zoomOrigin.id,style:zoomOrigin.style) }
            finishDrag(); store?.previewTransformID = nil; refresh()
        } else if Self.isReturn(event), store?.previewTransformID != nil {
            // Return (or Enter) is done: keep what is there, a drag in progress included, let go of
            // the clip and give the timeline the keys.
            finishDrag(); store?.finishTransform(); refresh()
        } else if drag == nil, store?.nudge(event) == true {
            // An arrow key moved the clip by a pixel (ten with Shift).
        } else if store?.shortcuts.command(matching:event) == .snapping {
            if !event.isARepeat { store?.snapping.toggle() }
        } else { super.keyDown(with:event) }
    }
}

/// A still of the preview's last frame, fitted as the player fits its video. It shows at once and
/// gives way to the new frame under it with a short fade, so an edit's preview simply changes.
@MainActor final class HeldFrameView: NSView {
    static let fade: CFTimeInterval = 0.12
    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer = true; layer?.contentsGravity = .resizeAspect; isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// The frame shown, kept so its buffer is not handed back to the player's pool meanwhile.
    private(set) var shown: PreviewFrame?
    func show(_ frame: PreviewFrame?) {
        guard let layer else { return }
        if let frame {
            shown = frame
            layer.removeAllAnimations(); layer.contents = frame.surface; layer.opacity = 1; isHidden = false
        } else if !isHidden, layer.opacity > 0 {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated { guard let self, self.layer?.opacity == 0 else { return }; self.isHidden = true; self.layer?.contents = nil; self.shown = nil }
            }
            let fade = CABasicAnimation(keyPath:"opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = Self.fade
            fade.timingFunction = CAMediaTimingFunction(name:.easeOut)
            layer.opacity = 0; layer.add(fade,forKey:"fade")
            CATransaction.commit()
        }
    }
}
