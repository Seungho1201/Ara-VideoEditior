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
    @State private var iconHovered = false
    var body: some View {
        Group {
            if store.showLauncher { LauncherView(store:store,registry:store.registry) }
            else { editor }
        }
        .background(Theme.background).tint(Theme.accent)
        .alert("Ara",isPresented:Binding(get:{store.message != nil},set:{if !$0 {store.message = nil}})) { Button("OK",role:.cancel) { store.message = nil } } message: { Text(store.message ?? "") }
        .sheet(isPresented:$store.showExportSheet) { exportSettings }
        .sheet(isPresented:Binding(get:{store.isExporting},set:{_ in})) { exportProgress }
    }
    private var editor: some View {
        VStack(spacing:0) {
            toolbar
            Divider()
            VSplitView {
                HSplitView {
                    LibraryPanel(store:store).frame(minWidth:215,idealWidth:265,maxWidth:330)
                    viewer.frame(minWidth:390,maxWidth:.infinity,maxHeight:.infinity)
                    InspectorPanel(store:store).frame(minWidth:250,idealWidth:280,maxWidth:320)
                }.frame(minHeight:280,idealHeight:500)
                timeline.frame(minHeight:345,idealHeight:345)
            }
            Divider()
            HStack(spacing:8) {
                Circle().fill(store.missing.isEmpty ? Theme.accent : .orange).frame(width:5,height:5)
                Text(store.status).lineLimit(1)
                Spacer()
                if let proxy = store.proxyProgress {
                    // Sources above FHD get a 1080p stand-in for the preview; export still uses the originals.
                    ProgressView(value:proxy.fraction).progressViewStyle(.linear).frame(width:70).controlSize(.mini)
                    Text("FHD preview media · \(proxy.name) \(Int(proxy.fraction*100))%" + (proxy.remaining > 1 ? " · \(proxy.remaining-1) more" : ""))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth:300,alignment:.trailing)
                        .help("Making 1080p preview copies of sources larger than FHD so scrubbing stays smooth. Export always uses the original files.")
                    Text("·")
                }
                Text("PREVIEW FHD  ·  LOCAL MEDIA  ·  SDR REC.709").tracking(1.2)
            }.font(.system(size:10,weight:.medium)).foregroundStyle(Theme.muted).padding(.horizontal,16).frame(height:27)
        }
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
            .help("Projects  ⇧⌘1").accessibilityLabel("Back to projects")
            VStack(alignment:.leading,spacing:3) {
                Text("Ara").font(.system(size:16,weight:.bold)).tracking(1)
                Text(store.project.name + (store.dirty ? " •" : "")).font(.system(size:12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength:10)
            toolbarButton("New",icon:"doc.badge.plus",action:store.newProject)
            toolbarButton("Open",icon:"folder",action:store.chooseOpen)
            toolbarButton("Save",icon:"square.and.arrow.down") { store.save() }
            Rectangle().fill(.white.opacity(0.1)).frame(width:1,height:24)
            toolbarButton("Import",icon:"plus",action:store.chooseImport)
            Button { store.showExportSheet = true } label: { Label("Export",systemImage:"arrow.up.right").font(.system(size:12,weight:.semibold)).padding(.horizontal,13).padding(.vertical,8) }
                .buttonStyle(.plain).background(Theme.accent,in:RoundedRectangle(cornerRadius:6)).foregroundStyle(Theme.background).disabled(store.project.clips.isEmpty || store.isExporting)
        }.padding(.horizontal,18).frame(height:64).background(Theme.panel)
    }
    /// Presets only. The inspector keeps the continuous slider for in-between values.
    private var speedMenu: some View {
        Menu {
            ForEach([0.25,0.5,0.75,1.0,1.5,2.0,3.0,4.0],id:\.self) { preset in
                Button(preset == 1 ? "1x · Normal" : String(format:"%gx",preset)) { store.setSpeed(preset) }
            }
        } label: {
            HStack(spacing:4) {
                Image(systemName:"speedometer")
                // The selected clip's speed; with nothing to retime the gauge stands alone.
                if store.canRetimeSelection {
                    Text(String(format:"%.2fx",store.selectedSpeed)).font(.system(size:11,weight:.medium,design:.monospaced))
                }
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        // A borderless menu draws in the accent colour; match the white toolbar icons instead.
        .tint(.primary)
        .disabled(!store.canRetimeSelection)
        .help("Playback speed of the selected clip")
        .accessibilityLabel("Clip playback speed")
    }
    private func toolbarButton(_ name: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action:action) { Label(name,systemImage:icon).font(.system(size:12,weight:.medium)) }.buttonStyle(.plain).padding(.horizontal,5).help(name).accessibilityLabel(name)
    }
    private var viewer: some View {
        VStack(spacing:0) {
            HStack { panelTitle("PROGRAM"); Spacer(); Text("1920 × 1080").font(.system(size:10,design:.monospaced)).foregroundStyle(Theme.muted) }.padding(14)
            ZStack {
                Color.black
                if store.project.clips.isEmpty || !store.missing.isEmpty {
                    VStack(spacing:14) {
                        Image(systemName:store.missing.isEmpty ? "play.rectangle" : "link.badge.plus").font(.system(size:38,weight:.ultraLight))
                        Text(store.missing.isEmpty ? "A blank frame. A new story." : "Reconnect your source media").font(.system(size:16,weight:.medium))
                        Text(store.missing.isEmpty ? "Import a file, then drag it onto the timeline." : "Use Relink in the media library to restore playback.").font(.system(size:12)).foregroundStyle(Theme.muted)
                    }.foregroundStyle(.white.opacity(0.8))
                } else { PreviewSurface(store:store) }
                if store.isBuilding { VStack { Spacer(); HStack(spacing:8) { ProgressView().controlSize(.mini); Text("Updating preview").font(.system(size:11)) }.padding(9).background(.black.opacity(0.7),in:Capsule()).padding(12) } }
            }.aspectRatio(16/9,contentMode:.fit).padding(.horizontal,18).frame(maxWidth:.infinity,maxHeight:.infinity)
            HStack(spacing:8) {
                Text(store.timecode).font(.system(size:11,weight:.medium,design:.monospaced)).foregroundStyle(Theme.accent).fixedSize()
                Spacer(minLength:0)
                HStack(spacing:4) {
                    Button(action:store.goToSelectedClipStart) { Image(systemName:"backward.end.fill").frame(width:26,height:28) }
                        .help("Selected clip: first frame ⌥←").accessibilityLabel("Go to selected clip start").disabled(store.selectedClip == nil)
                    Button { store.step(-1) } label: { Image(systemName:"backward.frame").frame(width:26,height:28) }
                        .help("Previous frame ←").accessibilityLabel("Previous frame")
                    Button { store.togglePlayback() } label: { Image(systemName:store.isPlaying ? "pause.fill" : "play.fill").frame(width:28,height:28) }
                        .help("Play / Pause Space").accessibilityLabel(store.isPlaying ? "Pause" : "Play").disabled(store.isBuilding)
                    Button { store.step(1) } label: { Image(systemName:"forward.frame").frame(width:26,height:28) }
                        .help("Next frame →").accessibilityLabel("Next frame")
                    Button(action:store.goToSelectedClipEnd) { Image(systemName:"forward.end.fill").frame(width:26,height:28) }
                        .help("Selected clip: last frame ⌥→").accessibilityLabel("Go to selected clip end").disabled(store.selectedClip == nil)
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
                Button { store.undo() } label:{Image(systemName:"arrow.uturn.backward")}.disabled(!store.canUndo).help("Undo ⌘Z")
                Button { store.redo() } label:{Image(systemName:"arrow.uturn.forward")}.disabled(!store.canRedo).help("Redo ⇧⌘Z")
                Divider().frame(height:18)
                Button { store.split() } label:{Image(systemName:"scissors")}.disabled(store.selectedClip == nil).help("Split at playhead ⌘B").accessibilityLabel("Split at playhead")
                Button(action:store.chooseSnapshot) {
                    if store.isCapturingSnapshot { ProgressView().controlSize(.mini).frame(width:16,height:16) }
                    else { Image(systemName:"camera").frame(width:16,height:16) }
                }.disabled(!store.canCaptureSnapshot).help("Save current frame as PNG ⇧⌘E").accessibilityLabel("Capture timeline snapshot")
                speedMenu
                Button { store.addText() } label:{
                    CaptionsGlyph(lineWidth:1).stroke(style:StrokeStyle(lineWidth:1,lineCap:.round,lineJoin:.round)).frame(width:17,height:12.6)
                }.help("Add text to V2 at playhead ⇧⌘T").accessibilityLabel("Add text clip")
                Button { store.deleteSelection() } label:{Image(systemName:"trash")}.disabled(store.selectedClip == nil).help("Delete linked clips")
                Spacer(minLength:4)
                Toggle(isOn:$store.snapping) { Image(systemName:"point.topleft.down.to.point.bottomright.curvepath") }.toggleStyle(.button).help("Snap to clip edges and playhead N")
                Text("−").foregroundStyle(Theme.muted)
                Slider(value:$store.zoom,in:8...220).frame(width:115).help("Timeline zoom")
                Text("+").foregroundStyle(Theme.muted)
                Text("\(store.project.frameRate.label) fps NDF").font(.system(size:10,design:.monospaced)).foregroundStyle(Theme.muted)
            }.font(.system(size:11,weight:.medium)).buttonStyle(.plain).padding(.horizontal,16).frame(height:42).background(Theme.panel)
            Divider()
            TimelineView(store:store)
            HStack { Text("V2 ABOVE V1"); Spacer(); Text("Drag to move · Edge handles to trim · ⌘B split · Double-click a gap, ⌘⌫ to close it · ⇧ drag disables snap") }.font(.system(size:9,weight:.medium)).foregroundStyle(Theme.muted).padding(.horizontal,16).frame(height:22)
        }
    }
    private var exportSettings: some View {
        VStack(alignment:.leading,spacing:20) {
            Text("Export movie").font(.title2.weight(.semibold))
            Text("H.264 video · AAC stereo audio · SDR Rec.709").foregroundStyle(Theme.muted)
            Picker("Resolution",selection:$store.exportHeight) { Text("1080p · 1920 × 1080").tag(1080); Text("4K · 3840 × 2160").tag(2160) }
            Text("\(store.project.frameRate.label) fps · \(store.project.frameRate.timecode(store.project.duration)) · Current timeline snapshot").font(.system(size:12,design:.monospaced))
            HStack { Button("Cancel") { store.showExportSheet = false }; Spacer(); Button("Choose destination…") { store.showExportSheet = false; DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { store.chooseExport() } }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width:470).background(Theme.panel)
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

@MainActor func panelTitle(_ text: String) -> some View { Text(text).font(.system(size:10,weight:.bold)).tracking(1.7).foregroundStyle(Theme.muted) }

struct LibraryPanel: View {
    @ObservedObject var store: EditorStore
    @State private var targeted = false
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack { panelTitle("MEDIA"); Spacer(); Text("\(store.project.media.count)").foregroundStyle(Theme.muted); Button { store.chooseImport() } label:{Image(systemName:"plus")}.buttonStyle(.plain) }.font(.system(size:11)).padding(16)
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
                    LazyVStack(spacing:8) {
                        ForEach(store.project.media) { media in
                            mediaRow(media)
                                .onTapGesture(count:2) { store.addMedia(media.id) }
                                .onTapGesture { store.selectedMediaID = media.id }
                                .contextMenu {
                                    if media.kind == .audio {
                                        Button("Append to A1") { store.addMedia(media.id,lane:.a1) }
                                        Button("Append to A2") { store.addMedia(media.id,lane:.a2) }
                                    } else {
                                        Button("Append to V1") { store.addMedia(media.id,lane:.v1) }
                                        Button("Append to V2") { store.addMedia(media.id,lane:.v2) }
                                    }
                                    Button("Relink source…") { store.relink(media) }
                                }
                        }
                    }.padding(10)
                }
            }
            if store.isImporting { HStack { ProgressView().controlSize(.small); Text("Reading media…").font(.system(size:11)) }.padding(12) }
            Divider()
            VStack(alignment:.leading,spacing:8) {
                HStack { Text("Project rate"); Spacer(); Picker("Project rate",selection:Binding(get:{store.project.frameRate},set:store.setRate)) { ForEach(FrameRate.supported) { Text($0.label).tag($0) } }.labelsHidden().frame(width:95).disabled(!store.project.clips.isEmpty) }.font(.system(size:11))
                Text("Set before adding clips · Non-drop timecode").font(.system(size:9)).foregroundStyle(Theme.muted)
            }.padding(12)
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
    private func mediaRow(_ media: MediaReference) -> some View {
        VStack(alignment:.leading,spacing:7) {
            ZStack {
                RoundedRectangle(cornerRadius:4).fill(.black.opacity(0.35))
                if let image = store.thumbnails[media.id] { Image(nsImage:image).resizable().aspectRatio(contentMode:.fit) }
                else if media.kind == .audio { Image(systemName:"waveform").font(.system(size:30,weight:.light)).foregroundStyle(Theme.accent) }
                else { Image(systemName:"film").foregroundStyle(Theme.muted) }
                VStack { Spacer(); HStack { Text(media.kind.rawValue.uppercased()).font(.system(size:8,weight:.bold)).tracking(1); Spacer(); Text(media.kind == .image ? "STILL" : store.project.frameRate.timecode(media.duration)).font(.system(size:9,design:.monospaced)) }.padding(5).background(.black.opacity(0.7)) }
            }.frame(height:103).clipShape(RoundedRectangle(cornerRadius:4))
                .overlay { LibraryDragHandle(id:media.id,thumbnail:store.thumbnails[media.id],select:{store.selectedMediaID = media.id},append:{store.addMedia(media.id)}) }
            Text(media.name).font(.system(size:11,weight:.medium)).lineLimit(1)
            HStack {
                Text(media.kind == .audio ? "Audio · Source waveform" : "\(media.width) × \(media.height)" )
                Spacer()
                if media.frameRate > 0 { Text(String(format:"%.2f fps",media.frameRate)) }
            }.font(.system(size:9)).foregroundStyle(Theme.muted)
            HStack {
                if store.missing.contains(media.id) { Label("Missing",systemImage:"exclamationmark.triangle").foregroundStyle(.orange); Spacer(); Button("Relink…") { store.relink(media) } }
                else { Text("Double-click to append").foregroundStyle(Theme.muted); Spacer(); Button { store.addMedia(media.id) } label:{Image(systemName:"plus.circle")}.buttonStyle(.plain).help("Append to timeline") }
            }.font(.system(size:10))
        }.padding(8).background(store.selectedMediaID == media.id ? Theme.accent.opacity(0.1) : Theme.raised.opacity(0.5),in:RoundedRectangle(cornerRadius:7))
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

/// Closed-captions mark: a rounded frame, open on the right edge, around two C's. Stroked, so it
/// takes the button's colour and dims with it like the SF Symbols beside it.
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
