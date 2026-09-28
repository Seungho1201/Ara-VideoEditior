import SwiftUI
import AppKit
import Combine
import FrameCore

struct TimelineView: View {
    @ObservedObject var store: EditorStore
    /// The canvas's vertical scroll position, so the track names stay beside their rows.
    @StateObject private var scroll = TimelineScroll()
    var body: some View {
        HStack(spacing:0) {
            VStack(spacing:0) {
                Text("TRACKS").font(.system(size:8,weight:.bold)).tracking(1).foregroundStyle(Theme.muted).frame(height:TimelineCanvas.ruler)
                VStack(spacing:0) {
                    addTrackButton(.video)
                    ForEach(store.project.displayLanes) { lane in
                        HStack(spacing:7) {
                            RoundedRectangle(cornerRadius:1).fill(lane.isVideo ? Color.blue.opacity(0.8) : Theme.accent).frame(width:3,height:22)
                            VStack(alignment:.leading,spacing:4) { Text(lane.rawValue).font(.system(size:11,weight:.semibold)); Text(LocalizedStringKey(lane.isVideo ? (lane.number == 1 ? "Picture" : "Overlay") : "Audio")).font(.system(size:8)).foregroundStyle(Theme.muted) }
                                .lineLimit(1).fixedSize()
                            Spacer(minLength:0)
                            if removable(lane) {
                                Button { store.removeTrack(lane) } label: {
                                    Image(systemName:"xmark").font(.system(size:8,weight:.bold)).foregroundStyle(Theme.muted)
                                        .frame(width:16,height:18).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).padding(.trailing,4)
                                .disabled(store.isExporting)
                                .help("Remove \(lane.rawValue) · the tracks above move down")
                                .accessibilityLabel("Remove track \(lane.rawValue)")
                            }
                        }.padding(.leading,12).frame(height:TimelineCanvas.rowHeight).overlay(alignment:.bottom){Divider()}
                    }
                    addTrackButton(.audio)
                    Spacer(minLength:0)
                }
                .offset(y:-scroll.offset)
                // minHeight 0: the names are as tall as all the tracks; the panel shows what fits
                // and scrolls the rest with the canvas, instead of the column growing the panel.
                .frame(minHeight:0,maxHeight:.infinity,alignment:.top).clipped()
                // Clipping only hides: without this, a "+" scrolled out of view still takes clicks
                // on the TRACKS header and the toolbar above it.
                .contentShape(Rectangle())
            }.frame(width:86).background(Theme.panel)
            Rectangle().fill(.white.opacity(0.08)).frame(width:1)
            TimelineSurface(store:store,scroll:scroll)
        }.background(Theme.background)
    }
    /// Added tracks (V3/A3 and up) can be removed while nothing is on them.
    private func removable(_ lane: Lane) -> Bool {
        lane.number > Project.trackCounts.lowerBound && !store.project.clips.contains { $0.lane == lane }
    }
    /// "+" above the top video track and below the bottom audio track.
    private func addTrackButton(_ kind: Lane.Kind) -> some View {
        let count = kind == .video ? store.project.videoTrackCount : store.project.audioTrackCount
        let atLimit = count >= Project.trackCounts.upperBound
        return Button { store.addTrack(kind) } label: {
            HStack(spacing:5) { Image(systemName:"plus"); Text(kind == .video ? "Video" : "Audio") }
                .font(.system(size:9,weight:.semibold)).foregroundStyle(Theme.muted)
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).padding(.leading,12).contentShape(Rectangle())
        }
        .buttonStyle(.plain).frame(height:TimelineCanvas.addBand)
        .helpTip(kind == .video ? "Add a video track" : "Add an audio track",kind == .video ? .above : .below)
        .disabled(atLimit || store.isExporting)
        .help(atLimit ? "A timeline has at most \(Project.trackCounts.upperBound) \(kind == .video ? "video" : "audio") tracks"
                      : kind == .video ? "Add a video track above V\(count)" : "Add an audio track below A\(count)")
        .accessibilityLabel(kind == .video ? "Add video track" : "Add audio track")
    }
}

/// Where the timeline canvas is scrolled to vertically.
@MainActor final class TimelineScroll: ObservableObject { @Published var offset: CGFloat = 0 }

struct TimelineSurface: NSViewRepresentable {
    @ObservedObject var store: EditorStore
    let scroll: TimelineScroll
    @MainActor final class Coordinator { var watch: NSObjectProtocol?; var updating = false }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> NSScrollView {
        let view = NSScrollView()
        view.hasHorizontalScroller = true; view.hasVerticalScroller = true; view.autohidesScrollers = true
        view.drawsBackground = false; view.scrollerStyle = .legacy
        // No rubber band vertically: the name column follows the canvas's settled offset only.
        view.verticalScrollElasticity = .none
        let canvas = TimelineCanvas(); canvas.store = store; view.documentView = canvas
        // Tracks that no longer fit scroll vertically; the name column follows the same offset.
        view.contentView.postsBoundsChangedNotifications = true
        let model = scroll, coordinator = context.coordinator
        coordinator.watch = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:view.contentView,queue:.main) { [weak clip = view.contentView] _ in
            MainActor.assumeIsolated {
                guard let clip else { return }
                (clip.documentView as? TimelineCanvas)?.scrolled(to:clip.bounds.origin)
                let y = max(0,clip.bounds.origin.y)
                guard model.offset != y else { return }
                // Resizing the canvas in updateNSView can move the clip view synchronously; a
                // SwiftUI model must not be published from inside that update.
                if coordinator.updating { DispatchQueue.main.async { model.offset = y } } else { model.offset = y }
            }
        }
        return view
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        if let watch = coordinator.watch { NotificationCenter.default.removeObserver(watch) }
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let canvas = scroll.documentView as? TimelineCanvas else { return }
        context.coordinator.updating = true; defer { context.coordinator.updating = false }
        let oldZoom = canvas.pixelsPerSecond
        canvas.store = store; canvas.pixelsPerSecond = store.zoom
        canvas.synchronizeScrubbing()
        canvas.setFrameSize(NSSize(width:max(scroll.contentSize.width,(max(20,store.project.duration.seconds)+8)*store.zoom),
                                   height:max(canvas.contentHeight,scroll.contentSize.height)))
        if oldZoom != store.zoom {
            let x = max(0,min(canvas.frame.width-scroll.contentSize.width,store.playhead.seconds*store.zoom-scroll.contentSize.width*0.45))
            scroll.contentView.scroll(to:NSPoint(x:x,y:scroll.contentView.bounds.origin.y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        if canvas.revealPlayheadRequest != store.revealPlayheadRequest {
            canvas.revealPlayheadRequest = store.revealPlayheadRequest
            let x = store.playhead.seconds*store.zoom
            let visible = scroll.contentView.bounds
            if x < visible.minX+12 || x > visible.maxX-12 {
                let offset = max(0,min(canvas.frame.width-visible.width,x-visible.width*0.5))
                scroll.contentView.scroll(to:NSPoint(x:offset,y:visible.origin.y)); scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        // Arming rectangle select gives the timeline the keyboard, so Esc reaches it.
        if store.dragSelectArmed, !canvas.armedForSelect, let window = canvas.window { window.makeFirstResponder(canvas) }
        canvas.armedForSelect = store.dragSelectArmed
        canvas.needsDisplay = true
        canvas.window?.invalidateCursorRects(for:canvas)
    }
}

@MainActor final class TimelineCanvas: NSView, NSUserInterfaceValidations {
    weak var store: EditorStore? { didSet { if store !== oldValue { followPlayhead() } } }
    private var playheadWatch: AnyCancellable?
    var pixelsPerSecond: Double = 64
    var revealPlayheadRequest = 0
    /// Whether rectangle select was armed at the last update (to notice it being switched on).
    var armedForSelect = false
    /// Shared with the SwiftUI track-name column so rows line up.
    static let ruler: Double = 28, addBand: Double = 26, rowHeight: Double = 62
    private let ruler = TimelineCanvas.ruler, rowHeight = TimelineCanvas.rowHeight, band = TimelineCanvas.addBand
    /// Top to bottom: V(n) … V1, A1 … A(n).
    private var lanes: [Lane] { store?.project.displayLanes ?? [] }
    private func rowTop(_ index: Int) -> Double { ruler+band+Double(index)*rowHeight }
    /// Ruler, the "+ Video" band, every track, the "+ Audio" band.
    var contentHeight: Double { ruler+band*2+Double(lanes.count)*rowHeight }
    /// The ruler stays at the top of the view while the tracks scroll under it.
    private var rulerTop: Double { visibleRect.minY }
    private enum DragMode { case move, start, end, scrub, marquee }
    private var mode: DragMode?
    /// A move of several selected clips together: the selection, where they would land, and by how much.
    private var group: Set<UUID>?
    private var groupGhosts: [Clip] = []
    private var groupDelta: MediaTime?
    /// Pressed on one of several selected clips: if it is let go without moving, just that one is selected.
    private var clickedInGroup: UUID?
    /// Shift-drag over empty track space: the rectangle, and what was selected before it.
    private var marquee: NSRect?
    private var marqueeBase: Set<UUID> = []
    private var origin = NSPoint.zero
    private var original: Clip?
    private var candidate: Clip?
    private var candidateValid = true
    private struct TransitionResize {
        let base: Project
        let original: FrameCore.Transition
        let leading: Bool
        let edge: MediaTime
        var candidate: FrameCore.Transition
    }
    private var transitionResize: TransitionResize?
    private var dropped: (UUID,Lane,MediaTime)?
    private var mediaDropFeedback = MediaDropFeedback()
    /// A dragged clip, edge or transition catching a snap.
    private var snapFeedback = SnapFeedback()
    /// A transition from the library over the clip edge (or cut) it would go on.
    private struct TransitionEdge: Equatable { let from: UUID?; let to: UUID? }
    private var transitionDropFeedback = CatchFeedback<TransitionEdge>()
    private func feelSnap(_ target: MediaTime?, _ event: NSEvent) {
        if snapFeedback.cue(for:target,at:event.timestamp,enabled:store?.haptics(.snapping) == true) { performHaptic(.alignment) }
    }
    private var mediaDragSequence: Int?
    /// Kept at the AppKit boundary so input tests can capture cues without vibrating hardware.
    /// The live hardware button state, kept at the AppKit boundary so input tests can pin it.
    var pressedMouseButtons: () -> Int = { NSEvent.pressedMouseButtons }
    var performHaptic: (NSHapticFeedbackManager.FeedbackPattern) -> Void = { pattern in
        NSHapticFeedbackManager.defaultPerformer.perform(pattern,performanceTime:.now)
    }
    /// A transition dragged from the library, over the clip edge it would land on.
    private struct TransitionDrop {
        let transition: FrameCore.Transition
        let lane: Lane
        let time: MediaTime
        let window: TransitionWindow
    }
    private var transitionDrop: TransitionDrop?
    private var moved = false
    private var tracking: NSTrackingArea?
    private var scrubSession: UUID?
    private var scrubEnd: MediaTime?
    private var scrubFeedback = ScrubFeedbackCadence()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame:NSRect) {
        super.init(frame:frame)
        registerForDraggedTypes([TransitionDrag.pasteboardType,.string,.fileURL]); setAccessibilityElement(true)
        setAccessibilityRole(.group); setAccessibilityLabel("Multitrack timeline. V2 above V1. A1 and A2 linked audio.")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        resetScrubbing()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area); tracking = area
    }
    /// Model/settings changes must not leave a stale boundary indicator or haptic latch.
    func synchronizeScrubbing() {
        guard let store else { resetScrubbing(); return }
        if let scrubSession, scrubSession != store.session {
            mode = nil; clearGroupGesture(); resetScrubbing()
        }
        if store.isPlaying || store.isBuilding || store.isExporting || store.isCapturingSnapshot || store.showExportSheet || store.showNewProjectSheet || store.showLauncher || store.isEditingText {
            resetScrubbing()
        } else if !store.snapping { setScrubEnd(nil) }
    }
    private func setScrubEnd(_ end: MediaTime?) {
        guard end != scrubEnd else { return }
        // The marker and its short label fit inside this strip, even at the viewport edge.
        for time in [scrubEnd,end].compactMap({ $0 }) {
            setNeedsDisplay(NSRect(x:time.seconds*pixelsPerSecond-64,y:0,width:128,height:bounds.height))
        }
        scrubEnd = end
    }
    private func resetScrubbing() {
        scrubSession = nil; scrubFeedback = ScrubFeedbackCadence(); setScrubEnd(nil)
    }
    private func scrub(at point: NSPoint, with event: NSEvent) {
        guard let store, !store.project.clips.isEmpty, !store.isExporting, !store.showExportSheet else { resetScrubbing(); return }
        // Playback started during the gesture (Space with the button still down, or a release
        // that arrives late, as with three-finger drag): the playhead belongs to playback now.
        // Following the pointer, or seeking to where it was released, would throw it back.
        // mouseDown pauses first, so a press on the ruler during playback still scrubs.
        if store.isPlaying { if mode == .scrub { mode = nil }; resetScrubbing(); return }
        if scrubSession != store.session { scrubFeedback = ScrubFeedbackCadence(); scrubSession = store.session }
        scrubFeedback.strength = store.skimHapticStrength
        let position = store.project.scrubPosition(at:time(at:point.x),snapping:store.snapping && !event.modifierFlags.contains(.shift))
        setScrubEnd(position.snappedEnd)
        let didMove = store.playhead != position.time
        if didMove { store.seek(position.time) }
        guard let cue = scrubFeedback.cue(for:position,at:event.timestamp,enabled:store.haptics(.skimming)),
              didMove || cue == .clipEnd else { return }
        // macOS exposes semantic patterns, not an intensity control. Alignment is the
        // system's boundary cue; levelChange is for pressure zones, not a stronger tap.
        performHaptic(cue == .clipEnd ? .alignment : .generic)
    }
    /// Ends a marquee or group move without committing it.
    private func clearGroupGesture() {
        if marquee != nil, let store, store.dragSelectArmed { store.dragSelectArmed = false }
        guard group != nil || marquee != nil || clickedInGroup != nil else { return }
        group = nil; groupGhosts = []; groupDelta = nil; clickedInGroup = nil; marquee = nil; needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        // A menu or window change can swallow mouseUp. A subsequent button-free
        // move ends that interrupted gesture; never commit its stale drag candidate.
        if event.type == .mouseMoved, pressedMouseButtons() == 0,
           mode != nil || transitionResize != nil || dropped != nil || transitionDrop != nil {
            mode = nil; original = nil; candidate = nil; transitionResize = nil; moved = false
            candidateValid = true
            clearGroupGesture()
            clearDropFeedback()
            resetScrubbing()
            window?.invalidateCursorRects(for:self)
        }
        // Hover never seeks or emits haptics. Only a pressed ruler/empty-track
        // gesture calls scrub; this tracking area solely recovers interrupted drags.
    }
    override func mouseExited(with event: NSEvent) {
        if mode != .scrub { resetScrubbing() }
    }
    private var lastScroll = NSPoint.zero
    /// A scroll shifts the pixels already drawn and repaints only the strip it uncovers. Clip
    /// names and speed badges stay in view while their clip is part-way off screen, so they move
    /// with the visible edge: across a horizontal scroll the title bands are repainted too, or
    /// the shifted copies would pile up. A vertical scroll repaints everything (the ruler is
    /// pinned to the top).
    func scrolled(to origin: NSPoint) {
        defer { lastScroll = origin }
        if origin.y != lastScroll.y { needsDisplay = true; return }
        guard origin.x != lastScroll.x, let store else { return }
        let visible = visibleRect
        if store.project.clips.isEmpty { needsDisplay = true; return }        // the centred hint
        var bands = Set<Double>()
        for clip in store.project.clips {
            let box = rect(clip)
            if box.intersects(visible) { bands.insert(box.minY) }
        }
        for top in bands { setNeedsDisplay(NSRect(x:visible.minX,y:top,width:visible.width,height:20)) }
    }
    /// A playhead move repaints the strips under its old and new positions, not the timeline.
    private func followPlayhead() {
        playheadWatch = store?.clock.moved.sink { [weak self] move in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let end = self.scrubEnd, end != move.new { self.resetScrubbing() }
                for time in [move.old,move.new] {
                    self.setNeedsDisplay(NSRect(x:time.seconds*self.pixelsPerSecond-8,y:0,width:16,height:self.bounds.height))
                }
                if self.store?.isPlaying == true { self.turnPage(from:move.old,to:move.new) }
            }
        }
    }
    /// Playing past the edge of the visible timeline turns the page: the next stretch comes into
    /// view with the playhead a little in from its left edge (as it does going back to the start).
    /// Only a playhead that was on screen: one the user has scrolled away from is left alone.
    private func turnPage(from old: MediaTime, to new: MediaTime) {
        guard mode == nil, let scroll = enclosingScrollView else { return }
        let visible = scroll.contentView.bounds, margin = min(40,visible.width*0.05)
        let was = old.seconds*pixelsPerSecond, now = new.seconds*pixelsPerSecond
        guard was >= visible.minX, was <= visible.maxX, now > visible.maxX-margin || now < visible.minX else { return }
        let x = max(0,min(bounds.width-visible.width,now-margin))
        guard abs(x-visible.minX) > 1 else { return }
        scroll.contentView.scroll(to:NSPoint(x:x,y:visible.origin.y)); scroll.reflectScrolledClipView(scroll.contentView)
    }
    /// The lower part of the row around a transition's window, so the clip titles and trim
    /// handles above it stay reachable.
    private func rect(_ transition: FrameCore.Transition) -> NSRect? {
        guard let store, let window = store.project.window(of:transition),
              let clip = (transition.from ?? transition.to).flatMap(store.project.clip),
              let index = lanes.firstIndex(of:clip.lane) else { return nil }
        let height = rowHeight-10
        return NSRect(x:window.start.seconds*pixelsPerSecond,y:rowTop(index)+5+height*0.4,width:max(8,window.duration.seconds*pixelsPerSecond),height:height*0.6)
    }
    private func resizeHandle(_ transition: FrameCore.Transition, leading: Bool) -> NSRect? {
        guard transition.isCut || (leading ? transition.to == nil : transition.from == nil),
              let box = rect(transition) else { return nil }
        // Split even a minimum-width transition into two distinct handles. The small outer
        // margin makes them easy to grab without stealing the clip's title-band trim handle.
        let reach = min(7,box.width/2)
        return NSRect(x:leading ? box.minX-3 : box.maxX-reach,y:box.minY,width:reach+3,height:box.height)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let store, !store.isExporting else { return }
        if store.dragSelectArmed {
            let tracks = NSRect(x:visibleRect.minX,y:rulerTop+ruler,width:visibleRect.width,height:max(0,visibleRect.height-ruler))
            addCursorRect(tracks,cursor:.crosshair); return
        }
        let visible = NSRect(x:visibleRect.minX,y:rulerTop+ruler,width:visibleRect.width,height:max(0,visibleRect.height-ruler))
        for transition in store.project.transitions {
            for leading in [true,false] {
                if let handle = resizeHandle(transition,leading:leading) {
                    let area = handle.intersection(visible)
                    if !area.isEmpty { addCursorRect(area,cursor:.resizeLeftRight) }
                }
            }
        }
    }
    /// Resolve against the current project both while hovering and at mouse-up. The complete
    /// clip is a target; its nearest edge wins. Empty track space only reaches 24 points away.
    /// Dropping on an existing transition replaces that exact transition, including fades.
    private func transitionTarget(_ kind: TransitionKind, at point: NSPoint) -> TransitionDrop? {
        guard let store, !store.isExporting, let lane = lane(at:point), lane.isVideo else { return nil }
        let from: UUID?, to: UUID?, edgeTime: MediaTime
        if let existing = store.project.transitions.first(where: { rect($0)?.contains(point) == true }) {
            from = existing.from; to = existing.to
            guard let time = from.flatMap(store.project.clip)?.end ?? to.flatMap(store.project.clip)?.start else { return nil }
            edgeTime = time
        } else {
            let clip = store.project.clips.first { $0.lane == lane && rect($0).contains(point) }
            let reach = clip?.duration ?? MediaTime(seconds:24/pixelsPerSecond)
            guard let edge = Editing.nearestTransitionEdge(on:lane,to:time(at:point.x),within:reach,in:store.project) else { return nil }
            from = edge.from; to = edge.to; edgeTime = edge.time
        }
        // Use the same editing command as the commit, without mutating the live document or
        // its undo history. Do not advertise a drop if another transition leaves no room.
        let existing = store.project.transitions.first { $0.from == from && $0.to == to }
        var candidate = store.project
        guard let id = try? Editing.setTransition(kind,direction:existing?.direction ?? .left,duration:existing?.duration,from:from,to:to,in:&candidate),
              let transition = candidate.transitions.first(where: { $0.id == id }),
              let window = candidate.window(of:transition) else { return nil }
        return TransitionDrop(transition:transition,lane:lane,time:edgeTime,window:window)
    }
    private func rect(_ clip:Clip) -> NSRect {
        let x = clip.start.seconds*pixelsPerSecond, width = max(2,clip.duration.seconds*pixelsPerSecond)
        guard let index = lanes.firstIndex(of:clip.lane) else {
            // A track a move is about to add (linked audio following its video to A3): drawn in the
            // "+" band where that track will appear, never over an existing row.
            return NSRect(x:x,y:(clip.lane.isVideo ? ruler : rowTop(lanes.count))+3,width:width,height:band-6)
        }
        return NSRect(x:x,y:rowTop(index)+5,width:width,height:rowHeight-10)
    }
    private func lane(at point:NSPoint) -> Lane? {
        guard point.y >= rulerTop+ruler else { return nil }
        let index = Int(floor((point.y-ruler-band)/rowHeight)), lanes = lanes
        return point.y >= ruler+band && lanes.indices.contains(index) ? lanes[index] : nil
    }
    private func time(at x:Double) -> MediaTime { .init(seconds:max(0,x/pixelsPerSecond)) }
    private func label(_ text:String,at point:NSPoint,size:CGFloat = 10,color:NSColor = .secondaryLabelColor) {
        (text as NSString).draw(at:point,withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:size,weight:.medium),.foregroundColor:color])
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let store else { return }
        NSColor(red:0.055,green:0.065,blue:0.085,alpha:1).setFill(); dirtyRect.fill()
        let visible = visibleRect.intersection(dirtyRect)
        let lanes = lanes
        for index in lanes.indices {
            let row = NSRect(x:visible.minX,y:rowTop(index),width:visible.width,height:rowHeight)
            NSColor(white:index%2 == 0 ? 0.11 : 0.09,alpha:1).setFill(); row.fill()
            NSColor(white:0.19,alpha:1).setStroke(); let line = NSBezierPath(); line.move(to:NSPoint(x:visible.minX,y:row.maxY)); line.line(to:NSPoint(x:visible.maxX,y:row.maxY)); line.stroke()
        }
        // The "+ Video" and "+ Audio" bands beside the track-name buttons stay empty.
        NSColor(white:0.07,alpha:1).setFill()
        NSRect(x:visible.minX,y:ruler,width:visible.width,height:band).fill()
        NSRect(x:visible.minX,y:rowTop(lanes.count),width:visible.width,height:band).fill()
        let interval: Double = pixelsPerSecond > 100 ? 1 : pixelsPerSecond > 40 ? 2 : pixelsPerSecond > 15 ? 5 : 10
        let first = floor(visible.minX/pixelsPerSecond/interval)*interval
        let last = ceil(visible.maxX/pixelsPerSecond/interval)*interval
        for second in stride(from:first,through:last,by:interval) {
            let x = second*pixelsPerSecond
            NSColor(white:0.22,alpha:1).setStroke(); let line = NSBezierPath(); line.move(to:NSPoint(x:x,y:ruler)); line.line(to:NSPoint(x:x,y:bounds.height)); line.lineWidth = 0.5; line.stroke()
        }
        let linked = Set(store.selectedClipIDs.flatMap { store.project.group(for:$0).map(\.id) })
        for clip in store.project.clips {
            let box = rect(clip)
            guard box.intersects(visible) else { continue }
            drawClip(clip,box:box,selected:linked.contains(clip.id),ghost:false,in:visible)
        }
        let resizing = transitionResize.flatMap { $0.base == store.project ? $0 : nil }
        for transition in store.project.transitions {
            let displayed = resizing.flatMap { $0.original.id == transition.id ? $0.candidate : nil } ?? transition
            guard let box = rect(displayed), box.intersects(visible) else { continue }
            drawTransition(displayed,box:box,selected:store.selectedTransitionID == transition.id)
        }
        if let resizing, moved, let box = rect(resizing.candidate) {
            let duration = resizing.candidate.duration
            let text = String(format:"%.2f s",duration.seconds)+" · \(duration.ticks/store.project.frameRate.frame.ticks)f"
            let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.semibold),.foregroundColor:NSColor.black]
            let size = (text as NSString).size(withAttributes:attributes)
            let x = resizing.leading ? box.minX : box.maxX
            let pill = NSRect(x:max(visibleRect.minX+3,min(x-size.width/2-7,visibleRect.maxX-size.width-17)),
                              y:max(rulerTop+ruler,box.minY-21),width:size.width+14,height:18)
            Theme.accentNS.setFill(); NSBezierPath(roundedRect:pill,xRadius:5,yRadius:5).fill()
            (text as NSString).draw(at:NSPoint(x:pill.minX+7,y:pill.minY+(18-size.height)/2),withAttributes:attributes)
        }
        if let drop = transitionDrop, let index = lanes.firstIndex(of:drop.lane) {
            let transition = drop.transition
            let x = drop.time.seconds*pixelsPerSecond
            let area = NSRect(x:drop.window.start.seconds*pixelsPerSecond,y:rowTop(index)+5,
                              width:max(3,drop.window.duration.seconds*pixelsPerSecond),height:rowHeight-10)
            let highlight = NSBezierPath(roundedRect:area,xRadius:4,yRadius:4)
            Theme.accentNS.withAlphaComponent(0.3).setFill(); highlight.fill()
            Theme.accentNS.setStroke(); highlight.lineWidth = 2; highlight.stroke()
            Theme.accentNS.setFill(); NSRect(x:x-1.5,y:rowTop(index)+2,width:3,height:rowHeight-4).fill()
            let text = transition.isCut ? transition.kind.name : transition.to != nil ? "\(transition.kind.name) · in" : "\(transition.kind.name) · out"
            let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:10,weight:.semibold),.foregroundColor:NSColor.black]
            let size = (text as NSString).size(withAttributes:attributes)
            let left = max(visibleRect.minX+3,min(x-size.width/2-7,visibleRect.maxX-size.width-17))
            let pill = NSRect(x:left,y:rowTop(index)+rowHeight/2-9,width:size.width+14,height:18)
            Theme.accentNS.setFill(); NSBezierPath(roundedRect:pill,xRadius:9,yRadius:9).fill()
            (text as NSString).draw(at:NSPoint(x:pill.minX+7,y:pill.minY+(18-size.height)/2),withAttributes:attributes)
        }
        if let candidate, moved {
            drawClip(candidate,box:rect(candidate),selected:true,ghost:true,in:visible)
            if let original, let link = original.linkID,
               let audio = store.project.clips.first(where:{$0.linkID == link && $0.id != original.id}) {
                var linked = audio; linked.start = candidate.start; linked.duration = candidate.duration; linked.lane = candidate.lane.paired
                drawClip(linked,box:rect(linked),selected:true,ghost:true,in:visible)
            }
            label(candidateValid ? store.project.frameRate.timecode(candidate.start) : "Track occupied / source limit",at:NSPoint(x:max(visible.minX+5,rect(candidate).minX),y:rect(candidate).maxY-16),size:10,color:candidateValid ? .white : .systemRed)
        }
        if group != nil, moved, !groupGhosts.isEmpty {
            for ghost in groupGhosts { drawClip(ghost,box:rect(ghost),selected:true,ghost:true,in:visible) }
            if let first = groupGhosts.min(by: { $0.start < $1.start }) {
                label(candidateValid ? store.project.frameRate.timecode(first.start) : "Track occupied",at:NSPoint(x:max(visible.minX+5,rect(first).minX),y:rect(first).maxY-16),size:10,color:candidateValid ? .white : .systemRed)
            }
        }
        if let marquee {
            let path = NSBezierPath(rect:marquee)
            Theme.accentNS.withAlphaComponent(0.12).setFill(); path.fill()
            Theme.accentNS.withAlphaComponent(0.9).setStroke(); path.lineWidth = 1; path.stroke()
        }
        if let gap = store.selectedGap {
            let row = lanes.firstIndex(of:gap.lane) ?? 0
            let box = NSRect(x:gap.start.seconds*pixelsPerSecond,y:rowTop(row)+5,
                             width:max(3,gap.duration.seconds*pixelsPerSecond),height:rowHeight-10)
            if box.intersects(visible) {
                let path = NSBezierPath(roundedRect:box.insetBy(dx:1,dy:1),xRadius:4,yRadius:4)
                NSColor.white.withAlphaComponent(0.14).setFill(); path.fill()
                NSColor.white.setStroke(); path.lineWidth = 2; path.stroke()
                if box.width > 132 { label(String(localized:"\(ShortcutSettings.shared.label(.closeGap)) close gap · \(store.project.frameRate.timecode(gap.duration))"),at:NSPoint(x:box.minX+8,y:box.midY-6),size:9,color:.white) }
            }
        }
        if let (id,lane,time) = dropped, let media = store.project.media.first(where:{$0.id == id}) {
            let clip = Clip(mediaID:id,name:media.name,kind:media.kind,lane:lane,start:time,duration:media.duration)
            Theme.accentNS.withAlphaComponent(0.3).setFill(); NSBezierPath(roundedRect:rect(clip),xRadius:4,yRadius:4).fill()
        }
        if store.project.clips.isEmpty { label("Drag media onto a video (V) or audio (A) track",at:NSPoint(x:visible.minX+24,y:rowTop(0)+57),size:13,color:NSColor(white:0.45,alpha:1)) }
        // The ruler is pinned to the top of the view; tracks scroll underneath it.
        let top = rulerTop
        NSColor(red:0.055,green:0.065,blue:0.085,alpha:1).setFill(); NSRect(x:visible.minX,y:top,width:visible.width,height:ruler).fill()
        for second in stride(from:first,through:last,by:interval) {
            let x = second*pixelsPerSecond
            NSColor(white:0.22,alpha:1).setStroke(); let tick = NSBezierPath(); tick.move(to:NSPoint(x:x,y:top+20)); tick.line(to:NSPoint(x:x,y:top+ruler)); tick.lineWidth = 0.5; tick.stroke()
            label(String(format:"%02d:%02d",Int(second)/60,Int(second)%60),at:NSPoint(x:x+5,y:top+7),size:9)
        }
        let x = store.playhead.seconds*pixelsPerSecond
        if x >= visible.minX-10 && x <= visible.maxX+10 {
            let color = Theme.accentNS; color.setStroke(); color.setFill()
            let line = NSBezierPath(); line.move(to:NSPoint(x:x,y:top)); line.line(to:NSPoint(x:x,y:bounds.height)); line.lineWidth = 1.5; line.stroke()
            let head = NSBezierPath(); head.move(to:NSPoint(x:x-5,y:top)); head.line(to:NSPoint(x:x+5,y:top)); head.line(to:NSPoint(x:x+5,y:top+8)); head.line(to:NSPoint(x:x,y:top+13)); head.line(to:NSPoint(x:x-5,y:top+8)); head.close(); head.fill()
            if scrubEnd == store.playhead && !store.isPlaying {
                // Keep the ordinary playhead visible; a brighter, wider strip and a ruler
                // label explain the magnetic jump even on hardware without haptics.
                Theme.accentNS.withAlphaComponent(0.22).setFill()
                NSRect(x:x-4,y:top+ruler,width:8,height:bounds.height-top-ruler).fill()
                let left = max(visible.minX+2,min(x-22,visible.maxX-46))
                let badge = NSRect(x:left,y:top+13,width:44,height:14)
                Theme.accentNS.setFill(); NSBezierPath(roundedRect:badge,xRadius:3,yRadius:3).fill()
                label("CLIP END",at:NSPoint(x:left+3,y:top+15),size:8,color:.black)
            }
        }
    }
    /// A translucent strip over the clips with a bow tie, like the transition icons in other editors.
    private func drawTransition(_ transition: FrameCore.Transition, box: NSRect, selected: Bool) {
        let path = NSBezierPath(roundedRect:box,xRadius:3,yRadius:3)
        NSColor.white.withAlphaComponent(selected ? 0.3 : 0.18).setFill(); path.fill()
        let bow = NSBezierPath()
        if transition.isCut {
            bow.move(to:NSPoint(x:box.minX,y:box.minY)); bow.line(to:NSPoint(x:box.maxX,y:box.maxY))
            bow.move(to:NSPoint(x:box.minX,y:box.maxY)); bow.line(to:NSPoint(x:box.maxX,y:box.minY))
        } else if transition.to != nil {        // fade in: a ramp up
            bow.move(to:NSPoint(x:box.minX,y:box.maxY)); bow.line(to:NSPoint(x:box.maxX,y:box.minY))
        } else {                                // fade out: a ramp down
            bow.move(to:NSPoint(x:box.minX,y:box.minY)); bow.line(to:NSPoint(x:box.maxX,y:box.maxY))
        }
        NSColor.white.withAlphaComponent(0.45).setStroke(); bow.lineWidth = 1; bow.stroke()
        (selected ? Theme.accentNS : NSColor.white.withAlphaComponent(0.6)).setStroke(); path.lineWidth = selected ? 2 : 1; path.stroke()
        if selected {
            Theme.accentNS.setFill()
            if transition.isCut || transition.to == nil { NSRect(x:box.minX+2,y:box.midY-7,width:2,height:14).fill() }
            if transition.isCut || transition.from == nil { NSRect(x:box.maxX-4,y:box.midY-7,width:2,height:14).fill() }
        }
        if box.width > 76 {
            let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:9,weight:.semibold),.foregroundColor:NSColor.white]
            let size = (transition.kind.name as NSString).size(withAttributes:attributes)
            let label = NSRect(x:box.midX-size.width/2-4,y:box.midY-size.height/2-1,width:size.width+8,height:size.height+2)
            NSColor.black.withAlphaComponent(0.55).setFill(); NSBezierPath(roundedRect:label,xRadius:3,yRadius:3).fill()
            (transition.kind.name as NSString).draw(at:NSPoint(x:label.minX+4,y:label.minY+1),withAttributes:attributes)
        }
    }
    /// A retimed clip's speed, top right: gauge and factor on a dark pill, like the toolbar's
    /// speed control. A short clip gets the factor alone, then the gauge alone. Returns where it
    /// was drawn, or nil when not even the gauge fits right of `after` (the clip's visible left).
    private func speedBadge(_ speed: Double, right: CGFloat, top: CGFloat, after left: CGFloat) -> NSRect? {
        let text = String(format:"%.2fx",speed) as NSString
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.semibold),.foregroundColor:NSColor.white]
        let textWidth = ceil(text.size(withAttributes:attributes).width), textHeight = text.size(withAttributes:attributes).height
        let icon: CGFloat = 11
        let layouts: [(gauge: Bool, label: Bool, width: CGFloat)] = [(true,true,5+icon+3+textWidth+6),(false,true,6+textWidth+6),(true,false,4+icon+4)]
        guard let fit = layouts.first(where: { right-$0.width >= left+4 }) else { return nil }
        let badge = NSRect(x:right-fit.width,y:top,width:fit.width,height:14)
        NSColor.black.withAlphaComponent(0.45).setFill(); NSBezierPath(roundedRect:badge,xRadius:7,yRadius:7).fill()
        var x = badge.minX+(fit.gauge ? (fit.label ? 5 : 4) : 6)
        if fit.gauge, let gauge = NSImage(systemSymbolName:"speedometer",accessibilityDescription:"Speed")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:9,weight:.semibold).applying(.init(paletteColors:[.white]))) {
            gauge.draw(in:NSRect(x:x,y:badge.minY+1.5,width:icon,height:icon),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            x += icon+3
        }
        if fit.label { text.draw(at:NSPoint(x:x,y:badge.minY+(badge.height-textHeight)/2),withAttributes:attributes) }
        return badge
    }
    /// `area` is the part being repainted: thumbnails and waveform are only drawn there.
    private func drawClip(_ clip:Clip,box:NSRect,selected:Bool,ghost:Bool,in area:NSRect) {
        guard let store else { return }
        let color: NSColor = clip.kind == .audio ? NSColor(red:0.16,green:0.28,blue:0.42,alpha:1) : clip.kind == .text ? NSColor(red:0.39,green:0.29,blue:0.51,alpha:1) : NSColor(red:0.18,green:0.31,blue:0.5,alpha:1)
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(roundedRect:box,xRadius:4,yRadius:4); path.addClip()
        color.withAlphaComponent(ghost ? 0.6 : 1).setFill(); box.fill()
        if !ghost {
            if clip.kind == .audio, let id = clip.mediaID, let peaks = store.waveforms[id], !peaks.isEmpty, let media = store.project.media(for:clip) {
                let waveform = NSBezierPath(); let center = box.minY+35
                // Anchor bars to the clip, never the dirty rect: playhead-only repaints and
                // newly exposed scroll strips must use the same positions/source samples as
                // a full draw. Include neighboring strokes whose antialiasing crosses an edge.
                let first = max(0,Int(floor((area.minX-box.minX)/2)))
                let last = min(Int(ceil(box.width/2)),Int(ceil((area.maxX-box.minX)/2))+1)
                if first < last {
                    for bar in first..<last {
                        let x = box.minX+Double(bar)*2
                        // A retimed clip walks the source at its own rate, or a 2x clip would
                        // draw only the first half of the audio it actually plays.
                        let source = clip.sourceStart.seconds+(x-box.minX)/pixelsPerSecond*clip.speed
                        let index = min(peaks.count-1,max(0,Int(source/max(0.001,media.duration.seconds)*Double(peaks.count))))
                        let amplitude = max(1,Double(peaks[index])*17)
                        waveform.move(to:NSPoint(x:x,y:center-amplitude)); waveform.line(to:NSPoint(x:x,y:center+amplitude))
                    }
                }
                Theme.accentNS.withAlphaComponent(0.85).setStroke(); waveform.lineWidth = 1; waveform.stroke()
            } else if let id = clip.mediaID, let image = store.thumbnails[id] {
                let strip = NSRect(x:box.minX,y:box.minY+20,width:82,height:box.height-20)
                let first = max(0,Int((area.minX-box.minX)/82))
                let last = min(Int(ceil(box.width/82)),Int(ceil((area.maxX-box.minX)/82)))
                if first < last { for tile in first..<last { image.draw(in:strip.offsetBy(dx:Double(tile)*82,dy:0),from:.zero,operation:.sourceOver,fraction:0.6,respectFlipped:true,hints:nil) } }
            }
            NSColor.black.withAlphaComponent(0.25).setFill(); NSRect(x:box.minX,y:box.minY,width:box.width,height:20).fill()
            let titleX = max(box.minX+7,visibleRect.minX+4)
            var titleEnd = min(box.maxX,visibleRect.maxX)-6
            // The speed outranks the name on a short clip: the badge takes its corner whenever it
            // fits, and the title gets what is left, truncated, or nothing when that is a sliver.
            if clip.speed != 1, let badge = speedBadge(clip.speed,right:min(box.maxX,visibleRect.maxX)-4,top:box.minY+3,after:max(box.minX,visibleRect.minX)) {
                titleEnd = badge.minX-6
            }
            if titleEnd-titleX >= 18 {
                let title = (clip.linkID == nil ? "" : "↔ ")+(clip.kind == .text ? clip.style.text : clip.name)
                let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
                (title as NSString).draw(with:NSRect(x:titleX,y:box.minY+4,width:titleEnd-titleX,height:14),options:[.usesLineFragmentOrigin,.truncatesLastVisibleLine],
                                         attributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.medium),.foregroundColor:NSColor.white,.paragraphStyle:style])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        (selected ? (ghost && !candidateValid ? NSColor.systemRed : Theme.accentNS) : color.highlight(withLevel:0.2)!).setStroke()
        path.lineWidth = selected ? 2 : 1; path.stroke()
        if selected {
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSRect(x:box.minX+2,y:box.midY-8,width:2,height:16).fill(); NSRect(x:box.maxX-4,y:box.midY-8,width:2,height:16).fill()
        }
    }
    override func mouseDown(with event:NSEvent) {
        guard let store else { return }
        resetScrubbing()
        mode = nil; original = nil; candidate = nil; transitionResize = nil
        group = nil; groupGhosts = []; groupDelta = nil; clickedInGroup = nil; marquee = nil; snapFeedback = SnapFeedback()
        window?.makeFirstResponder(self); origin = convert(event.locationInWindow,from:nil); moved = false
        if origin.y < rulerTop+ruler { mode = .scrub; store.pause(); scrub(at:origin,with:event); return }
        let shift = event.modifierFlags.intersection([.shift,.command,.option,.control]) == [.shift]
        // Rectangle select from the toolbar: this press starts a rectangle wherever it lands on the
        // tracks, clips included. It replaces the selection (with Shift, adds to it).
        if store.dragSelectArmed {
            marqueeBase = shift ? store.selectionForEditing : []
            if !shift { store.selectClips([]) }
            marquee = NSRect(origin:origin,size:.zero); mode = .marquee
            needsDisplay = true; return
        }
        // With Shift the press is about choosing clips, so a transition strip under it does not take it.
        for transition in store.project.transitions.reversed() where !shift {
            let leading = [true,false].first { resizeHandle(transition,leading:$0)?.contains(origin) == true }
            guard leading != nil || rect(transition)?.contains(origin) == true else { continue }
            store.selectTransition(transition.id)
            if let leading, !store.isExporting {
                store.commitPendingEdits(); store.endInteraction(); store.pause()
                if let window = store.project.window(of:transition) {
                    transitionResize = TransitionResize(base:store.project,original:transition,leading:leading,
                                                        edge:leading ? window.start : window.end,candidate:transition)
                    NSCursor.resizeLeftRight.set()
                }
            }
            needsDisplay = true; return
        }
        if let clip = store.project.clips.last(where:{rect($0).contains(origin)}) {
            let box = rect(clip), grabbed = Set(store.project.group(for:clip.id).map(\.id))
            let edge: DragMode = origin.x-box.minX < 7 ? .start : box.maxX-origin.x < 7 ? .end : .move
            if shift {
                // Shift-click adds a clip (with its linked partner) to the selection, or takes it out.
                var ids = store.selectionForEditing
                if ids.contains(where:grabbed.contains) { ids.subtract(grabbed) } else { ids.insert(clip.id) }
                store.selectClips(ids); store.selectedGap = nil
                needsDisplay = true; return
            }
            let selection = store.selectionForEditing
            if selection.count > 1, selection.contains(where:grabbed.contains), edge == .move {
                // Dragging one of several selected clips moves them all together.
                group = selection; clickedInGroup = clip.id; original = clip; candidateValid = true; mode = .move
            } else {
                store.selectedClipID = clip.id; store.selectedGap = nil
                original = clip; candidate = clip; candidateValid = true
                mode = edge
            }
        } else {
            // Shift-drag over empty track space draws a rectangle that selects the clips it touches.
            if shift {
                marqueeBase = store.selectionForEditing; marquee = NSRect(origin:origin,size:.zero); mode = .marquee
                needsDisplay = true; return
            }
            store.selectClips([]); store.selectedTransitionID = nil
            // Double-clicking empty track space selects the gap it belongs to, for ⌘⌫.
            if event.clickCount == 2, let lane = lane(at:origin),
               let gap = Editing.gap(on:lane,at:time(at:origin.x),in:store.project) {
                store.selectGap(gap); mode = nil; needsDisplay = true; return
            }
            store.selectedGap = nil; mode = .scrub; store.pause(); scrub(at:origin,with:event)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event:NSEvent) {
        guard let store else { return }
        if var resize = transitionResize {
            guard store.project == resize.base, !store.isExporting else {
                transitionResize = nil; moved = false; needsDisplay = true; return
            }
            autoscrollHorizontally(with:event)
            let point = convert(event.locationInWindow,from:nil)
            guard moved || abs(point.x-origin.x) >= 2 else { return }
            moved = true
            var position = resize.edge+MediaTime(seconds:(point.x-origin.x)/pixelsPerSecond)
            var target: MediaTime?
            if store.snapping && !event.modifierFlags.contains(.shift) {
                target = Editing.snapTarget(position,excludingTransition:resize.original.id,playhead:store.playhead,threshold:.init(seconds:8/pixelsPerSecond),project:resize.base)
                position = store.project.frameRate.quantize(target ?? position)
            }
            var preview = resize.base
            if (try? Editing.resizeTransition(resize.original.id,leading:resize.leading,to:position,in:&preview)) != nil,
               let updated = preview.transitions.first(where: { $0.id == resize.original.id }) {
                resize.candidate = updated; transitionResize = resize
                feelSnap(target,event)
            } else { feelSnap(nil,event) }
            NSCursor.resizeLeftRight.set(); needsDisplay = true; return
        }
        guard let mode else { return }
        if mode == .marquee {
            autoscroll(with:event)
            let point = convert(event.locationInWindow,from:nil)
            let box = NSRect(x:min(origin.x,point.x),y:min(origin.y,point.y),width:abs(point.x-origin.x),height:abs(point.y-origin.y))
            marquee = box
            let touched = Set(store.project.clips.filter { rect($0).intersects(box) }.map(\.id))
            let ids = marqueeBase.union(touched)
            if ids != store.selectionForEditing { store.selectClips(ids) }
            needsDisplay = true; return
        }
        if let group, let original {
            autoscrollHorizontally(with:event)
            let point = convert(event.locationInWindow,from:nil)
            guard moved || abs(point.x-origin.x) >= 2 else { return }
            moved = true
            var position = original.start+MediaTime(seconds:(point.x-origin.x)/pixelsPerSecond)
            // The grabbed clip snaps to everything but the clips moving with it.
            var others = store.project; Editing.delete(group,from:&others)
            var target: MediaTime?
            if store.snapping && !event.modifierFlags.contains(.shift) {
                target = Editing.snapTarget(position,duration:original.duration,playhead:store.playhead,threshold:.init(seconds:8/pixelsPerSecond),project:others)
            }
            position = store.project.frameRate.quantize(target ?? position)
            let delta = position-original.start
            let moving = Set(group.flatMap { store.project.group(for:$0).map(\.id) })
            var copy = store.project
            do {
                try Editing.move(group,by:delta,in:&copy)
                groupGhosts = copy.clips.filter { moving.contains($0.id) }; candidateValid = true
                groupDelta = (copy.clips.first { $0.id == original.id }?.start ?? position)-original.start
                feelSnap(target,event)
            } catch {
                candidateValid = false; groupDelta = nil; feelSnap(nil,event)
                groupGhosts = store.project.clips.filter { moving.contains($0.id) }.map { var ghost = $0; ghost.start = max(.zero,ghost.start+delta); return ghost }
            }
            needsDisplay = true; return
        }
        // Only moving a clip can change track; scrubs and trims keep the tracks where they are.
        if mode == .move { autoscroll(with:event) } else { autoscrollHorizontally(with:event) }
        let point = convert(event.locationInWindow,from:nil)
        if mode == .scrub { scrub(at:point,with:event); return }
        guard let original else { return }
        if abs(point.x-origin.x)<2 && abs(point.y-origin.y)<2 { return }; moved = true
        let delta = MediaTime(seconds:(point.x-origin.x)/pixelsPerSecond)
        var position = (mode == .end ? original.end : original.start)+delta
        var target: MediaTime?
        if store.snapping && !event.modifierFlags.contains(.shift) {
            target = Editing.snapTarget(position,duration:mode == .move ? original.duration : .zero,excluding:original.id,playhead:store.playhead,threshold:.init(seconds:8/pixelsPerSecond),project:store.project)
        }
        position = store.project.frameRate.quantize(target ?? position)
        var copy = store.project
        do {
            if mode == .move { try Editing.move(original.id,to:position,lane:lane(at:point) ?? original.lane,in:&copy) }
            else { try Editing.trim(original.id,leading:mode == .start,to:position,in:&copy) }
            candidate = copy.clips.first(where:{$0.id == original.id}); candidateValid = true
            // Caught by a snap where the clip can go: a tick under the finger.
            feelSnap(target,event)
        } catch {
            candidateValid = false; feelSnap(nil,event)
            var ghost = original
            if mode == .move { ghost.start = max(.zero,position); if let lane = lane(at:point), lane.isVideo == original.lane.isVideo { ghost.lane = lane } }
            else if mode == .end { ghost.duration = max(store.project.frameRate.frame,position-original.start) }
            else { ghost.start = max(.zero,min(position,original.end-store.project.frameRate.frame)); ghost.duration = original.end-ghost.start }
            candidate = ghost
        }
        needsDisplay = true
    }
    private func autoscrollHorizontally(with event:NSEvent) {
        let point = convert(event.locationInWindow,from:nil), visible = visibleRect
        let inside = convert(NSPoint(x:point.x,y:min(max(point.y,visible.minY+1),visible.maxY-1)),to:nil)
        guard let clamped = NSEvent.mouseEvent(with:event.type,location:inside,modifierFlags:event.modifierFlags,timestamp:event.timestamp,
                                               windowNumber:event.windowNumber,context:nil,eventNumber:event.eventNumber,
                                               clickCount:event.clickCount,pressure:event.pressure) else { return }
        autoscroll(with:clamped)
    }
    override func mouseUp(with event:NSEvent) {
        if mode == .scrub { scrub(at:convert(event.locationInWindow,from:nil),with:event) }
        if let resize = transitionResize, let store, moved, store.project == resize.base {
            store.setTransitionDuration(resize.original.id,to:resize.candidate.duration)
        }
        if let store, let group {
            if moved, candidateValid, let delta = groupDelta, delta != .zero { store.moveClips(group,by:delta) }
            else if !moved, let id = clickedInGroup { store.selectedClipID = id }      // a click picks just that one
        } else if let store, let original, let candidate, moved, candidateValid {
            if mode == .move { store.move(original.id,to:candidate.start,lane:candidate.lane) }
            else if mode == .start { store.trim(original.id,leading:true,to:candidate.start) }
            else if mode == .end { store.trim(original.id,leading:false,to:candidate.end) }
        }
        // The toolbar's rectangle select is for one drag.
        if mode == .marquee, let store, store.dragSelectArmed { store.dragSelectArmed = false }
        mode = nil; original = nil; candidate = nil; transitionResize = nil; moved = false; needsDisplay = true
        group = nil; groupGhosts = []; groupDelta = nil; clickedInGroup = nil; marquee = nil
        resetScrubbing()
        window?.invalidateCursorRects(for:self)
    }
    // Standard Edit menu actions follow the responder chain. Text fields keep their
    // native text clipboard; these actions belong only to the focused timeline.
    @objc func copy(_ sender: Any?) { store?.copySelection() }
    @objc func cut(_ sender: Any?) { store?.cutSelection() }
    @objc func paste(_ sender: Any?) { store?.pasteClips() }
    @objc override func selectAll(_ sender: Any?) { store?.selectAllClips(); needsDisplay = true }
    func validateUserInterfaceItem(_ item:any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) || item.action == #selector(cut(_:)) { return store?.canCopyClip == true && store?.isExporting == false }
        if item.action == #selector(selectAll(_:)) { return store?.project.clips.isEmpty == false }
        if item.action == #selector(paste(_:)) { return store?.canPasteClip == true }
        return false
    }
    /// ⌘ plus a letter. A Korean (or other non-Latin) input source may not produce the Latin
    /// letter, so there the physical key counts; on a Latin layout the letter itself does, or ⌘Q
    /// on AZERTY (the A key) or Dvorak (the X key) would select all or cut.
    static func isCommand(_ event: NSEvent, _ letter: String, keyCode: UInt16) -> Bool {
        if let typed = event.charactersIgnoringModifiers?.lowercased(), let first = typed.unicodeScalars.first, first.isASCII { return typed == letter }
        return event.keyCode == keyCode
    }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command,.shift,.option,.control])
        if window?.firstResponder === self, modifiers == [.command], let store {
            if Self.isCommand(event,"c",keyCode:8), store.canCopyClip { copy(nil); return true }
            if Self.isCommand(event,"v",keyCode:9), store.canPasteClip { paste(nil); return true }
            if Self.isCommand(event,"x",keyCode:7), store.canCopyClip, !store.isExporting { cut(nil); return true }
            if Self.isCommand(event,"a",keyCode:0), !store.project.clips.isEmpty { selectAll(nil); return true }
        }
        return super.performKeyEquivalent(with:event)
    }
    override func keyDown(with event:NSEvent) {
        guard let store else { return }
        // A Korean input source may not produce the Latin menu equivalent, so the timeline's
        // own commands also work from here by key position; text fields keep their own keys.
        if let command = ShortcutSettings.shared.command(matching:event), store.performFromKeyboard(command,repeating:event.isARepeat) { return }
        if event.modifierFlags.intersection([.command,.shift,.option,.control]) == [.command] {
            if Self.isCommand(event,"c",keyCode:8) { copy(nil); return }
            if Self.isCommand(event,"v",keyCode:9) { paste(nil); return }
        }
        let modifiers = event.modifierFlags.intersection(Shortcut.modifierMask)
        switch event.keyCode {
        // Shift-arrows move ten frames, whatever the frame keys are set to.
        case 123 where modifiers == [.shift]: store.step(-10)
        case 124 where modifiers == [.shift]: store.step(10)
        case 117 where modifiers.isEmpty: store.deleteSelection()
        case 53:
            resetScrubbing()
            if transitionResize != nil {
                transitionResize = nil; moved = false; needsDisplay = true; window?.invalidateCursorRects(for:self); return
            }
            mode = nil; candidate = nil; original = nil; moved = false; store.selectedGap = nil; store.previewTransformID = nil; store.selectedTransitionID = nil
            clearGroupGesture()
            if store.dragSelectArmed { store.dragSelectArmed = false }
            else if store.selectedClipIDs.count > 1 { store.selectClips([]) }
            needsDisplay = true
        // Return (or Enter) finishes a transform in the preview, keeping it, as it does there.
        case 36,76 where store.previewTransformID != nil && PreviewTransformOverlay.isReturn(event):
            store.previewTransformID = nil
        default: super.keyDown(with:event)
        }
    }
    override func magnify(with event:NSEvent) { if let store { store.zoom = min(220,max(8,store.zoom*(1+event.magnification))) } }
    /// Validate the position used by both the ghost and the final drop. Haptics must
    /// never advertise a missing source, incompatible track or occupied linked lane.
    private func mediaDropTarget(_ id: UUID, at point: NSPoint) -> MediaDropTarget? {
        guard let store, !store.isExporting, !store.isCapturingSnapshot,
              !store.showLauncher, !store.showExportSheet, !store.showNewProjectSheet,
              !store.missing.contains(id), let lane = lane(at:point) else { return nil }
        let raw = time(at:point.x), threshold = MediaTime(seconds:8/pixelsPerSecond)
        let snapping = store.snapping && !NSEvent.modifierFlags.contains(.shift)
        let position = snapping ? Editing.snapped(raw,playhead:store.playhead,threshold:threshold,project:store.project)
                                : store.project.frameRate.quantize(raw)
        var preview = store.project
        guard (try? Editing.add(mediaID:id,lane:lane,at:position,to:&preview)) != nil else { return nil }
        // Checking the actual edges also recognizes a pointer exactly on an edge;
        // ordinary frame rounding alone must not produce an alignment cue.
        let edges = [.zero,store.playhead] + store.project.clips.flatMap { [$0.start,$0.end] }
        let aligned = snapping && edges.contains {
            abs($0.ticks-raw.ticks) <= threshold.ticks && store.project.frameRate.quantize($0) == position
        }
        return MediaDropTarget(id:id,lane:lane,time:position,snappedTime:aligned ? position : nil)
    }
    override func draggingEntered(_ sender:any NSDraggingInfo) -> NSDragOperation {
        if mediaDragSequence != sender.draggingSequenceNumber {
            mediaDropFeedback = MediaDropFeedback(); mediaDragSequence = sender.draggingSequenceNumber
        }
        return draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender:any NSDraggingInfo) -> NSDragOperation {
        dropped = nil; transitionDrop = nil
        var feedbackTarget: MediaDropTarget?
        defer {
            needsDisplay = true
            if let cue = mediaDropFeedback.cue(for:feedbackTarget,at:ProcessInfo.processInfo.systemUptime,
                                              enabled:store?.haptics(.mediaDrop) == true) { performHaptic(cue) }
        }
        guard store != nil else { return [] }
        let point = convert(sender.draggingLocation,from:nil)
        if let kind = TransitionDrag.kind(from:sender.draggingPasteboard) {
            transitionDrop = transitionTarget(kind,at:point)
            // Over a new cut or clip edge the transition would go on: a tick.
            let edge = transitionDrop.map { TransitionEdge(from:$0.transition.from,to:$0.transition.to) }
            if transitionDropFeedback.cue(for:edge,at:ProcessInfo.processInfo.systemUptime,enabled:store?.haptics(.transitions) == true) { performHaptic(.alignment) }
            return transitionDrop == nil ? [] : .copy
        }
        if let value = sender.draggingPasteboard.string(forType:.string), let id = UUID(uuidString:value) {
            guard let target = mediaDropTarget(id,at:point) else { return [] }
            dropped = (target.id,target.lane,target.time); feedbackTarget = target
            return .copy
        }
        return sender.draggingPasteboard.canReadObject(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) ? .copy : []
    }
    private func clearDropFeedback() {
        dropped = nil; transitionDrop = nil; needsDisplay = true
        _ = mediaDropFeedback.cue(for:nil,at:ProcessInfo.processInfo.systemUptime,enabled:false)
        _ = transitionDropFeedback.cue(for:nil,at:ProcessInfo.processInfo.systemUptime,enabled:false)
    }
    override func draggingExited(_ sender:(any NSDraggingInfo)?) { clearDropFeedback() }
    override func draggingEnded(_ sender:any NSDraggingInfo) {
        clearDropFeedback(); mediaDropFeedback = MediaDropFeedback(); transitionDropFeedback = CatchFeedback(); mediaDragSequence = nil
    }
    override func performDragOperation(_ sender:any NSDraggingInfo) -> Bool {
        guard let store else { return false }
        defer { clearDropFeedback() }
        if let kind = TransitionDrag.kind(from:sender.draggingPasteboard) {
            guard let drop = transitionTarget(kind,at:convert(sender.draggingLocation,from:nil)) else { return false }
            let applied = store.applyTransition(kind,from:drop.transition.from,to:drop.transition.to)
            if applied { window?.makeFirstResponder(self); if store.haptics(.transitions) { performHaptic(.generic) } }
            return applied
        }
        if let value = sender.draggingPasteboard.string(forType:.string), let id = UUID(uuidString:value) {
            // Re-evaluate at mouse-up: the location or project may have changed
            // since the last draggingUpdated. Only a committed add earns a cue.
            guard let target = mediaDropTarget(id,at:convert(sender.draggingLocation,from:nil)),
                  store.addMedia(id,lane:target.lane,at:target.time) else { return false }
            if store.haptics(.mediaDrop) { performHaptic(.generic) }
            window?.makeFirstResponder(self)
            return true
        }
        if let files = sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] { store.importFiles(files); return true }
        return false
    }
}
