import SwiftUI
import AppKit
import FrameCore
import FrameMedia

struct InspectorPanel: View {
    @ObservedObject var store: EditorStore
    /// The title being typed. The text view binds to this, never to the store: writing the
    /// store's value back into an NSTextView mid-composition cancels Hangul (and any IME) input.
    @State private var textDraft = ""
    @State private var draftClipID: UUID?
    @State private var textCommit: Task<Void,Never>?
    /// The last text this panel pushed to the store, to tell its own commit echoing back from a
    /// real outside change such as ⌘Z while the field still has focus.
    @State private var lastCommitted: String?
    /// The document the draft was taken from. A draft never lands in a different document.
    @State private var draftSession: UUID?
    @FocusState private var textFocused: Bool
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            if let transition = store.selectedTransition {
                transitionInspector(transition)
            } else if let clip = store.selectedClip {
                ScrollView {
                    VStack(alignment:.leading,spacing:18) {
                        VStack(alignment:.leading,spacing:6) {
                            Text(clip.name).font(.system(size:13,weight:.semibold)).lineLimit(2)
                            HStack { Text("\(clip.lane.rawValue) · \(clip.kind.rawValue.capitalized)"); if clip.linkID != nil { Image(systemName:"link"); Text("Linked A/V") } }.font(.system(size:10)).foregroundStyle(Theme.accent)
                        }
                        section("TIMING") {
                            info("Start",store.project.frameRate.timecode(clip.start))
                            info("Source in",store.project.frameRate.timecode(clip.sourceStart))
                            info("Duration",store.project.frameRate.timecode(clip.duration))
                            HStack { Button("Trim start here") { store.trim(clip.id,leading:true,to:store.playhead) }; Button("Trim end here") { store.trim(clip.id,leading:false,to:store.playhead) } }.controlSize(.mini)
                        }
                        if clip.kind == .video || clip.kind == .audio {
                            section("SPEED") {
                                HStack {
                                    Text("Playback").foregroundStyle(Theme.muted); Spacer()
                                    Text(String(format:"%.2fx",clip.speed)).font(.system(size:10,design:.monospaced))
                                }
                                Slider(value:Binding(get:{store.selectedClip?.speed ?? 1},
                                                     set:{ v in store.setSpeedInteractively(min(Clip.speedRange.upperBound,max(Clip.speedRange.lowerBound,(v*20).rounded()/20))) }),
                                       in:Clip.speedRange,
                                       onEditingChanged:{ active in if active { store.beginInteraction() } else { store.endInteraction() } })
                                    .controlSize(.mini).accessibilityLabel("Playback speed")
                                HStack(spacing:5) {
                                    ForEach([0.25,0.5,1.0,2.0,4.0],id:\.self) { preset in
                                        Button(preset == 1 ? "1x" : String(format:"%gx",preset)) { store.setSpeed(preset) }
                                            .controlSize(.mini).disabled(abs(clip.speed-preset) < 0.001)
                                    }
                                }
                                Text(clip.speed == 1 ? "Source length \(store.project.frameRate.timecode(clip.sourceLength))"
                                                     : "Uses \(store.project.frameRate.timecode(clip.sourceLength)) of source · audio pitch preserved")
                                    .font(.system(size:9)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                            }
                        }
                        if clip.kind != .audio {
                            section("TRANSFORM") {
                                control("Position X",\.x,range:-1...1,multiplier:100,suffix:"%")
                                control("Position Y",\.y,range:-1...1,multiplier:100,suffix:"%")
                                control("Scale",\.scale,range:0.05...4,multiplier:100,suffix:"%")
                                control("Rotation",\.rotation,range:-180...180,suffix:"°")
                                control("Opacity",\.opacity,range:0...1,multiplier:100,suffix:"%")
                            }
                            section("COLOUR · SDR") {
                                control("Brightness",\.brightness,range:-1...1,multiplier:100)
                                control("Contrast",\.contrast,range:0...3,multiplier:100,suffix:"%")
                                control("Saturation",\.saturation,range:0...3,multiplier:100,suffix:"%")
                            }
                        }
                        if clip.kind == .audio || clip.linkID != nil {
                            section("AUDIO") {
                                control("Volume",\.volume,range:0...2,multiplier:100,suffix:"%")
                                Toggle("Mute",isOn:Binding(get:{store.selectedClip?.style.muted ?? false},set:{v in store.updateStyle { $0.muted = v } })).toggleStyle(.switch).controlSize(.mini)
                            }
                        }
                        if clip.kind == .text {
                            section("TEXT") {
                                TextEditor(text:$textDraft).font(.system(size:12)).frame(height:75).scrollContentBackground(.hidden).padding(5).background(Theme.background,in:RoundedRectangle(cornerRadius:4)).accessibilityLabel("Title text")
                                    .focused($textFocused)
                                    .onAppear { syncDraft(from:clip,force:true); store.flushPendingEdits = { flushTextCommit() } }
                                    .onChange(of:clip.id) { _,_ in syncDraft(from:clip,force:true) }
                                    // Undo/redo or Reset changed the text: follow it even while focused.
                                    .onChange(of:clip.style.text) { _,now in followOutsideChange(now) }
                                    .onChange(of:textDraft) { _,draft in scheduleTextCommit(draft) }
                                    .onChange(of:textFocused) { _,focused in
                                        store.isEditingText = focused
                                        if !focused { flushTextCommit(); store.endLiveEdit() }
                                    }
                                    .onDisappear { store.isEditingText = false; flushTextCommit(); store.endLiveEdit(); store.flushPendingEdits = nil }
                                TitleFontControls(fontName:clip.style.fontName,revision:store.fontsRevision,addedFolder:store.fontFolder,
                                                  isAdding:store.isAddingFonts,apply:{ [clipID = clip.id] in store.applyFont($0,to:clipID) },
                                                  addFonts:{ store.chooseFonts(applyToSelection:true) }).equatable()
                                control("Font size",\.fontSize,range:8...300,suffix:" pt")
                                ColorPicker("Text colour",selection:Binding(get:{Color(red:clip.style.red,green:clip.style.green,blue:clip.style.blue)},set:{color in
                                    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                                    // The picker re-sends its colour after a colour-space round trip; that is not an edit.
                                    let s = clip.style, tolerance = 0.5/255
                                    guard abs(c.redComponent-s.red) > tolerance || abs(c.greenComponent-s.green) > tolerance || abs(c.blueComponent-s.blue) > tolerance else { return }
                                    store.updateStyleLive(clip.id,name:"Text colour") { $0.red = c.redComponent; $0.green = c.greenComponent; $0.blue = c.blueComponent }
                                }),supportsOpacity:false)
                            }
                        }
                        Button("Reset appearance") { store.updateStyle { style in let text = style.text; style = ClipStyle(); style.text = text } }.controlSize(.small)
                    }.padding(16)
                }
            } else if let gap = store.selectedGap {
                VStack(alignment:.leading,spacing:18) {
                    VStack(alignment:.leading,spacing:6) {
                        Text("Empty space").font(.system(size:13,weight:.semibold))
                        Text("\(gap.lane.rawValue) · Gap").font(.system(size:10)).foregroundStyle(Theme.accent)
                    }
                    section("TIMING") {
                        info("Start",store.project.frameRate.timecode(gap.start))
                        info("End",store.project.frameRate.timecode(gap.end))
                        info("Duration",store.project.frameRate.timecode(gap.duration))
                    }
                    Text("Closing the gap pulls every later clip on \(gap.lane.rawValue) — and its linked audio — back by the gap length.")
                        .font(.system(size:11)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                    Button("Close Gap  ⌘⌫") { store.closeSelectedGap() }.controlSize(.small)
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                Spacer(minLength:0)
            } else {
                VStack(spacing:12) {
                    Image(systemName:"cursorarrow.click").font(.system(size:25,weight:.light))
                    Text("Select a timeline clip").font(.system(size:12,weight:.medium))
                    Text("Double-click empty track space\nto select a gap.").font(.system(size:11)).multilineTextAlignment(.center)
                }.foregroundStyle(Theme.muted).frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }.background(Theme.panel)
    }
    /// A transition picked on the timeline: its kind, its length (fitted to its clips), removal.
    @ViewBuilder private func transitionInspector(_ transition: FrameCore.Transition) -> some View {
        let project = store.project
        let lane = (transition.from ?? transition.to).flatMap(project.clip)?.lane.rawValue ?? "V"
        let placement = transition.isCut ? "Across a cut" : transition.to != nil ? "Fade in" : "Fade out"
        var others = project
        let _ = others.transitions.removeAll { $0.id == transition.id }
        let longest = max(project.frameRate.frame.seconds,others.longestTransition(from:transition.from,to:transition.to).seconds)
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                VStack(alignment:.leading,spacing:6) {
                    Text(transition.kind.name).font(.system(size:13,weight:.semibold))
                    Text("\(lane) · \(placement)").font(.system(size:10)).foregroundStyle(Theme.accent)
                }
                Image(nsImage:TransitionPreviews.image(transition.kind,direction:transition.direction)).resizable().aspectRatio(16/9,contentMode:.fit)
                    .clipShape(RoundedRectangle(cornerRadius:4)).frame(maxWidth:220)
                section("TRANSITION") {
                    HStack {
                        Text("Kind").foregroundStyle(Theme.muted); Spacer()
                        Picker("",selection:Binding(get:{store.selectedTransition?.kind ?? transition.kind},set:{ store.updateSelectedTransition(kind:$0) })) {
                            ForEach(TransitionKind.Category.allCases,id:\.self) { category in
                                Section(category.rawValue) {
                                    ForEach(TransitionKind.allCases.filter { $0.category == category }) { Text($0.name).tag($0) }
                                }
                            }
                        }.labelsHidden().controlSize(.small).frame(maxWidth:150)
                    }
                    if transition.kind.hasDirection {
                        HStack {
                            Text("Direction").foregroundStyle(Theme.muted); Spacer()
                            Picker("",selection:Binding(get:{store.selectedTransition?.direction ?? transition.direction},set:{ store.updateSelectedTransition(direction:$0) })) {
                                ForEach(TransitionDirection.allCases) { direction in
                                    Image(systemName:"arrow.\(direction.rawValue)").tag(direction).accessibilityLabel(direction.rawValue.capitalized)
                                }
                            }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(maxWidth:150)
                        }
                    }
                    HStack {
                        Text("Duration").foregroundStyle(Theme.muted); Spacer()
                        Text(String(format:"%.2f s",(store.selectedTransition?.duration ?? transition.duration).seconds)).font(.system(size:10,design:.monospaced))
                    }
                    Slider(value:Binding(get:{store.selectedTransition?.duration.seconds ?? transition.duration.seconds},
                                         set:{ store.updateSelectedTransition(duration:MediaTime(seconds:$0)) }),
                           in:project.frameRate.frame.seconds...max(project.frameRate.frame.seconds+0.001,longest),
                           onEditingChanged:{ active in if active { store.beginInteraction() } else { store.endInteraction() } })
                        .controlSize(.mini).accessibilityLabel("Transition duration")
                        .help(transition.isCut ? "Drag either edge of the transition on the timeline to resize around the cut."
                              : transition.to != nil ? "Drag the transition's right edge on the timeline; its start stays anchored."
                              : "Drag the transition's left edge on the timeline; its end stays anchored.")
                    Text(!transition.isCut ? "Plays inside the clip; the tracks below show through."
                         : transition.kind.needsBothPictures ? "Centred on the cut, both clips playing. Where a clip has no footage beyond the cut, its edge frame is held."
                         : "Centred on the cut: out of the first clip, into the next. Needs no footage beyond the cut.")
                        .font(.system(size:9)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                }
                Button("Remove transition  ⌫") { store.removeSelectedTransition() }.controlSize(.small)
            }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private func syncDraft(from clip: Clip, force: Bool) {
        // A new document counts as a new clip even when ids match (Save As keeps them).
        if clip.id != draftClipID || draftSession != store.session {
            flushTextCommit(); store.endLiveEdit()
            draftClipID = clip.id; draftSession = store.session
            textDraft = clip.style.text; lastCommitted = clip.style.text; return
        }
        if force || !textFocused, textDraft != clip.style.text { textDraft = clip.style.text; lastCommitted = clip.style.text }
    }
    private func followOutsideChange(_ now: String) {
        // Our own debounced commit arriving back is not an outside change; overwriting the field
        // then would cut off whatever was typed since, including a Hangul syllable mid-composition.
        guard now != lastCommitted, now != textDraft else { return }
        textCommit?.cancel(); textCommit = nil
        textDraft = now; lastCommitted = now
    }
    /// Commits a short moment after the last keystroke. The preview follows the typing without
    /// re-rendering the whole editor, and the text view's own state is never overwritten.
    private func scheduleTextCommit(_ draft: String) {
        guard let id = draftClipID else { return }
        textCommit?.cancel()
        textCommit = Task { @MainActor in
            try? await Task.sleep(for:.milliseconds(160))
            guard !Task.isCancelled else { return }
            textCommit = nil      // done: a later flush must not commit this draft a second time
            commitText(draft,to:id)
        }
    }
    private func flushTextCommit() {
        guard let task = textCommit, let id = draftClipID else { return }
        task.cancel(); textCommit = nil
        commitText(textDraft,to:id)
    }
    private func commitText(_ draft: String, to id: UUID) {
        // An IME cancelling a composition can hand Escape to the field as a character. Control
        // characters are invisible in a title, so drop them; newline and tab stay, and format
        // characters such as the emoji zero-width joiner are not controls and are kept.
        let visible = String(String.UnicodeScalarView(draft.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control
        }))
        let text = String(visible.prefix(2000))
        guard draftSession == store.session,
              store.project.clips.first(where: { $0.id == id })?.style.text != text else { return }
        if id == draftClipID { lastCommitted = text }
        store.updateStyleLive(id,name:"Edit text",closesWhenIdle:false) { $0.text = text }
    }
    private func section<Content:View>(_ title:String,@ViewBuilder content:()->Content) -> some View {
        VStack(alignment:.leading,spacing:10) { panelTitle(title); content() }.font(.system(size:11))
    }
    private func info(_ key:String,_ value:String) -> some View {
        HStack { Text(key).foregroundStyle(Theme.muted); Spacer(); Text(value).font(.system(size:10,design:.monospaced)) }
    }
    private func control(_ label:String,_ key:WritableKeyPath<ClipStyle,Double>,range:ClosedRange<Double>,multiplier:Double = 1,suffix:String = "") -> some View {
        VStack(spacing:5) {
            HStack {
                Text(label).foregroundStyle(Theme.muted); Spacer()
                Text(String(format:"%.0f",(store.selectedClip?.style[keyPath:key] ?? 0)*multiplier)+suffix).font(.system(size:10,design:.monospaced))
            }
            Slider(value:Binding(get:{store.selectedClip?.style[keyPath:key] ?? range.lowerBound},set:{v in store.updateStyle { $0[keyPath:key] = v } }),in:range,onEditingChanged:{ active in if active { store.beginInteraction() } else { store.endInteraction() } }).controlSize(.mini).accessibilityLabel(label)
        }
    }
}


/// Family and style menus for a title, the font file button, and a note when the title's font is
/// not on this Mac (it is drawn in the default font until the font is added). Equatable on what it
/// shows, so the inspector's many unrelated updates do not rebuild its ~250-item family menu.
struct TitleFontControls: View, Equatable {
    let fontName: String
    let revision: Int
    let addedFolder: URL
    let isAdding: Bool
    let apply: (String) -> Void
    let addFonts: () -> Void
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.fontName == b.fontName && a.revision == b.revision && a.addedFolder == b.addedFolder && a.isAdding == b.isAdding
    }
    var body: some View {
        let current = FontLibrary.face(fontName)
        let menu = FontMenu.families(revision,addedIn:addedFolder)
        let listed = Set((menu.added+menu.system).map(\.name))
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("Font").foregroundStyle(Theme.muted); Spacer()
                Picker("",selection:Binding(get:{ current?.family ?? FontMenu.missingTag },set:{ family in
                    guard family != FontMenu.missingTag, family != current?.family,
                          let face = FontLibrary.closestFace(inFamily:family,toWeight:current?.weight ?? 0.4,italic:current?.isItalic ?? false) else { return }
                    apply(face.postScriptName)
                })) {
                    if current == nil { Text("\(fontName) (missing)").tag(FontMenu.missingTag) }
                    // A family installed since the list was made (Font Book) still has an entry.
                    if let current, !listed.contains(current.family) { Text(current.familyDisplayName).tag(current.family) }
                    if !menu.added.isEmpty {
                        Section("Added") { ForEach(menu.added) { Text($0.displayName).tag($0.name) } }
                    }
                    Section("System") { ForEach(menu.system) { Text($0.displayName).tag($0.name) } }
                }.labelsHidden().controlSize(.small).frame(maxWidth:170).accessibilityLabel("Font family")
            }
            if let current {
                let faces = FontLibrary.faces(ofFamily:current.family)
                let repeated = Dictionary(grouping:faces,by:\.style).filter { $0.value.count > 1 }.keys
                if faces.count > 1 {
                    HStack {
                        Text("Style").foregroundStyle(Theme.muted); Spacer()
                        Picker("",selection:Binding(get:{ current.postScriptName },set:{ name in
                            if name != current.postScriptName { apply(name) }
                        })) {
                            // Two faces with one style name (a static file and a variable font of the
                            // same family) are told apart by their PostScript names.
                            ForEach(faces) { Text(repeated.contains($0.style) ? "\($0.style) · \($0.postScriptName)" : $0.style).tag($0.postScriptName) }
                        }.labelsHidden().controlSize(.small).frame(maxWidth:170).accessibilityLabel("Font style")
                    }
                }
            } else {
                Text("“\(fontName)” isn't on this Mac, so the title is shown in Helvetica Neue Bold. Add the font to use it again.")
                    .font(.system(size:9)).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
            }
            HStack(spacing:8) {
                Button("Add Font…",action:addFonts).controlSize(.small).disabled(isAdding)
                    .help("TTF, OTF or TTC files, or the ZIP they came in. Ara keeps its own copy, and the new font is put on this title.")
                if isAdding { ProgressView().controlSize(.mini).accessibilityLabel("Adding fonts") }
            }
        }
    }
}

/// Font families for the title font menu, split into the fonts added to Ara and the Mac's own.
/// Listing every family takes a moment, so it is done once per set of fonts, not per redraw.
@MainActor enum FontMenu {
    static let missingTag = "\u{0}missing"
    private static var cache: (revision: Int, added: [FontLibrary.Family], system: [FontLibrary.Family])?
    /// Lists the families off the main thread ahead of time (at launch, after fonts change), so
    /// the first title selected does not wait for it.
    static func warm(_ revision: Int, addedIn folder: URL) async {
        if let cache, cache.revision == revision { return }
        let all = await Task.detached(priority:.utility) { FontLibrary.families() }.value
        let added = Set(FontLibrary.addedFaces(in:folder).map(\.family))
        cache = (revision,all.filter { added.contains($0.name) },all.filter { !added.contains($0.name) })
    }
    static func families(_ revision: Int, addedIn folder: URL) -> (added: [FontLibrary.Family], system: [FontLibrary.Family]) {
        if let cache, cache.revision == revision { return (cache.added,cache.system) }
        let all = FontLibrary.families(), added = Set(FontLibrary.addedFaces(in:folder).map(\.family))
        let split = (all.filter { added.contains($0.name) },all.filter { !added.contains($0.name) })
        cache = (revision,split.0,split.1)
        return split
    }
}
