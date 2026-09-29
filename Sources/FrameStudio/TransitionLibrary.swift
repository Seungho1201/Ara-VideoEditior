import SwiftUI
import AppKit
import CoreImage
import FrameCore
import FrameMedia

/// The right-hand panel: the inspector, or the transitions to drag onto the timeline.
struct SidePanel: View {
    @ObservedObject var store: EditorStore
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            SidePanelTabs(store:store)
            Divider()
            switch store.sidePanel {
            case .inspector: InspectorPanel(store:store)
            case .transitions: TransitionLibrary(store:store)
            }
        }.background(Theme.panel)
    }
}

/// The side panel's tabs. The titles take the room first, each on one line: at the panel's
/// narrowest they fit whole (a longer one would shrink a little), never broken mid-word.
struct SidePanelTabs: View {
    @ObservedObject var store: EditorStore
    var body: some View {
        HStack(spacing:0) {
            HStack(spacing:16) {
                ForEach(EditorStore.SidePanel.allCases,id:\.self) { tab in
                    let tip = tab == .inspector ? "Settings of the selected clip" : "Transitions: drag onto a cut"
                    Button { store.sidePanel = tab } label: {
                        Text(LocalizedStringKey(tab.rawValue)).font(.system(size:10,weight:.bold)).tracking(1.7)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(store.sidePanel == tab ? Color.primary : Theme.muted)
                            .padding(.bottom,4)
                            .overlay(alignment:.bottom) { Rectangle().fill(store.sidePanel == tab ? Theme.accent : .clear).frame(height:2) }
                    }.buttonStyle(.plain).accessibilityAddTraits(store.sidePanel == tab ? .isSelected : [])
                    .helpTip(tip,.below)
                }
            }.layoutPriority(1)
            Spacer(minLength:12)
            Image(systemName:store.sidePanel == .inspector ? "slider.horizontal.3" : "square.on.square").foregroundStyle(Theme.muted)
        }.padding(.horizontal,16).padding(.top,16).padding(.bottom,12)
    }
}

/// Every transition by category, with a still of it part-way through that plays when hovered.
/// Drag one onto a cut or a clip's edge in the timeline, or click it to put it on the selected
/// clip's start or end. With a transition selected (one just added included), a click swaps its
/// kind, so kinds can be tried one after another.
struct TransitionLibrary: View {
    @ObservedObject var store: EditorStore
    @State private var atEnd = true
    @State private var hovered: TransitionKind?
    private let columns = [GridItem(.flexible(),spacing:10),GridItem(.flexible(),spacing:10)]
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                if let transition = store.selectedTransition {
                    VStack(alignment:.leading,spacing:6) {
                        Text("Replace \(transition.kind.displayName)").font(.system(size:11,weight:.medium)).lineLimit(1)
                        Text("Click another transition to try it in its place.")
                            .font(.system(size:11)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                    }
                } else if let clip = store.selectedClip, clip.lane.isVideo {
                    VStack(alignment:.leading,spacing:6) {
                        Text("Apply to \(clip.name)").font(.system(size:11,weight:.medium)).lineLimit(1)
                        Picker("",selection:$atEnd) { Text(edgeLabel(end:false)).tag(false); Text(edgeLabel(end:true)).tag(true) }
                            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    }
                } else {
                    Text("Drag a transition onto a cut or a clip's edge. On a clip, the nearest edge is used. Or select a clip and click one.")
                        .font(.system(size:11)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                }
                ForEach(TransitionKind.Category.allCases,id:\.self) { category in
                    VStack(alignment:.leading,spacing:8) {
                        Text(category.displayName.uppercased()).font(.system(size:9,weight:.bold)).tracking(1.4).foregroundStyle(Theme.muted)
                        LazyVGrid(columns:columns,spacing:12) {
                            ForEach(TransitionKind.allCases.filter { $0.category == category }) { kind in
                                Button { apply(kind) } label: { tile(kind) }
                                    .buttonStyle(.plain)
                                    .onHover { inside in if inside { hovered = kind } else if hovered == kind { hovered = nil } }
                                    // AppKit owns the entire mouse sequence, just as it does for
                                    // media cards. A SwiftUI Button's press must not consume the drag.
                                    .overlay { TransitionDragHandle(kind:kind,apply:{ apply(kind) }).accessibilityHidden(true) }
                                    .help(store.selectedTransition != nil ? "Click to put it in place of the selected transition · or drag onto the timeline"
                                          : store.selectedClip == nil ? "Drag onto the timeline"
                                          : atEnd ? "Click to add to the selected clip's end · or drag onto the timeline" : "Click to add to the selected clip's start · or drag onto the timeline")
                                    .accessibilityLabel("\(kind.displayName) transition")
                            }
                        }
                    }
                }
            }.padding(14)
        }
    }
    private func edgeLabel(end: Bool) -> String {
        guard let edge = store.transitionEdge(ofSelectedClipAtEnd:end) else { return end ? String(localized:"End") : String(localized:"Start") }
        let cut = edge.from != nil && edge.to != nil
        return end ? (cut ? String(localized:"End · to next") : String(localized:"End · fade out"))
                   : (cut ? String(localized:"Start · from previous") : String(localized:"Start · fade in"))
    }
    private func apply(_ kind: TransitionKind) {
        // Same edge, length and direction: only the kind changes.
        if store.selectedTransition != nil { store.updateSelectedTransition(kind:kind); return }
        guard let edge = store.transitionEdge(ofSelectedClipAtEnd:atEnd) else {
            store.status = String(localized:"Select a video, image or title clip first, or drag \(kind.displayName) onto the timeline"); return
        }
        store.applyTransition(kind,from:edge.from,to:edge.to)
    }
    private func tile(_ kind: TransitionKind) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Group {
                if hovered == kind {
                    SwiftUI.TimelineView(.animation(minimumInterval:1/30)) { context in
                        Image(nsImage:TransitionPreviews.frame(kind,at:context.date)).resizable()
                    }
                } else {
                    Image(nsImage:TransitionPreviews.image(kind)).resizable()
                }
            }
            .aspectRatio(16/9,contentMode:.fit)
            .clipShape(RoundedRectangle(cornerRadius:4))
            .overlay(RoundedRectangle(cornerRadius:4).stroke(hovered == kind ? Theme.accent : .white.opacity(0.12),lineWidth:1))
            Text(kind.displayName).font(.system(size:10,weight:.medium)).lineLimit(1)
        }.contentShape(Rectangle())
    }
}

extension TransitionDirection {
    /// The direction as the inspector names it to VoiceOver, in Ara's language.
    var displayName: String {
        switch self {
        case .left: String(localized:"Left")
        case .right: String(localized:"Right")
        case .up: String(localized:"Up")
        case .down: String(localized:"Down")
        }
    }
}

/// What a transition carries while it is dragged onto the timeline.
enum TransitionDrag {
    static let pasteboardType = NSPasteboard.PasteboardType("com.framestudio.transition-kind")
    static let prefix = "ara.transition:"
    static func payload(_ kind: TransitionKind) -> String { prefix+kind.rawValue }
    static func kind(from text: String) -> TransitionKind? {
        guard text.hasPrefix(prefix) else { return nil }
        return TransitionKind(rawValue:String(text.dropFirst(prefix.count)))
    }
    static func kind(from pasteboard: NSPasteboard) -> TransitionKind? {
        if let value = pasteboard.string(forType:pasteboardType) { return TransitionKind(rawValue:value) }
        return pasteboard.string(forType:.string).flatMap { kind(from:$0) }
    }
}

private struct TransitionDragHandle: NSViewRepresentable {
    let kind: TransitionKind
    let apply: () -> Void
    func makeNSView(context: Context) -> TransitionDragView { TransitionDragView() }
    func updateNSView(_ view: TransitionDragView, context: Context) {
        view.kind = kind; view.apply = apply
    }
}

@MainActor private final class TransitionDragView: NSView, NSDraggingSource {
    var kind: TransitionKind = .crossDissolve
    var apply: (() -> Void)?
    private var origin = NSPoint.zero
    private var didDrag = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow,from:nil); didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        guard !didDrag, hypot(point.x-origin.x,point.y-origin.y) > 4 else { return }
        didDrag = true
        // Eager native data is readable by TimelineCanvas throughout the drag, including
        // its first draggingEntered call. Keep the text representation for compatibility.
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(kind.rawValue,forType:TransitionDrag.pasteboardType)
        pasteboard.setString(TransitionDrag.payload(kind),forType:.string)
        let item = NSDraggingItem(pasteboardWriter:pasteboard)
        item.setDraggingFrame(NSRect(x:point.x-64,y:point.y-36,width:128,height:72),contents:TransitionPreviews.image(kind))
        beginDraggingSession(with:[item],event:event,source:self)
    }
    override func mouseUp(with event: NSEvent) {
        // Cancelling a drag (including Escape) must never turn it into a click-to-apply.
        guard !didDrag, bounds.contains(convert(event.locationInWindow,from:nil)) else { return }
        apply?()
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

/// Stills of each transition part-way through, and short loops of it for hovering, drawn by the
/// renderer the timeline uses, from a cool outgoing picture to a warm incoming one.
@MainActor enum TransitionPreviews {
    private struct Key: Hashable { let kind: TransitionKind; let direction: TransitionDirection }
    private static var stills: [Key:NSImage] = [:]
    private static var loops: [Key:[NSImage]] = [:]
    private static let context = FrameRenderer.makeContext()
    private static let canvas = CGRect(x:0,y:0,width:192,height:108)
    private static let loopFrames = 36, loopSeconds = 1.8
    static func image(_ kind: TransitionKind, direction: TransitionDirection = .left) -> NSImage {
        let key = Key(kind:kind,direction:direction)
        if let cached = stills[key] { return cached }
        let image = render(kind,direction,kind.needsBothPictures ? 0.4 : 0.3)
        stills[key] = image
        return image
    }
    /// The hover loop at `date`: the transition, then a beat on the incoming picture.
    static func frame(_ kind: TransitionKind, direction: TransitionDirection = .left, at date: Date) -> NSImage {
        let key = Key(kind:kind,direction:direction)
        let frames = loops[key] ?? (0..<loopFrames).map { render(kind,direction,min(1,Double($0)/Double(loopFrames-8))) }
        loops[key] = frames
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:loopSeconds)/loopSeconds
        return frames[min(frames.count-1,Int(phase*Double(frames.count)))]
    }
    private static func render(_ kind: TransitionKind, _ direction: TransitionDirection, _ progress: Double) -> NSImage {
        func picture(_ top: CIColor, _ bottom: CIColor, sun: CIColor) -> CIImage {
            let sky = CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(x:0,y:canvas.maxY),"inputPoint1":CIVector(x:0,y:0),
                                                                    "inputColor0":top,"inputColor1":bottom])!.outputImage!.cropped(to:canvas)
            let disc = CIFilter(name:"CIRadialGradient",parameters:["inputCenter":CIVector(x:canvas.width*0.7,y:canvas.height*0.62),"inputRadius0":13,"inputRadius1":15,
                                                                     "inputColor0":sun,"inputColor1":CIColor(red:0,green:0,blue:0,alpha:0)])!.outputImage!.cropped(to:canvas)
            return disc.composited(over:sky)
        }
        let outgoing = picture(CIColor(red:0.16,green:0.36,blue:0.72),CIColor(red:0.10,green:0.68,blue:0.74),sun:CIColor(red:0.9,green:0.95,blue:1))
        let incoming = picture(CIColor(red:0.96,green:0.55,blue:0.20),CIColor(red:0.78,green:0.22,blue:0.30),sun:CIColor(red:1,green:0.93,blue:0.55))
        let length = MediaTime(seconds:1), cut = MediaTime(seconds:0.5), at = MediaTime(seconds:min(progress,0.999))
        let black = CIImage(color:.black).cropped(to:canvas)
        func side(_ role: LayerTransition.Role) -> LayerTransition {
            LayerTransition(id:UUID(),kind:kind,direction:direction,role:role,paired:kind.needsBothPictures,start:.zero,duration:length,cut:cut)
        }
        let frame: CIImage
        if progress >= 1 { frame = incoming }
        else if kind.needsBothPictures { frame = TransitionRenderer.composite(side(.outgoing),below:black,outgoing:outgoing,incoming:incoming,at:at,canvas:canvas) }
        else if at < cut { frame = TransitionRenderer.composite(side(.outgoing),below:black,outgoing:outgoing,incoming:nil,at:at,canvas:canvas) }
        else { frame = TransitionRenderer.composite(side(.incoming),below:black,outgoing:nil,incoming:incoming,at:at,canvas:canvas) }
        guard let cg = context.createCGImage(frame.cropped(to:canvas),from:canvas,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)) else {
            return NSImage(size:NSSize(width:canvas.width/2,height:canvas.height/2))
        }
        return NSImage(cgImage:cg,size:NSSize(width:canvas.width/2,height:canvas.height/2))
    }
}
