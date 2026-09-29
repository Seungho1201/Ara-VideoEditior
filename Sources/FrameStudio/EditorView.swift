import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import FrameCore

@MainActor enum Theme {
    static let background = Color(red:0.055,green:0.065,blue:0.085)
    static let panel = Color(red:0.085,green:0.095,blue:0.12)
    static let raised = Color(red:0.12,green:0.135,blue:0.17)
    // Ara's fixed light-blue accent (#9ACBFF), shared by SwiftUI and AppKit.
    static let accentNS = NSColor(srgbRed:154.0/255,green:203.0/255,blue:1,alpha:1)
    static let accent = Color(nsColor:accentNS)
    static let muted = Color(red:0.54,green:0.58,blue:0.65)
}

struct EditorView: View {
    @ObservedObject var store: EditorStore
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @State private var customSpeed = false
    @State private var iconHovered = false
    var body: some View {
        Group {
            if store.showLauncher { LauncherView(store:store,registry:store.registry) }
            else { editor }
        }
        .background(Theme.background,ignoresSafeAreaEdges:[]).tint(Theme.accent)
        .alert("Ara",isPresented:Binding(get:{store.message != nil},set:{if !$0 {store.message = nil}})) { Button("OK",role:.cancel) { store.message = nil } } message: { Text(store.message ?? "") }
        .sheet(isPresented:$store.showExportSheet) { ExportSettingsView(store:store) }
        .sheet(isPresented:$store.showNewProjectSheet) { NewProjectView(store:store) }
        .sheet(isPresented:Binding(get:{store.isExporting},set:{_ in})) { exportProgress }
    }
    private var editor: some View {
        VStack(spacing:0) {
            toolbar
            Divider()
            VSplitView {
                HSplitView {
                    // Both side panels must be able to grow, so the viewer can shrink
                    // to its fitted picture plus the horizontal margins below.
                    LibraryPanel(store:store).frame(minWidth:340,idealWidth:496,maxWidth:.infinity)
                        .background(EditorSplitSizing(axis:.columns))
                    viewer.frame(minWidth:390,maxWidth:.infinity,maxHeight:.infinity)
                    SidePanel(store:store).frame(minWidth:250,idealWidth:328.5,maxWidth:.infinity)
                }.frame(minHeight:280,idealHeight:500)
                    .background(EditorSplitSizing(axis:.rows))
                timeline.frame(minHeight:345,idealHeight:345)
            }
        }
        .overlay { if store.showHelp { HelpOverlay(isShown:$store.showHelp) } }
        .animation(.easeOut(duration:0.15),value:store.showHelp)
    }
    private var toolbar: some View {
        HStack(spacing:14) {
            // The app icon is the way home: back to the project lobby, keeping this project loaded.
            Button(action:store.showStartScreen) {
                Image(nsImage:NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).aspectRatio(contentMode:.fit)
                    .frame(width:44,height:44)
                    .scaleEffect(iconHovered ? 1.06 : 1)
                    .brightness(iconHovered ? 0.06 : 0)
                    .animation(.easeOut(duration:0.12),value:iconHovered)
            }
            .buttonStyle(.plain).onHover { iconHovered = $0 }
            .disabled(store.isExporting || store.isCapturingSnapshot)
            .help("Projects  \(shortcuts.label(.startScreen))").accessibilityLabel("Back to projects")
            .helpTip("Projects",.below,shortcut:shortcuts.label(.startScreen))
            VStack(alignment:.leading,spacing:3) {
                Text("Ara").font(.system(size:16,weight:.bold)).tracking(1)
                Text(store.project.name + (store.dirty ? " •" : "")).font(.system(size:12)).foregroundStyle(Theme.muted).lineLimit(1)
                    .help(store.status)
            }
            Spacer(minLength:10)
            toolbarButton("New",icon:"doc.badge.plus",action:store.newProject).helpTip("New project",.below,shortcut:shortcuts.label(.newProject))
            toolbarButton("Open",icon:"folder",action:store.chooseOpen).helpTip("Open project",.below,shortcut:shortcuts.label(.openProject))
            toolbarButton("Save",icon:"square.and.arrow.down") { store.save() }.helpTip("Save project",.below,shortcut:shortcuts.label(.save))
            Rectangle().fill(.white.opacity(0.1)).frame(width:1,height:24)
            toolbarButton("Import",icon:"plus",action:store.chooseImport).disabled(store.isExporting).helpTip("Import media",.below,shortcut:shortcuts.label(.importMedia))
            Button { store.showExportSheet = true } label: { Label("Export",systemImage:"arrow.up.right").font(.system(size:12,weight:.semibold)).padding(.horizontal,13).padding(.vertical,8) }
                .buttonStyle(.plain).background(Theme.accent,in:RoundedRectangle(cornerRadius:6)).foregroundStyle(Theme.background).disabled(store.isExporting || store.isCapturingSnapshot)
                .helpTip("Export movie",.below,shortcut:shortcuts.label(.exportMovie))
        }.padding(.horizontal,18).frame(height:64).background(Theme.panel)
    }
    /// Presets only. The inspector keeps the continuous slider for in-between values.
    /// The gauge and the speed are two menus opening the same list: an AppKit menu button jumps to
    /// its new width, so the speed is its own view that slides in, and the icons after it move
    /// over smoothly instead of jumping.
    private var speedMenu: some View {
        HStack(spacing:4) {
            speedPresets { Image(systemName:"speedometer") }
            // The selected clip's speed; with nothing to retime the gauge stands alone.
            if store.canRetimeSelection {
                speedPresets { Text(String(format:"%.2fx",store.selectedSpeed)).font(.system(size:11,weight:.medium,design:.monospaced)) }
                    .transition(.asymmetric(insertion:.opacity.combined(with:.offset(x:-8)),removal:.opacity.combined(with:.offset(x:-8))))
            }
        }
        .help("Playback speed of the selected clip")
        .helpTip("Clip speed")
        .popover(isPresented:$customSpeed,arrowEdge:.bottom) {
            VStack(alignment:.leading,spacing:8) {
                Text("Custom speed").font(.system(size:12,weight:.semibold))
                SpeedField(store:store,width:120,focusOnAppear:true) { customSpeed = false }
                Text("0.1x – 10x · Return to apply").font(.system(size:10)).foregroundStyle(Theme.muted)
            }.padding(14)
        }
        .accessibilityElement(children:.contain)
        .accessibilityLabel("Clip playback speed")
    }
    private func speedPresets<Label:View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            ForEach(EditorStore.speedPresets,id:\.self) { preset in
                Button { store.setSpeed(preset) } label: { preset == 1 ? Text("1x · Normal") : Text(verbatim:String(format:"%gx",preset)) }
            }
            Divider()
            Button("Custom…") { customSpeed = true }
        } label: { label() }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        // A borderless menu draws in the accent colour; match the white toolbar icons instead.
        .tint(.primary)
        .disabled(!store.canRetimeSelection || store.isExporting)
    }
    private func toolbarButton(_ name: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action:action) { Label(LocalizedStringKey(name),systemImage:icon).font(.system(size:12,weight:.medium)) }.buttonStyle(.plain).padding(.horizontal,5).help(LocalizedStringKey(name)).accessibilityLabel(Text(LocalizedStringKey(name)))
    }
    private var viewer: some View {
        VStack(spacing:0) {
            HStack { panelTitle("PROGRAM"); Spacer(); Text(store.project.aspectRatio.dimensions()).font(.system(size:10,design:.monospaced)).foregroundStyle(Theme.muted) }.padding(14)
            ZStack {
                Color.black
                // Only a missing source the timeline uses stops playback; an unused one is just
                // marked in the library.
                let blocked = !store.missingInUse.isEmpty
                if store.project.clips.isEmpty || blocked {
                    VStack(spacing:14) {
                        Image(systemName:blocked ? "link.badge.plus" : "play.rectangle").font(.system(size:38,weight:.ultraLight))
                        Text(blocked ? "Reconnect your source media" : "A blank frame. A new story.").font(.system(size:16,weight:.medium))
                        Text(blocked ? "Use Relink in the media library to restore playback." : "Import a file, then drag it onto the timeline.").font(.system(size:12)).foregroundStyle(Theme.muted)
                    }.foregroundStyle(.white.opacity(0.8))
                } else { PreviewSurface(store:store).helpTip("Double-click a clip to move, resize and rotate it",.inside) }
                if store.isBuilding { VStack { Spacer(); HStack(spacing:8) { ProgressView().controlSize(.mini); Text("Updating preview").font(.system(size:11)) }.padding(9).background(.black.opacity(0.7),in:Capsule()).padding(12) } }
            }.aspectRatio(store.project.aspectRatio.value,contentMode:.fit).padding(.horizontal,50).frame(maxWidth:.infinity,maxHeight:.infinity)
            HStack(spacing:8) {
                PlayheadTimecode(clock:store.clock,rate:store.project.frameRate)
                Spacer(minLength:0)
                HStack(spacing:4) {
                    Button(action:store.goToSelectedClipStart) { Image(systemName:"backward.end.fill").frame(width:26,height:28) }
                        .help("Selected clip: first frame \(shortcuts.label(.clipStart))").accessibilityLabel("Go to selected clip start").disabled(store.selectedClip == nil).helpTip("Selected clip: first frame",shortcut:shortcuts.label(.clipStart))
                    Button { store.step(-1) } label: { Image(systemName:"backward.frame").frame(width:26,height:28) }
                        .help("Previous frame \(shortcuts.label(.previousFrame))").accessibilityLabel("Previous frame").helpTip("Previous frame",shortcut:shortcuts.label(.previousFrame))
                    Button { store.togglePlayback() } label: { Image(systemName:store.isPlaying ? "pause.fill" : "play.fill").frame(width:28,height:28) }
                        .help("Play / Pause \(shortcuts.label(.playPause))").accessibilityLabel(store.isPlaying ? Text("Pause") : Text("Play")).disabled(store.isBuilding).helpTip("Play / Pause",shortcut:shortcuts.label(.playPause))
                    Button { store.step(1) } label: { Image(systemName:"forward.frame").frame(width:26,height:28) }
                        .help("Next frame \(shortcuts.label(.nextFrame))").accessibilityLabel("Next frame").helpTip("Next frame",shortcut:shortcuts.label(.nextFrame))
                    Button(action:store.goToSelectedClipEnd) { Image(systemName:"forward.end.fill").frame(width:26,height:28) }
                        .help("Selected clip: last frame \(shortcuts.label(.clipEnd))").accessibilityLabel("Go to selected clip end").disabled(store.selectedClip == nil).helpTip("Selected clip: last frame",shortcut:shortcuts.label(.clipEnd))
                }
                Spacer(minLength:0)
                Text(store.project.frameRate.timecode(store.project.duration)).font(.system(size:11,design:.monospaced)).foregroundStyle(Theme.muted).fixedSize()
            }.buttonStyle(.plain).padding(.horizontal,16).frame(height:50)
        }.background(Theme.background)
    }
    private var timeline: some View {
        VStack(spacing:0) {
            HStack(spacing:16) {
                panelTitle("TIMELINE")
                // What changes the project waits while an export reads it.
                Button { store.undo() } label:{Image(systemName:"arrow.uturn.backward")}.disabled(!store.canUndo || store.isExporting).help("Undo \(shortcuts.label(.undo))").helpTip("Undo",shortcut:shortcuts.label(.undo))
                Button { store.redo() } label:{Image(systemName:"arrow.uturn.forward")}.disabled(!store.canRedo || store.isExporting).help("Redo \(shortcuts.label(.redo))").helpTip("Redo",shortcut:shortcuts.label(.redo))
                Divider().frame(height:18)
                Button { store.split() } label:{Image(systemName:"scissors")}.disabled(store.selectedClip == nil || store.isExporting).help("Split at playhead \(shortcuts.label(.split))").accessibilityLabel("Split at playhead").helpTip("Split at playhead",shortcut:shortcuts.label(.split))
                Button(action:store.chooseSnapshot) {
                    if store.isCapturingSnapshot { ProgressView().controlSize(.mini).frame(width:16,height:16) }
                    else { Image(systemName:"camera").frame(width:16,height:16) }
                }.disabled(!store.canCaptureSnapshot).help("Save current frame as PNG \(shortcuts.label(.snapshot))").accessibilityLabel("Capture timeline snapshot").helpTip("Save frame as PNG",shortcut:shortcuts.label(.snapshot))
                speedMenu
                Button { store.addText() } label:{
                    CaptionsGlyph(lineWidth:1).stroke(style:StrokeStyle(lineWidth:1,lineCap:.round,lineJoin:.round)).frame(width:17,height:12.6)
                }.disabled(store.isExporting).help("Add a title above the clips at the playhead \(shortcuts.label(.addText))").accessibilityLabel("Add text clip").helpTip("Add title",shortcut:shortcuts.label(.addText))
                // Rectangle select, once: the next drag across the tracks selects what it covers.
                Button { store.dragSelectArmed.toggle() } label:{
                    DragSelectGlyph().frame(width:15,height:15)
                        .padding(3).background(store.dragSelectArmed ? Theme.accent.opacity(0.22) : .clear,in:RoundedRectangle(cornerRadius:4))
                        .foregroundStyle(store.dragSelectArmed ? Theme.accent : Color.primary)
                }.padding(-3).disabled(store.project.clips.isEmpty)
                 .help(store.dragSelectArmed ? LocalizedStringKey("Drag across the timeline to select clips · Esc to cancel") : LocalizedStringKey("Select clips with a rectangle: the next drag across the timeline, no Shift needed"))
                 .accessibilityLabel("Rectangle select").accessibilityAddTraits(store.dragSelectArmed ? .isSelected : []).helpTip("Rectangle select")
                Button { store.deleteSelection() } label:{Image(systemName:"trash")}.disabled(!store.canDeleteSelection || store.isExporting)
                    .help(store.selectedTransition != nil ? LocalizedStringKey("Remove transition") : LocalizedStringKey("Delete selected clips")).helpTip("Delete",shortcut:shortcuts.label(.delete))
                Spacer(minLength:4)
                Toggle(isOn:$store.snapping) { Image(systemName:"magnifyingglass") }.toggleStyle(.button).help("Snap to clip edges and playhead \(shortcuts.label(.snapping))").accessibilityLabel("Snapping").helpTip("Snapping",shortcut:shortcuts.label(.snapping))
                Text("−").foregroundStyle(Theme.muted)
                Slider(value:$store.zoom,in:8...220).frame(width:115).help("Timeline zoom").helpTip("Timeline zoom · pinch",shortcut:"")
                Text("+").foregroundStyle(Theme.muted)
                Button { store.showHelp.toggle() } label: {
                    Image(systemName:"questionmark.circle").font(.system(size:14))
                        .foregroundStyle(store.showHelp ? Theme.accent : Color.primary)
                }
                .help("Show what each control does").accessibilityLabel("Tips")
                .helpTip("Show these tips")
            }.font(.system(size:11,weight:.medium)).buttonStyle(.plain).padding(.horizontal,16).frame(height:42).background(Theme.panel)
            // The clip speed slides in and out; the icons after it follow instead of jumping.
            .animation(.snappy(duration:0.28),value:store.canRetimeSelection)
            Divider()
            TimelineView(store:store)
                .helpTip("Drag clips to move, their edges to trim · Shift-drag selects several · drag the ruler to skim",.inside)
        }
    }
    private var exportProgress: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Rendering your movie").font(.title2.weight(.semibold))
            Text("\(Int(store.exportProgress*100))% · H.264 / AAC").font(.system(size:13,design:.monospaced))
            ProgressView(value:store.exportProgress)
            Text("Your final file appears only after a successful export.").font(.system(size:12)).foregroundStyle(Theme.muted)
            HStack { Spacer(); Button("Cancel Export",role:.cancel) { store.cancelExport() } }
        }.padding(28).frame(width:440).interactiveDismissDisabled().background(Theme.panel)
    }
}

@MainActor func panelTitle(_ text: String) -> some View { Text(LocalizedStringKey(text)).font(.system(size:10,weight:.bold)).tracking(1.7).foregroundStyle(Theme.muted) }

extension MediaKind {
    /// The kind as the panels name it, in Ara's language (the raw value is the saved one).
    var displayName: String {
        switch self {
        case .video: String(localized:"Video")
        case .audio: String(localized:"Audio")
        case .image: String(localized:"Image")
        case .text: String(localized:"Text")
        }
    }
}

struct LibraryPanel: View {
    @ObservedObject var store: EditorStore
    @State private var targeted = false
    private let columns = [GridItem(.flexible(minimum:0),spacing:10),GridItem(.flexible(minimum:0),spacing:10)]
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                panelTitle("MEDIA").helpTip("Drag media onto the timeline, or double-click to add it at the end",.below)
                Spacer()
                if let proxy = store.proxyProgress {
                    HStack(spacing:6) {
                        ProgressView(value:proxy.fraction).progressViewStyle(.linear).frame(width:46).controlSize(.mini)
                        Text("Preview \(Int(proxy.fraction*100))%").monospacedDigit()
                    }
                    .font(.system(size:10)).foregroundStyle(Theme.muted)
                    .help(proxy.remaining > 1 ? String(localized:"Preparing preview · \(proxy.name) · \(proxy.remaining-1) more") : String(localized:"Preparing preview · \(proxy.name)"))
                    .accessibilityElement(children:.ignore)
                    .accessibilityLabel("Preparing preview for \(proxy.name)")
                    .accessibilityValue("\(Int(proxy.fraction*100)) percent")
                }
                Text("\(store.project.media.count)").foregroundStyle(Theme.muted)
                Button { store.chooseImport() } label:{Image(systemName:"plus")}.buttonStyle(.plain)
            }.font(.system(size:11)).padding(16)
            Divider()
            if store.project.media.isEmpty {
                VStack(spacing:14) {
                    Image(systemName:"square.and.arrow.down").font(.system(size:28,weight:.light)).foregroundStyle(Theme.accent)
                    Text("Bring your footage").font(.system(size:14,weight:.medium))
                    Text("Drop video, audio or images here.\nYour originals stay untouched.").font(.system(size:11)).multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                    Button("Import Media…") { store.chooseImport() }.controlSize(.small)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns:columns,alignment:.leading,spacing:10) {
                        ForEach(store.project.media) { media in
                            mediaCard(media)
                                .onTapGesture(count:2) { store.addMedia(media.id) }
                                .onTapGesture { store.selectedMediaID = media.id }
                                .contextMenu {
                                    ForEach(media.kind == .audio ? store.project.audioLanes : store.project.videoLanes) { lane in
                                        Button("Append to \(lane.rawValue)") { store.addMedia(media.id,lane:lane) }
                                    }
                                    Button("Relink source…") { store.relink(media) }
                                }
                        }
                    }.padding(10)
                }
            }
            if store.isImporting { HStack { ProgressView().controlSize(.small); Text("Reading media…").font(.system(size:11)) }.padding(12) }
            if store.isAddingFonts { HStack { ProgressView().controlSize(.small); Text("Adding fonts…").font(.system(size:11)) }.padding(12) }
        }.background(targeted ? Theme.accent.opacity(0.12) : Theme.panel)
            .onDrop(of:[UTType.fileURL],isTargeted:$targeted) { providers in
                Task { @MainActor in
                    var files: [URL] = []
                    for provider in providers {
                        let url: URL? = await withCheckedContinuation { continuation in
                            _ = provider.loadObject(ofClass:URL.self) { url,_ in continuation.resume(returning:url) }
                        }
                        if let url { files.append(url) }
                    }
                    store.importFiles(files)
                }
                return true
            }
    }
    private func mediaCard(_ media: MediaReference) -> some View {
        VStack(alignment:.leading,spacing:7) {
            ZStack {
                RoundedRectangle(cornerRadius:4).fill(.black.opacity(0.35))
                if let image = store.thumbnails[media.id] { Image(nsImage:image).resizable().aspectRatio(contentMode:.fit) }
                else if media.kind == .audio { Image(systemName:"waveform").font(.system(size:30,weight:.light)).foregroundStyle(Theme.accent) }
                else { Image(systemName:"film").foregroundStyle(Theme.muted) }
                VStack { Spacer(); HStack {
                    Text(media.kind.displayName.uppercased()).font(.system(size:8,weight:.bold)).tracking(1); Spacer()
                    Group { if media.kind == .image { Text("STILL") } else { Text(store.project.frameRate.timecode(media.duration)) } }.font(.system(size:9,design:.monospaced))
                }.padding(5).background(.black.opacity(0.7)) }
            }.aspectRatio(16.0/9,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:4))
                .overlay { LibraryDragHandle(id:media.id,thumbnail:store.thumbnails[media.id],select:{store.selectedMediaID = media.id},append:{store.addMedia(media.id)}) }
            Text(media.name).font(.system(size:11,weight:.medium)).lineLimit(1).truncationMode(.middle).help(media.name)
            HStack {
                // Sizes plain, as PROGRAM and the sheets show them: 2560 × 1440, never 2,560 × 1,440.
                if media.kind == .audio { Text("Audio · Source waveform") } else { Text(verbatim:"\(media.width) × \(media.height)") }
                Spacer()
                if media.frameRate > 0 { Text(String(format:"%.2f fps",media.frameRate)) }
            }.font(.system(size:9)).foregroundStyle(Theme.muted).lineLimit(1)
            HStack {
                if store.missing.contains(media.id) { Label("Missing",systemImage:"exclamationmark.triangle").foregroundStyle(.orange); Spacer(); Button("Relink…") { store.relink(media) } }
                else { Text("Double-click to append").foregroundStyle(Theme.muted).lineLimit(1); Spacer(); Button { store.addMedia(media.id) } label:{Image(systemName:"plus.circle")}.buttonStyle(.plain).help("Append to timeline") }
            }.font(.system(size:10))
        }.frame(maxWidth:.infinity,alignment:.leading).padding(8).background(store.selectedMediaID == media.id ? Theme.accent.opacity(0.1) : Theme.raised.opacity(0.5),in:RoundedRectangle(cornerRadius:7))
            .overlay(RoundedRectangle(cornerRadius:7).stroke(store.selectedMediaID == media.id ? Theme.accent.opacity(0.8) : .clear,lineWidth:1))
    }
}

/// Native drag initiation keeps thumbnail drags reliable across SwiftUI tap/context-menu recognizers.
private struct LibraryDragHandle: NSViewRepresentable {
    let id: UUID
    let thumbnail: NSImage?
    let select: () -> Void
    let append: () -> Void
    func makeNSView(context:Context) -> LibraryDragView { LibraryDragView() }
    func updateNSView(_ view:LibraryDragView,context:Context) {
        view.mediaID = id; view.thumbnail = thumbnail; view.select = select; view.append = append
    }
}

@MainActor private final class LibraryDragView: NSView, NSDraggingSource {
    var mediaID = UUID()
    var thumbnail: NSImage?
    var select: (() -> Void)?
    var append: (() -> Void)?
    private var origin = NSPoint.zero
    private var dragging = false
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func mouseDown(with event:NSEvent) {
        origin = convert(event.locationInWindow,from:nil); dragging = false; select?()
        if event.clickCount == 2 { append?() }
    }
    override func mouseDragged(with event:NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        guard !dragging, hypot(point.x-origin.x,point.y-origin.y) > 3 else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter:mediaID.uuidString as NSString)
        let image = thumbnail ?? NSImage(systemSymbolName:"waveform",accessibilityDescription:"Audio")!
        item.setDraggingFrame(NSRect(x:point.x-70,y:point.y-40,width:140,height:80),contents:image)
        beginDraggingSession(with:[item],event:event,source:self)
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext) -> NSDragOperation { .copy }
}

/// The playhead readout: the one SwiftUI view that follows every playhead move.
private struct PlayheadTimecode: View {
    @ObservedObject var clock: PlayheadClock
    let rate: FrameRate
    var body: some View {
        Text(rate.timecode(clock.time)).font(.system(size:11,weight:.medium,design:.monospaced)).foregroundStyle(Theme.accent).fixedSize()
    }
}

/// Closed-captions mark: a rounded frame, open on the right edge, around two C's. Stroked, so it
/// takes the button's colour and dims with it like the SF Symbols beside it.
/// A square with an arrow out to a dashed square: select by dragging a rectangle.
private struct DragSelectGlyph: View {
    var body: some View {
        Canvas { context, size in
            let line: CGFloat = 1.2, side = size.width*0.58
            let solid = CGRect(x:line/2,y:size.height-side-line/2,width:side,height:side)
            let dashed = CGRect(x:size.width-side-line/2,y:line/2,width:side,height:side)
            // The dashed square shows only where the solid one does not cover it.
            context.drawLayer { layer in
                var outside = Path(CGRect(origin:.zero,size:size)); outside.addRect(solid)
                layer.clip(to:outside,style:FillStyle(eoFill:true))
                layer.stroke(Path(dashed),with:.foreground,style:StrokeStyle(lineWidth:line,dash:[1.6,1.3]))
            }
            context.stroke(Path(solid),with:.foreground,lineWidth:line)
            // The arrow, from inside the solid square up to the dashed one.
            let from = CGPoint(x:solid.minX+side*0.42,y:solid.maxY-side*0.42), to = CGPoint(x:dashed.maxX-side*0.3,y:dashed.minY+side*0.3)
            var arrow = Path(); arrow.move(to:from); arrow.addLine(to:to)
            let head = side*0.34
            arrow.move(to:CGPoint(x:to.x-head,y:to.y)); arrow.addLine(to:to); arrow.addLine(to:CGPoint(x:to.x,y:to.y+head))
            context.stroke(arrow,with:.foreground,style:StrokeStyle(lineWidth:line,lineCap:.round,lineJoin:.round))
        }
    }
}

private struct CaptionsGlyph: Shape {
    var lineWidth: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx:lineWidth/2,dy:lineWidth/2)
        let w = r.width, h = r.height, corner = h*0.26
        var p = Path()
        // Frame, clockwise from just below the opening on the right edge.
        p.move(to:CGPoint(x:r.maxX,y:r.minY+h*0.78))
        p.addLine(to:CGPoint(x:r.maxX,y:r.maxY-corner))
        p.addRelativeArc(center:CGPoint(x:r.maxX-corner,y:r.maxY-corner),radius:corner,startAngle:.degrees(0),delta:.degrees(90))
        p.addLine(to:CGPoint(x:r.minX+corner,y:r.maxY))
        p.addRelativeArc(center:CGPoint(x:r.minX+corner,y:r.maxY-corner),radius:corner,startAngle:.degrees(90),delta:.degrees(90))
        p.addLine(to:CGPoint(x:r.minX,y:r.minY+corner))
        p.addRelativeArc(center:CGPoint(x:r.minX+corner,y:r.minY+corner),radius:corner,startAngle:.degrees(180),delta:.degrees(90))
        p.addLine(to:CGPoint(x:r.maxX-corner,y:r.minY))
        p.addRelativeArc(center:CGPoint(x:r.maxX-corner,y:r.minY+corner),radius:corner,startAngle:.degrees(270),delta:.degrees(90))
        p.addLine(to:CGPoint(x:r.maxX,y:r.minY+h*0.58))
        // Two C's: arcs over and under a short straight back, open to the right. The arcs stop
        // short of horizontal so the opening stays visible at toolbar size.
        let cw = w*0.23, ch = h*0.5, cr = cw/2, top = r.midY-ch/2, sweep = 145.0
        for left in [r.minX+w*0.2, r.minX+w*0.56] {
            let upper = CGPoint(x:left+cr,y:top+cr), lower = CGPoint(x:left+cr,y:top+ch-cr)
            p.move(to:CGPoint(x:upper.x+cr*cos(-(180-sweep)*Double.pi/180),y:upper.y+cr*sin(-(180-sweep)*Double.pi/180)))
            p.addRelativeArc(center:upper,radius:cr,startAngle:.degrees(-(180-sweep)),delta:.degrees(-sweep))
            p.addLine(to:CGPoint(x:left,y:lower.y))
            p.addRelativeArc(center:lower,radius:cr,startAngle:.degrees(180),delta:.degrees(-sweep))
        }
        return p
    }
}
