import AppKit
@preconcurrency import AVFoundation
import CoreImage
import FrameCore
import FrameMedia

/// The transform outline, its handles and the off-canvas part of the clip being transformed,
/// drawn above the whole window: over the panels and the timeline, never clipped by the viewer.
///
/// It sits as the topmost subview of the window's content view and takes clicks only on the
/// transformed clip and its handles; every other click falls through to the views underneath.
/// Mouse events are handed to the viewer's PreviewTransformOverlay, which owns the drag logic.
@MainActor final class TransformChromeView: NSView {
    weak var overlay: PreviewTransformOverlay?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = [.width,.height]
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Keeps this view above anything SwiftUI adds to the window later.
    func install(in host: NSView) {
        if superview !== host { removeFromSuperview(); frame = host.bounds; host.addSubview(self,positioned:.above,relativeTo:nil) }
        else if host.subviews.last !== self { host.addSubview(self,positioned:.above,relativeTo:nil) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // No blanket capture while dragging or zooming: AppKit already sends mouseDragged/mouseUp to
        // the view that took mouseDown, and capturing everything would swallow unrelated clicks.
        guard let overlay, overlay.isTransforming else { return nil }
        let local = convert(point,from:superview)
        return overlay.chromeAccepts(overlay.convert(local,from:self)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { overlay?.mouseDown(with:event) }
    override func mouseDragged(with event: NSEvent) { overlay?.mouseDragged(with:event) }
    override func mouseUp(with event: NSEvent) { overlay?.mouseUp(with:event) }
    override func magnify(with event: NSEvent) { overlay?.magnify(with:event) }
    override func scrollWheel(with event: NSEvent) {
        if let overlay, event.modifierFlags.contains(.option) { overlay.scrollWheel(with:event) } else { super.scrollWheel(with:event) }
    }
    override func draw(_ dirtyRect: NSRect) { overlay?.drawChrome(in:self) }
    override func resetCursorRects() { overlay?.addChromeCursorRects(to:self) }
}

/// The picture of the clip being transformed, for drawing the part that lies outside the canvas.
/// Made once per frame and look (never per drag step), off the main actor, and only ever from the
/// image the preview actually shows, so a rebuild or a style change can never leave a stale one up.
@MainActor final class TransformGhost {
    private(set) var image: CGImage?
    private var imageKey: String?
    private var imageSize: CGSize?
    private var imageClip: UUID?
    private var pendingKey: String?
    private var task: Task<Void,Never>?
    // Decoded video frames are kept apart from their styled version: a colour-slider change
    // restyles the frame it already has instead of decoding it again.
    private var frameKey: String?
    private var frame: CGImage?
    private var generator: AVAssetImageGenerator?
    private var generatorURL: URL?
    var onReady: (() -> Void)?
    /// Core Image contexts are thread-safe and expensive (Metal); one is enough.
    private nonisolated static let context = FrameRenderer.makeContext()
    private nonisolated static let maxEdge: CGFloat = 2048

    /// The ghost for this clip, or nil when none matches it yet. Never an image made for another
    /// clip or another source size, which would be drawn stretched.
    func image(for clip: Clip, sourceTime: MediaTime, sourceSize: CGSize, store: EditorStore) -> CGImage? {
        let s = clip.style
        let look = "\(s.brightness)|\(s.contrast)|\(s.saturation)"
        let identityLook = s.brightness == 0 && s.contrast == 1 && s.saturation == 1
        let controls = [kCIInputBrightnessKey:s.brightness,kCIInputContrastKey:s.contrast,kCIInputSaturationKey:s.saturation]
        let current = imageClip == clip.id && imageSize == sourceSize ? image : nil
        if clip.kind == .video {
            guard let url = store.previewSourceURL(for:clip) else { return current }
            let fKey = "\(url.path)|\(sourceTime.ticks)"
            let key = "\(clip.id)|\(fKey)|\(look)"
            if key == imageKey { return current }
            if key == pendingKey { return current }
            pendingKey = key; task?.cancel()
            let generator = self.generator(for:url)
            if frameKey != fKey { generator.cancelAllCGImageGeneration() }   // latest wins; the old request really stops
            let cached = frameKey == fKey ? frame : nil
            task = Task { [weak self] in
                var decoded = cached
                if decoded == nil {
                    decoded = try? await generator.image(at:sourceTime.cmTime).image
                    guard !Task.isCancelled, let self else { return }
                    if let decoded { self.frameKey = fKey; self.frame = decoded }
                }
                guard let self else { return }
                guard let decoded else { if self.pendingKey == key { self.pendingKey = nil }; return }   // retry next draw
                let styled: CGImage? = identityLook ? decoded
                    : await Task.detached(priority:.userInitiated) { Self.styled(CIImage(cgImage:decoded),controls) }.value
                self.store(styled,key:key,size:sourceSize,clip:clip.id)
            }
            return current
        }
        // Text and stills: the layer image the current player item renders. While a rebuild is in
        // flight that item is about to be replaced, so wait for the new one.
        guard !store.isBuilding, let layer = store.previewLayerImage(for:clip) else { return current }
        let key = "\(clip.id)|\(ObjectIdentifier(layer).hashValue)|\(s.text.hashValue)|\(s.fontSize)|\(look)"
        if key == imageKey || key == pendingKey { return current }
        pendingKey = key; task?.cancel()
        let reuse = identityLook ? layer.cgImage : nil
        task = Task { [weak self] in
            let styled: CGImage?
            if let reuse, CGFloat(max(reuse.width,reuse.height)) <= Self.maxEdge { styled = reuse }
            else { styled = await Task.detached(priority:.userInitiated) { Self.styled(layer,controls) }.value }
            guard !Task.isCancelled, let self else { return }
            self.store(styled,key:key,size:sourceSize,clip:clip.id)
        }
        return current
    }
    private func store(_ styled: CGImage?, key: String, size: CGSize, clip: UUID) {
        guard pendingKey == key else { return }
        pendingKey = nil
        guard let styled else { return }                                  // failed: the next draw retries
        image = styled; imageKey = key; imageSize = size; imageClip = clip
        onReady?()
    }
    private func generator(for url: URL) -> AVAssetImageGenerator {
        if let generator, generatorURL == url { return generator }
        generator?.cancelAllCGImageGeneration()
        let made = AVAssetImageGenerator(asset:AVURLAsset(url:url))
        made.appliesPreferredTrackTransform = true
        made.maximumSize = CGSize(width:Self.maxEdge,height:Self.maxEdge)
        made.requestedTimeToleranceBefore = .zero; made.requestedTimeToleranceAfter = .zero
        generator = made; generatorURL = url
        return made
    }
    func reset() {
        task?.cancel(); task = nil; generator?.cancelAllCGImageGeneration(); generator = nil; generatorURL = nil
        image = nil; imageKey = nil; imageSize = nil; imageClip = nil; pendingKey = nil; frame = nil; frameKey = nil
    }

    /// The renderer's colour controls, at no more than maxEdge pixels on the long side: the ghost is
    /// drawn into the clip's source rectangle, so a smaller bitmap lands in exactly the same place.
    private nonisolated static func styled(_ source: CIImage, _ controls: [String:Double]) -> CGImage? {
        var image = source.transformed(by:CGAffineTransform(translationX:-source.extent.minX,y:-source.extent.minY))
        let longEdge = max(image.extent.width,image.extent.height)
        if longEdge > maxEdge {
            let factor = maxEdge/longEdge
            image = image.transformed(by:CGAffineTransform(scaleX:factor,y:factor))
        }
        image = image.applyingFilter("CIColorControls",parameters:controls)
        return context.createCGImage(image,from:image.extent.integral,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
    }
}
