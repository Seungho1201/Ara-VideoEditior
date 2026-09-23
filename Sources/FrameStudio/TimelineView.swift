import SwiftUI
import AppKit
import FrameCore

struct TimelineView: View {
    @ObservedObject var store: EditorStore
    var body: some View {
        HStack(spacing:0) {
            VStack(spacing:0) {
                Text("TRACKS").font(.system(size:8,weight:.bold)).tracking(1).foregroundStyle(Theme.muted).frame(height:28)
                ForEach(Lane.displayOrder) { lane in
                    HStack(spacing:7) {
                        RoundedRectangle(cornerRadius:1).fill(lane.isVideo ? Color.blue.opacity(0.8) : Theme.accent).frame(width:3,height:22)
                        VStack(alignment:.leading,spacing:4) { Text(lane.rawValue).font(.system(size:11,weight:.semibold)); Text(lane.isVideo ? (lane == .v2 ? "Overlay" : "Picture") : "Audio").font(.system(size:8)).foregroundStyle(Theme.muted) }
                        Spacer(minLength:0)
                    }.padding(.leading,12).frame(height:62).overlay(alignment:.bottom){Divider()}
                }
                Spacer(minLength:0)
            }.frame(width:78).background(Theme.panel)
            Rectangle().fill(.white.opacity(0.08)).frame(width:1)
            TimelineSurface(store:store)
        }.background(Theme.background)
    }
}

struct TimelineSurface: NSViewRepresentable {
    @ObservedObject var store: EditorStore
    func makeNSView(context:Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false; scroll.autohidesScrollers = false
        scroll.drawsBackground = false; scroll.scrollerStyle = .legacy
        let canvas = TimelineCanvas(); canvas.store = store; scroll.documentView = canvas
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let canvas = scroll.documentView as? TimelineCanvas else { return }
        let oldZoom = canvas.pixelsPerSecond
        canvas.store = store; canvas.pixelsPerSecond = store.zoom
        canvas.setFrameSize(NSSize(width:max(scroll.contentSize.width,(max(20,store.project.duration.seconds)+8)*store.zoom),height:max(276,scroll.contentSize.height)))
        if oldZoom != store.zoom {
            let x = max(0,min(canvas.frame.width-scroll.contentSize.width,store.playhead.seconds*store.zoom-scroll.contentSize.width*0.45))
            scroll.contentView.scroll(to:NSPoint(x:x,y:0)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        if canvas.revealPlayheadRequest != store.revealPlayheadRequest {
            canvas.revealPlayheadRequest = store.revealPlayheadRequest
            let x = store.playhead.seconds*store.zoom
            let visible = scroll.contentView.bounds
            if x < visible.minX+12 || x > visible.maxX-12 {
                let offset = max(0,min(canvas.frame.width-visible.width,x-visible.width*0.5))
                scroll.contentView.scroll(to:NSPoint(x:offset,y:0)); scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        canvas.needsDisplay = true
    }
}

@MainActor final class TimelineCanvas: NSView, NSUserInterfaceValidations {
    weak var store: EditorStore?
    var pixelsPerSecond: Double = 64
    var revealPlayheadRequest = 0
    private let ruler: Double = 28
    private let rowHeight: Double = 62
    private enum DragMode { case move, start, end, scrub }
    private var mode: DragMode?
    private var origin = NSPoint.zero
    private var original: Clip?
    private var candidate: Clip?
    private var candidateValid = true
    private var dropped: (UUID,Lane,MediaTime)?
    private var moved = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override init(frame:NSRect) {
        super.init(frame:frame)
        registerForDraggedTypes([.string,.fileURL]); setAccessibilityElement(true)
        setAccessibilityRole(.group); setAccessibilityLabel("Multitrack timeline. V2 above V1. A1 and A2 linked audio.")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func rect(_ clip:Clip) -> NSRect {
        let index = Lane.displayOrder.firstIndex(of:clip.lane) ?? 0
        return NSRect(x:clip.start.seconds*pixelsPerSecond,y:ruler+Double(index)*rowHeight+5,width:max(2,clip.duration.seconds*pixelsPerSecond),height:rowHeight-10)
    }
    private func lane(at point:NSPoint) -> Lane? {
        let index = Int(floor((point.y-ruler)/rowHeight)); return Lane.displayOrder.indices.contains(index) ? Lane.displayOrder[index] : nil
    }
    private func time(at x:Double) -> MediaTime { .init(seconds:max(0,x/pixelsPerSecond)) }
    private func label(_ text:String,at point:NSPoint,size:CGFloat = 10,color:NSColor = .secondaryLabelColor) {
        (text as NSString).draw(at:point,withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:size,weight:.medium),.foregroundColor:color])
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let store else { return }
        NSColor(red:0.055,green:0.065,blue:0.085,alpha:1).setFill(); dirtyRect.fill()
        let visible = visibleRect.intersection(dirtyRect)
        for index in 0..<4 {
            let row = NSRect(x:visible.minX,y:ruler+Double(index)*rowHeight,width:visible.width,height:rowHeight)
            NSColor(white:index%2 == 0 ? 0.11 : 0.09,alpha:1).setFill(); row.fill()
            NSColor(white:0.19,alpha:1).setStroke(); let line = NSBezierPath(); line.move(to:NSPoint(x:visible.minX,y:row.maxY)); line.line(to:NSPoint(x:visible.maxX,y:row.maxY)); line.stroke()
        }
        let interval: Double = pixelsPerSecond > 100 ? 1 : pixelsPerSecond > 40 ? 2 : pixelsPerSecond > 15 ? 5 : 10
        let first = floor(visible.minX/pixelsPerSecond/interval)*interval
        let last = ceil(visible.maxX/pixelsPerSecond/interval)*interval
        for second in stride(from:first,through:last,by:interval) {
            let x = second*pixelsPerSecond
            NSColor(white:0.22,alpha:1).setStroke(); let line = NSBezierPath(); line.move(to:NSPoint(x:x,y:20)); line.line(to:NSPoint(x:x,y:bounds.height)); line.lineWidth = 0.5; line.stroke()
            label(String(format:"%02d:%02d",Int(second)/60,Int(second)%60),at:NSPoint(x:x+5,y:7),size:9)
        }
        let linked = Set(store.selectedClipID.map { store.project.group(for:$0).map(\.id) } ?? [])
        for clip in store.project.clips {
            let box = rect(clip)
            guard box.intersects(visible) else { continue }
            drawClip(clip,box:box,selected:linked.contains(clip.id),ghost:false)
        }
        if let candidate, moved {
            drawClip(candidate,box:rect(candidate),selected:true,ghost:true)
            if let original, let link = original.linkID,
               let audio = store.project.clips.first(where:{$0.linkID == link && $0.id != original.id}) {
                var linked = audio; linked.start = candidate.start; linked.duration = candidate.duration; linked.lane = candidate.lane.paired
                drawClip(linked,box:rect(linked),selected:true,ghost:true)
            }
            label(candidateValid ? store.project.frameRate.timecode(candidate.start) : "Track occupied / source limit",at:NSPoint(x:max(visible.minX+5,rect(candidate).minX),y:rect(candidate).maxY-16),size:10,color:candidateValid ? .white : .systemRed)
        }
        if let gap = store.selectedGap {
            let row = Lane.displayOrder.firstIndex(of:gap.lane) ?? 0
            let box = NSRect(x:gap.start.seconds*pixelsPerSecond,y:ruler+Double(row)*rowHeight+5,
                             width:max(3,gap.duration.seconds*pixelsPerSecond),height:rowHeight-10)
            if box.intersects(visible) {
                let path = NSBezierPath(roundedRect:box.insetBy(dx:1,dy:1),xRadius:4,yRadius:4)
                NSColor.white.withAlphaComponent(0.14).setFill(); path.fill()
                NSColor.white.setStroke(); path.lineWidth = 2; path.stroke()
                if box.width > 132 { label("⌘⌫ close gap · \(store.project.frameRate.timecode(gap.duration))",at:NSPoint(x:box.minX+8,y:box.midY-6),size:9,color:.white) }
            }
        }
        if let (id,lane,time) = dropped, let media = store.project.media.first(where:{$0.id == id}) {
            let clip = Clip(mediaID:id,name:media.name,kind:media.kind,lane:lane,start:time,duration:media.duration)
            Theme.accentNS.withAlphaComponent(0.3).setFill(); NSBezierPath(roundedRect:rect(clip),xRadius:4,yRadius:4).fill()
        }
        let x = store.playhead.seconds*pixelsPerSecond
        if x >= visible.minX-10 && x <= visible.maxX+10 {
            let color = Theme.accentNS; color.setStroke(); color.setFill()
            let line = NSBezierPath(); line.move(to:NSPoint(x:x,y:0)); line.line(to:NSPoint(x:x,y:bounds.height)); line.lineWidth = 1.5; line.stroke()
            let head = NSBezierPath(); head.move(to:NSPoint(x:x-5,y:0)); head.line(to:NSPoint(x:x+5,y:0)); head.line(to:NSPoint(x:x+5,y:8)); head.line(to:NSPoint(x:x,y:13)); head.line(to:NSPoint(x:x-5,y:8)); head.close(); head.fill()
        }
        if store.project.clips.isEmpty { label("Drag media onto V1 / V2 or A1 / A2",at:NSPoint(x:visible.minX+24,y:ruler+85),size:13,color:NSColor(white:0.45,alpha:1)) }
    }
    private func drawClip(_ clip:Clip,box:NSRect,selected:Bool,ghost:Bool) {
        guard let store else { return }
        let color: NSColor = clip.kind == .audio ? NSColor(red:0.16,green:0.28,blue:0.42,alpha:1) : clip.kind == .text ? NSColor(red:0.39,green:0.29,blue:0.51,alpha:1) : NSColor(red:0.18,green:0.31,blue:0.5,alpha:1)
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(roundedRect:box,xRadius:4,yRadius:4); path.addClip()
        color.withAlphaComponent(ghost ? 0.6 : 1).setFill(); box.fill()
        if !ghost {
            if clip.kind == .audio, let id = clip.mediaID, let peaks = store.waveforms[id], !peaks.isEmpty, let media = store.project.media(for:clip) {
                let visible = box.intersection(visibleRect)
                let waveform = NSBezierPath(); let center = box.minY+35
                for x in stride(from:visible.minX,to:visible.maxX,by:2) {
                    // A retimed clip walks the source at its own rate, or a 2x clip would
                    // draw only the first half of the audio it actually plays.
                    let source = clip.sourceStart.seconds+(x-box.minX)/pixelsPerSecond*clip.speed
                    let index = min(peaks.count-1,max(0,Int(source/max(0.001,media.duration.seconds)*Double(peaks.count))))
                    let amplitude = max(1,Double(peaks[index])*17)
                    waveform.move(to:NSPoint(x:x,y:center-amplitude)); waveform.line(to:NSPoint(x:x,y:center+amplitude))
                }
                Theme.accentNS.withAlphaComponent(0.85).setStroke(); waveform.lineWidth = 1; waveform.stroke()
            } else if let id = clip.mediaID, let image = store.thumbnails[id] {
                let strip = NSRect(x:box.minX,y:box.minY+20,width:82,height:box.height-20)
                let first = max(0,Int((visibleRect.minX-box.minX)/82))
                let last = min(Int(ceil(box.width/82)),Int(ceil((visibleRect.maxX-box.minX)/82)))
                if first < last { for tile in first..<last { image.draw(in:strip.offsetBy(dx:Double(tile)*82,dy:0),from:.zero,operation:.sourceOver,fraction:0.6,respectFlipped:true,hints:nil) } }
            }
            NSColor.black.withAlphaComponent(0.25).setFill(); NSRect(x:box.minX,y:box.minY,width:box.width,height:20).fill()
            let speedTag = clip.speed == 1 ? "" : String(format:"%.2fx ",clip.speed)
            label((clip.linkID == nil ? "" : "↔ ")+speedTag+(clip.kind == .text ? clip.style.text : clip.name),at:NSPoint(x:max(box.minX+7,visibleRect.minX+4),y:box.minY+4),size:10,color:.white)
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
        window?.makeFirstResponder(self); origin = convert(event.locationInWindow,from:nil); moved = false
        if origin.y < ruler { mode = .scrub; store.pause(); store.seek(time(at:origin.x)); return }
        if let clip = store.project.clips.last(where:{rect($0).contains(origin)}) {
            store.selectedClipID = clip.id; store.selectedGap = nil
            original = clip; candidate = clip; candidateValid = true
            let box = rect(clip)
            mode = origin.x-box.minX < 7 ? .start : box.maxX-origin.x < 7 ? .end : .move
        } else {
            store.selectedClipID = nil
            // Double-clicking empty track space selects the gap it belongs to, for ⌘⌫.
            if event.clickCount == 2, let lane = lane(at:origin),
               let gap = Editing.gap(on:lane,at:time(at:origin.x),in:store.project) {
                store.selectGap(gap); mode = nil; needsDisplay = true; return
            }
            store.selectedGap = nil; mode = .scrub; store.pause(); store.seek(time(at:origin.x))
        }
        needsDisplay = true
    }
    override func mouseDragged(with event:NSEvent) {
        guard let store, let mode else { return }
        autoscroll(with:event)
        let point = convert(event.locationInWindow,from:nil)
        if mode == .scrub { store.seek(time(at:point.x)); return }
        guard let original else { return }
        if abs(point.x-origin.x)<2 && abs(point.y-origin.y)<2 { return }; moved = true
        let delta = MediaTime(seconds:(point.x-origin.x)/pixelsPerSecond)
        var position = (mode == .end ? original.end : original.start)+delta
        if store.snapping && !event.modifierFlags.contains(.shift) {
            position = Editing.snapped(position,duration:mode == .move ? original.duration : .zero,excluding:original.id,playhead:store.playhead,threshold:.init(seconds:8/pixelsPerSecond),project:store.project)
        } else { position = store.project.frameRate.quantize(position) }
        var copy = store.project
        do {
            if mode == .move { try Editing.move(original.id,to:position,lane:lane(at:point) ?? original.lane,in:&copy) }
            else { try Editing.trim(original.id,leading:mode == .start,to:position,in:&copy) }
            candidate = copy.clips.first(where:{$0.id == original.id}); candidateValid = true
        } catch {
            candidateValid = false
            var ghost = original
            if mode == .move { ghost.start = max(.zero,position); if let lane = lane(at:point), lane.isVideo == original.lane.isVideo { ghost.lane = lane } }
            else if mode == .end { ghost.duration = max(store.project.frameRate.frame,position-original.start) }
            else { ghost.start = max(.zero,min(position,original.end-store.project.frameRate.frame)); ghost.duration = original.end-ghost.start }
            candidate = ghost
        }
        needsDisplay = true
    }
    override func mouseUp(with event:NSEvent) {
        if let store, let original, let candidate, moved, candidateValid {
            if mode == .move { store.move(original.id,to:candidate.start,lane:candidate.lane) }
            else if mode == .start { store.trim(original.id,leading:true,to:candidate.start) }
            else if mode == .end { store.trim(original.id,leading:false,to:candidate.end) }
        }
        mode = nil; original = nil; candidate = nil; moved = false; needsDisplay = true
    }
    // Standard Edit menu actions follow the responder chain. Text fields keep their
    // native text clipboard; these actions belong only to the focused timeline.
    @objc func copy(_ sender: Any?) { store?.copySelection() }
    @objc func paste(_ sender: Any?) { store?.pasteClips() }
    func validateUserInterfaceItem(_ item:any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return store?.canCopyClip == true }
        if item.action == #selector(paste(_:)) { return store?.canPasteClip == true }
        return false
    }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command,.shift,.option,.control])
        if window?.firstResponder === self, modifiers == [.command] {
            if event.keyCode == 8 { copy(nil); return true }
            if event.keyCode == 9 { paste(nil); return true }
        }
        return super.performKeyEquivalent(with:event)
    }
    override func keyDown(with event:NSEvent) {
        guard let store else { return }
        if event.modifierFlags.intersection([.command,.shift,.option,.control]) == [.command] {
            if event.keyCode == 8 { copy(nil); return }
            if event.keyCode == 9 { paste(nil); return }
        }
        switch event.keyCode {
        case 123:
            if event.modifierFlags.contains(.option) { store.goToSelectedClipStart() }
            else { store.step(event.modifierFlags.contains(.shift) ? -10 : -1) }
        case 124:
            if event.modifierFlags.contains(.option) { store.goToSelectedClipEnd() }
            else { store.step(event.modifierFlags.contains(.shift) ? 10 : 1) }
        case 49: store.togglePlayback()
        case 51,117: store.deleteSelection()
        case 53: mode = nil; candidate = nil; original = nil; moved = false; store.selectedGap = nil; store.previewTransformID = nil; needsDisplay = true
        default: super.keyDown(with:event)
        }
    }
    override func magnify(with event:NSEvent) { if let store { store.zoom = min(220,max(8,store.zoom*(1+event.magnification))) } }
    override func draggingEntered(_ sender:any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender:any NSDraggingInfo) -> NSDragOperation {
        guard let store else { return [] }
        let point = convert(sender.draggingLocation,from:nil)
        if let value = sender.draggingPasteboard.string(forType:.string), let id = UUID(uuidString:value), let lane = lane(at:point) {
            let position = store.snapping ? Editing.snapped(time(at:point.x),playhead:store.playhead,threshold:.init(seconds:8/pixelsPerSecond),project:store.project) : store.project.frameRate.quantize(time(at:point.x))
            var p = store.project
            if (try? Editing.add(mediaID:id,lane:lane,at:position,to:&p)) != nil { dropped = (id,lane,position); needsDisplay = true; return .copy }
            dropped = nil; needsDisplay = true; return []
        }
        return sender.draggingPasteboard.canReadObject(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) ? .copy : []
    }
    override func draggingExited(_ sender:(any NSDraggingInfo)?) { dropped = nil; needsDisplay = true }
    override func performDragOperation(_ sender:any NSDraggingInfo) -> Bool {
        guard let store else { return false }
        defer { dropped = nil; needsDisplay = true }
        if let (id,lane,time) = dropped { store.addMedia(id,lane:lane,at:time); return true }
        if let files = sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] { store.importFiles(files); return true }
        return false
    }
}
