import SwiftUI
import AppKit
import FrameCore
import FrameMedia

struct InspectorPanel: View {
    @ObservedObject var store: EditorStore
    @ObservedObject private var shortcuts = ShortcutSettings.shared
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
    /// The title whose appearance slider is being dragged: its edits stay one undo step until release.
    @State private var titleDrag: UUID?
    /// Whether the SHADOW, TRANSFORM and COLOUR sections are unfolded; kept across launches.
    @AppStorage("inspector.shadowOpen") private var shadowOpen = true
    @AppStorage("inspector.transformOpen") private var transformOpen = true
    @AppStorage("inspector.colourOpen") private var colourOpen = true
    /// The characters a title keeps (Project.validated): the text field holds no more.
    static let textLimit = 2000
    /// `draft` cut to `textLimit` where it differs from `old`: what was typed or pasted is shortened,
    /// never the text around it, so a key pressed in a full title changes nothing.
    static func fitted(_ draft: String, after old: String) -> String { fitting(draft,after:old).text }
    /// `fitted`, with where the caret goes: after what was kept of the typing or paste (in UTF-16
    /// units, as the text view counts).
    static func fitting(_ draft: String, after old: String) -> (text: String, caret: Int) {
        guard draft.count > textLimit else { return (draft,draft.utf16.count) }
        let new = Array(draft), was = Array(old)
        var head = 0, tail = 0
        while head < min(new.count,was.count), new[head] == was[head] { head += 1 }
        while tail < min(new.count,was.count)-head, new[new.count-1-tail] == was[was.count-1-tail] { tail += 1 }
        guard head+tail <= textLimit else { let text = String(draft.prefix(textLimit)); return (text,text.utf16.count) }
        let kept = String(new[..<head]+new[head..<new.count-tail].prefix(textLimit-head-tail))
        return (kept+String(new[(new.count-tail)...]),kept.utf16.count)
    }
    /// Puts the caret back at `caret` in the text view showing `text` once it shows it: writing the
    /// fitted text back puts the caret at its end, and the next key would act there, out of sight.
    private static func placeCaret(_ caret: Int, in text: String, tries: Int = 5) {
        DispatchQueue.main.async {
            guard let field = NSApp.windows.lazy.compactMap({ $0.firstResponder as? NSTextView }).first(where: { $0.string == text }) else {
                if tries > 1 { placeCaret(caret,in:text,tries:tries-1) }
                return
            }
            field.setSelectedRange(NSRange(location:caret,length:0)); field.scrollRangeToVisible(field.selectedRange())
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            if let transition = store.selectedTransition {
                transitionInspector(transition)
            } else if let clip = store.selectedClip {
                ScrollView {
                    VStack(alignment:.leading,spacing:18) {
                        ClipHeader(store:store,clip:clip)
                        // A title's own settings come first: what it says and how it looks.
                        if clip.kind == .text {
                            section("TEXT") {
                                TextEditor(text:$textDraft).font(.system(size:12)).frame(height:75).scrollContentBackground(.hidden).padding(5).background(Theme.background,in:RoundedRectangle(cornerRadius:4)).accessibilityLabel("Title text")
                                    .focused($textFocused)
                                    .onAppear { syncDraft(from:clip,force:true); store.flushPendingEdits = { flushTextCommit() } }
                                    .onChange(of:clip.id) { _,_ in syncDraft(from:clip,force:true) }
                                    // Undo/redo or Reset changed the text: follow it even while focused.
                                    .onChange(of:clip.style.text) { _,now in followOutsideChange(now) }
                                    // Also when an undo lands on the text last drawn: typing flushed and undone
                                    // in one call never shows the text change above.
                                    .onChange(of:store.textRevision) { _,_ in
                                        if let now = store.project.clips.first(where: { $0.id == draftClipID })?.style.text { followOutsideChange(now) }
                                    }
                                    .onChange(of:textDraft) { old,draft in
                                        // The field holds no more than the title keeps: a longer paste is cut here, in
                                        // view, and the caret stays after what was kept.
                                        if draft.count > Self.textLimit {
                                            let fitted = Self.fitting(draft,after:old)
                                            textDraft = fitted.text; Self.placeCaret(fitted.caret,in:fitted.text); return
                                        }
                                        scheduleTextCommit(composing()?.string ?? draft)
                                    }
                                    // A syllable an input method is still composing (Hangul) is in the field
                                    // but not yet in the binding: the title shows it at once all the same, and
                                    // loses it again when the composition is cancelled.
                                    // (The text view says nothing of marked text; its storage does.)
                                    .onReceive(NotificationCenter.default.publisher(for:NSTextStorage.didProcessEditingNotification)) { note in
                                        guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters),
                                              let field = focusedField(), field.textStorage === storage else { return }
                                        scheduleTextCommit(field.string)
                                    }
                                    .onChange(of:textFocused) { _,focused in
                                        store.isEditingText = focused
                                        if !focused { flushTextCommit(); store.endLiveEdit() }
                                    }
                                    .onDisappear { store.isEditingText = false; flushTextCommit(); store.endLiveEdit(); store.flushPendingEdits = nil }
                                if textDraft.count >= Self.textLimit {
                                    Text("A title holds up to \(Self.textLimit) characters.")
                                        .font(.system(size:9)).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
                                }
                                TitleFontControls(fontName:clip.style.fontName,revision:store.fontsRevision,addedFolder:store.fontFolder,
                                                  isAdding:store.isAddingFonts,apply:{ [clipID = clip.id] in store.applyFont($0,to:clipID) },
                                                  addFonts:{ store.chooseFonts(applyToSelection:true) }).equatable()
                                titleControl("Font size",\.fontSize,range:8...300,suffix:" pt",clip:clip)
                                titleColor("Text colour",\.red,\.green,\.blue,clip:clip)
                            }
                            // Width and opacity switch the effect on; the rest wait until it is.
                            section("OUTLINE") {
                                titleControl("Width",\.outlineWidth,range:0...20,suffix:" pt",clip:clip,undoName:"Outline",switches:true)
                                titleColor("Outline colour",\.outlineRed,\.outlineGreen,\.outlineBlue,clip:clip).disabled(!clip.style.hasOutline)
                            }
                            FoldingSection(title:"SHADOW",isOpen:$shadowOpen,
                                           summary:clip.style.hasShadow ? .amount(Self.reading(clip.style.shadowOpacity,multiplier:100,switches:true)+"%",
                                                                                  TitleColor(red:clip.style.shadowRed,green:clip.style.shadowGreen,blue:clip.style.shadowBlue)) : .off) {
                                titleControl("Opacity",\.shadowOpacity,range:0...1,multiplier:100,suffix:"%",clip:clip,undoName:"Shadow",switches:true)
                                Group {
                                    titleControl("Distance",\.shadowDistance,range:0...40,suffix:" pt",clip:clip,undoName:"Shadow")
                                    titleControl("Angle",\.shadowAngle,range:-180...180,suffix:"°",clip:clip,undoName:"Shadow")
                                    titleControl("Blur",\.shadowBlur,range:0...40,suffix:" pt",clip:clip,undoName:"Shadow")
                                    titleColor("Shadow colour",\.shadowRed,\.shadowGreen,\.shadowBlue,clip:clip)
                                }.disabled(!clip.style.hasShadow)
                            }
                            // A colour folded away hides its presets, and unfolds without them.
                            .onChange(of:shadowOpen) { _,open in if !open { store.colorPresetRow.close("Shadow colour") } }
                        }
                        if clip.kind == .video || clip.kind == .audio {
                            section("SPEED") {
                                HStack {
                                    Text("Playback").foregroundStyle(Theme.muted); Spacer()
                                    // Type any speed from 0.1x to 10x; Return applies it.
                                    SpeedField(store:store)
                                }
                                // On a log scale, so 1x sits in the middle and slow speeds get as much room as fast ones.
                                Slider(value:Binding(get:{log2(store.selectedClip?.speed ?? 1)},
                                                     set:{ v in store.setSpeedInteractively(min(Clip.speedRange.upperBound,max(Clip.speedRange.lowerBound,(pow(2,v)*20).rounded()/20))) }),
                                       in:log2(Clip.speedRange.lowerBound)...log2(Clip.speedRange.upperBound),
                                       onEditingChanged:{ active in if active { store.beginInteraction() } else { store.endInteraction() } })
                                    .controlSize(.mini).accessibilityLabel("Playback speed")
                                HStack(spacing:5) {
                                    ForEach([0.25,0.5,1.0,2.0,4.0,5.0],id:\.self) { preset in
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
                            FoldingSection(title:"TRANSFORM",isOpen:$transformOpen,summary:Self.isDefaultTransform(clip.style) ? .unchanged : .changed) {
                                control("Position X",\.x,range:-1...1,multiplier:100,suffix:"%")
                                control("Position Y",\.y,range:-1...1,multiplier:100,suffix:"%")
                                control("Scale",\.scale,range:0.05...4,multiplier:100,suffix:"%")
                                control("Rotation",\.rotation,range:-180...180,suffix:"°")
                                control("Opacity",\.opacity,range:0...1,multiplier:100,suffix:"%")
                            }
                            FoldingSection(title:"COLOUR · SDR",isOpen:$colourOpen,summary:Self.isDefaultColour(clip.style) ? .unchanged : .changed) {
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
                        // Where the clip is: read-only, so below everything that changes it.
                        section("TIMING") {
                            info("Start",store.project.frameRate.timecode(clip.start))
                            info("Source in",store.project.frameRate.timecode(clip.sourceStart))
                            info("Duration",store.project.frameRate.timecode(clip.duration))
                        }
                        Button("Reset appearance") { store.updateStyle { style in let text = style.text; style = ClipStyle(); style.text = text } }.controlSize(.small)
                    }.padding(16)
                }
            } else if store.hasMultipleSelection {
                multipleSelection
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
                    Button("Close Gap  \(shortcuts.label(.closeGap))") { store.closeSelectedGap() }.controlSize(.small)
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
        let placement = transition.isCut ? String(localized:"Across a cut") : transition.to != nil ? String(localized:"Fade in") : String(localized:"Fade out")
        var others = project
        let _ = others.transitions.removeAll { $0.id == transition.id }
        let longest = max(project.frameRate.frame.seconds,others.longestTransition(from:transition.from,to:transition.to).seconds)
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                VStack(alignment:.leading,spacing:6) {
                    Text(transition.kind.displayName).font(.system(size:13,weight:.semibold))
                    Text(verbatim:"\(lane) · \(placement)").font(.system(size:10)).foregroundStyle(Theme.accent).lineLimit(1)
                }
                Image(nsImage:TransitionPreviews.image(transition.kind,direction:transition.direction)).resizable().aspectRatio(16/9,contentMode:.fit)
                    .clipShape(RoundedRectangle(cornerRadius:4)).frame(maxWidth:220)
                section("TRANSITION") {
                    HStack {
                        Text("Kind").foregroundStyle(Theme.muted); Spacer()
                        Picker("",selection:Binding(get:{store.selectedTransition?.kind ?? transition.kind},set:{ store.updateSelectedTransition(kind:$0) })) {
                            ForEach(TransitionKind.Category.allCases,id:\.self) { category in
                                Section(category.displayName) {
                                    ForEach(TransitionKind.allCases.filter { $0.category == category }) { Text($0.displayName).tag($0) }
                                }
                            }
                        }.labelsHidden().controlSize(.small).frame(maxWidth:150)
                    }
                    if transition.kind.hasDirection {
                        HStack {
                            Text("Direction").foregroundStyle(Theme.muted); Spacer()
                            Picker("",selection:Binding(get:{store.selectedTransition?.direction ?? transition.direction},set:{ store.updateSelectedTransition(direction:$0) })) {
                                ForEach(TransitionDirection.allCases) { direction in
                                    Image(systemName:"arrow.\(direction.rawValue)").tag(direction).accessibilityLabel(direction.displayName)
                                }
                            }.pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(maxWidth:150)
                        }
                    }
                    HStack {
                        Text("Duration").foregroundStyle(Theme.muted); Spacer()
                        Text(String(format:String(localized:"%.2f s"),(store.selectedTransition?.duration ?? transition.duration).seconds)).font(.system(size:10,design:.monospaced))
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
                // Names the key Delete is set to now (none when it has no shortcut).
                Button("Remove transition  \(shortcuts.label(.delete))") { store.removeSelectedTransition() }.controlSize(.small)
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
    /// The title's text view while it has the keyboard (the text field's editor, a field editor,
    /// is some other field's).
    private func focusedField() -> NSTextView? {
        guard textFocused else { return nil }
        return NSApp.windows.lazy.compactMap { $0.firstResponder as? NSTextView }.first { !$0.isFieldEditor }
    }
    /// The focused text view while an input method composes in it.
    private func composing() -> NSTextView? { focusedField().flatMap { $0.hasMarkedText() ? $0 : nil } }
    /// Commits a short moment after the last keystroke. The preview follows the typing without
    /// re-rendering the whole editor, and the text view's own state is never overwritten.
    private func scheduleTextCommit(_ draft: String) {
        guard let id = draftClipID else { return }
        textCommit?.cancel()
        textCommit = Task { @MainActor in
            try? await Task.sleep(for:.milliseconds(80))
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
        let text = String(visible.prefix(Self.textLimit))
        guard draftSession == store.session,
              store.project.clips.first(where: { $0.id == id })?.style.text != text else { return }
        if id == draftClipID { lastCommitted = text }
        store.updateStyleLive(id,name:"Edit text",closesWhenIdle:false) { $0.text = text }
    }
    /// Several clips selected on the timeline: what they span, and what can be done with them.
    private var multipleSelection: some View {
        let ids = store.selectionForEditing
        // Each selected clip with its linked partner, found in one pass.
        let groups = Set(store.project.clips.filter { ids.contains($0.id) }.map { $0.linkID ?? $0.id })
        let clips = store.project.clips.filter { groups.contains($0.linkID ?? $0.id) }
        // A video with its linked audio counts once, as the timeline shows one selection for both.
        let count = groups.count
        let start = clips.map(\.start).min() ?? .zero, end = clips.map(\.end).max() ?? .zero
        return VStack(alignment:.leading,spacing:18) {
            VStack(alignment:.leading,spacing:6) {
                Text("\(count) clips selected").font(.system(size:13,weight:.semibold))
                Text("Multiple selection").font(.system(size:10)).foregroundStyle(Theme.accent)
            }
            section("RANGE") {
                info("Start",store.project.frameRate.timecode(start))
                info("End",store.project.frameRate.timecode(end))
                info("Span",store.project.frameRate.timecode(end-start))
            }
            HStack(spacing:6) {
                Button("Copy") { store.copySelection() }
                Button("Cut") { store.cutSelection() }.disabled(store.isExporting)
                Button("Delete") { store.deleteSelection() }.disabled(store.isExporting)
            }.controlSize(.small)
            Text("Drag any of them on the timeline to move them together. Shift-click adds or removes a clip, Shift-drag over empty track space adds more, Esc clears.")
                .font(.system(size:10)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:0)
        }.padding(16)
    }
    private func section<Content:View>(_ title:String,@ViewBuilder content:()->Content) -> some View {
        VStack(alignment:.leading,spacing:10) { panelTitle(title); content() }.font(.system(size:11))
    }
    private func info(_ key:String,_ value:String) -> some View {
        HStack { Text(LocalizedStringKey(key)).foregroundStyle(Theme.muted); Spacer(); Text(value).font(.system(size:10,design:.monospaced)) }
    }
    /// What an appearance slider does with a value: one live edit of the clip, kept in `range`.
    /// Turning and scaling go about the clip's alignment point, as the preview's handle and pinch
    /// do; the frame in 1080 units stands in for the viewer, as the point lands alike at any size.
    /// A value that switches a title's effect on (`switches`) and reads 0 is 0: the effect is off,
    /// as its label says.
    static func slide(_ key: WritableKeyPath<ClipStyle,Double>, to value: Double, range: ClosedRange<Double>, multiplier: Double = 1, switches: Bool = false,
                      of id: UUID, name: String, closesWhenIdle: Bool, in store: EditorStore) {
        guard let clip = store.project.clips.first(where: { $0.id == id }) else { return }
        var kept = min(range.upperBound,max(range.lowerBound,value))
        if switches, (kept*multiplier).rounded() == 0 { kept = 0 }
        let turns = key == \ClipStyle.rotation || key == \ClipStyle.scale
        let geometry = turns ? (store.previewSourceSize(for:clip) ?? letters(of:clip)).map {
            VisualGeometry(sourceSize:$0,canvasSize:store.project.aspectRatio.size(),style:clip.style,isText:clip.kind == .text)
        } : nil
        store.updateStyleLive(id,name:name,closesWhenIdle:closesWhenIdle) { style in
            style[keyPath:key] = kept
            if let geometry { style = geometry.keepingAnchor(style) }
        }
    }
    /// A title's letters' box drawn here, for when the preview has no picture of it (not built
    /// yet, or stopped by a missing source), measured as `previewSourceSize` measures it.
    private static func letters(of clip: Clip) -> CGSize? {
        guard clip.kind == .text, let image = try? FrameRenderer.textImage(clip.style) else { return nil }
        let margin = FrameRenderer.effectMargin(clip.style)
        return CGSize(width:max(1,image.extent.width-2*margin),height:max(1,image.extent.height-2*margin))
    }
    /// A title slider's value as its label reads it: whole steps, rounded as `slide` rounds (+ 0
    /// turns −0 into 0). An effect that is on never reads 0: one saved below a step by an earlier
    /// Ara shows its tenths.
    /// Whether a clip is placed as it came in: TRANSFORM folded says Default rather than Edited.
    static func isDefaultTransform(_ style: ClipStyle) -> Bool {
        let plain = ClipStyle()
        return style.x == plain.x && style.y == plain.y && style.scale == plain.scale && style.rotation == plain.rotation && style.opacity == plain.opacity
    }
    /// Whether a clip's colour is as it came in, for COLOUR folded.
    static func isDefaultColour(_ style: ClipStyle) -> Bool {
        let plain = ClipStyle()
        return style.brightness == plain.brightness && style.contrast == plain.contrast && style.saturation == plain.saturation
    }
    static func reading(_ value: Double, multiplier: Double = 1, switches: Bool = false) -> String {
        let shown = value*multiplier
        if switches, shown > 0, shown.rounded() == 0 { return String(format:"%.1f",max(0.1,(shown*10).rounded()/10)) }
        return String(format:"%.0f",shown.rounded()+0)
    }
    /// A slider for how a title is drawn. It redraws the title in the preview without rebuilding
    /// the composition, and one drag is one undo step.
    private func titleControl(_ label:String,_ key:WritableKeyPath<ClipStyle,Double>,range:ClosedRange<Double>,multiplier:Double = 1,suffix:String = "",clip:Clip,undoName:String? = nil,switches:Bool = false) -> some View {
        VStack(spacing:5) {
            HStack {
                Text(LocalizedStringKey(label)).foregroundStyle(Theme.muted); Spacer()
                Text(Self.reading(clip.style[keyPath:key],multiplier:multiplier,switches:switches)+suffix).font(.system(size:10,design:.monospaced))
            }
            Slider(value:Binding(get:{store.selectedClip?.style[keyPath:key] ?? range.lowerBound},set:{v in
                       // Keyboard steps have no drag around them: those close after a pause.
                       Self.slide(key,to:v,range:range,multiplier:multiplier,switches:switches,of:clip.id,name:undoName ?? label,closesWhenIdle:titleDrag != clip.id,in:store)
                   }),in:range,onEditingChanged:{ active in
                       // The title's typed text lands first, as its own step.
                       if active { store.commitPendingEdits(); titleDrag = clip.id } else { titleDrag = nil; store.endLiveEdit() }
                   }).controlSize(.mini).accessibilityLabel(Text(LocalizedStringKey(undoName.map { "\($0) \(label.lowercased())" } ?? label)))
        }
    }
    /// A title colour: its swatch, the presets beside it, and the palette (ColorControls.swift).
    private func titleColor(_ label:String,_ red:WritableKeyPath<ClipStyle,Double>,_ green:WritableKeyPath<ClipStyle,Double>,_ blue:WritableKeyPath<ClipStyle,Double>,clip:Clip) -> some View {
        TitleColorControl(store:store,target:ColorTarget(clipID:clip.id,red:red,green:green,blue:blue,name:label),
                          color:TitleColor(red:clip.style[keyPath:red],green:clip.style[keyPath:green],blue:clip.style[keyPath:blue]))
    }
    private func control(_ label:String,_ key:WritableKeyPath<ClipStyle,Double>,range:ClosedRange<Double>,multiplier:Double = 1,suffix:String = "") -> some View {
        VStack(spacing:5) {
            HStack {
                Text(LocalizedStringKey(label)).foregroundStyle(Theme.muted); Spacer()
                Text(String(format:"%.0f",(store.selectedClip?.style[keyPath:key] ?? 0)*multiplier)+suffix).font(.system(size:10,design:.monospaced))
            }
            if key == \ClipStyle.volume {
                // Volume changes the audio mix (and the linked clip's level): that needs a rebuild.
                Slider(value:Binding(get:{store.selectedClip?.style[keyPath:key] ?? range.lowerBound},set:{v in store.updateStyle { $0[keyPath:key] = v } }),in:range,onEditingChanged:{ active in if active { store.beginInteraction() } else { store.endInteraction() } }).controlSize(.mini).accessibilityLabel(Text(LocalizedStringKey(label)))
            } else {
                // Placement and colour only change how the layer is drawn: the preview shows each
                // step at once, without rebuilding the composition, and one drag is one undo step.
                Slider(value:Binding(get:{store.selectedClip?.style[keyPath:key] ?? range.lowerBound},set:{v in
                           guard let id = store.selectedClipID else { return }
                           Self.slide(key,to:v,range:range,of:id,name:"Adjust clip",closesWhenIdle:titleDrag != id,in:store)
                       }),in:range,onEditingChanged:{ active in
                           if active { store.commitPendingEdits(); titleDrag = store.selectedClipID } else { titleDrag = nil; store.endLiveEdit() }
                       }).controlSize(.mini).accessibilityLabel(Text(LocalizedStringKey(label)))
            }
        }
    }
}

/// The selected clip's name, its track and kind, and for a picture the buttons that place its
/// alignment point, on a row of their own so the name and track keep the panel's width.
struct ClipHeader: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    private var placing: Bool { store.anchorEditID == clip.id }
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(alignment:.top,spacing:6) {
                Text(clip.name).font(.system(size:13,weight:.semibold)).lineLimit(2)
                Spacer(minLength:4)
                favoriteButton
            }
            // One line: a narrow panel shortens it rather than break "V1 · Video" in two.
            HStack { Text(verbatim:"\(clip.lane.rawValue) · \(clip.kind.displayName)"); if clip.linkID != nil { Image(systemName:"link"); Text("Linked A/V") } }
                .font(.system(size:10)).foregroundStyle(Theme.accent).lineLimit(1)
            // Where the clip's alignment point is: turning and scaling go about it, and moving lines
            // it up with the frame's centre and other clips' points. Side by side while they fit.
            if clip.lane.isVideo {
                ViewThatFits(in:.horizontal) {
                    HStack(spacing:6) { adjustButton; resetButton }
                    VStack(alignment:.leading,spacing:5) { adjustButton; resetButton }
                }.padding(.top,4)
            }
        }
    }
    /// Keeps the clip in the favourites (the ★ at the panel's top right), or lets it go.
    private var favoriteButton: some View {
        let kept = store.isFavorite(clip)
        return Button { store.toggleFavorite(clip) } label: {
            Image(systemName:kept ? "star.fill" : "star").font(.system(size:14,weight:.semibold))
                .foregroundStyle(kept ? Color(red:1,green:0.84,blue:0.04) : Theme.muted)
                .frame(width:24,height:22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kept ? "Remove from Favourites" : "Keep in Favourites, to drag onto any project's timeline")
        .accessibilityLabel(kept ? Text("Remove from Favourites") : Text("Keep in Favourites"))
    }
    private var adjustButton: some View {
        Button { withAnimation(.snappy(duration:0.2)) { store.editAnchor(clip) } } label: {
            Label(placing ? "Done" : "Adjust alignment point",systemImage:placing ? "checkmark.circle.fill" : "scope")
                .font(.system(size:10,weight:.semibold)).lineLimit(1).fixedSize().padding(.horizontal,8).padding(.vertical,5)
                .foregroundStyle(placing ? Theme.background : Color.primary)
                .background(placing ? Theme.accent : Theme.raised,in:RoundedRectangle(cornerRadius:5))
        }
        .buttonStyle(.plain).disabled(store.isExporting || store.isCapturingSnapshot)
        .help("Click, then click or drag in the preview to place the alignment point. It catches the centre, corners and edges.")
    }
    /// Only while placing the point. With nothing to reset it is dimmed once, as disabled, and not
    /// again on top, so it stays legible.
    @ViewBuilder private var resetButton: some View {
        if placing {
            Button { store.resetAnchor(clip) } label: {
                Label("Reset alignment point",systemImage:"arrow.counterclockwise")
                    .font(.system(size:10,weight:.semibold)).lineLimit(1).fixedSize().padding(.horizontal,8).padding(.vertical,5)
                    .background(Theme.raised,in:RoundedRectangle(cornerRadius:5))
            }
            .buttonStyle(.plain).disabled(!clip.style.hasAnchor || store.isExporting)
            .help("Put the alignment point back in the middle of the clip")
            .transition(.opacity)
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
    /// The font's name marked as not on this Mac, for the menu and its button.
    private var missingTitle: String { String(localized:"\(fontName) (missing)") }
    private func familyEntries(current: FontLibrary.Face?, menu: (added: [FontLibrary.Family], system: [FontLibrary.Family]), listed: Set<String>) -> [FontPopUp.Entry] {
        var entries: [FontPopUp.Entry] = []
        if current == nil { entries.append(.item(tag:FontMenu.missingTag,title:missingTitle,face:nil)) }
        // A family installed since the list was made (Font Book) still has an entry.
        if let current, !listed.contains(current.family) {
            entries.append(.item(tag:current.family,title:current.familyDisplayName,face:FontMenu.previewFace(of:FontLibrary.Family(name:current.family,displayName:current.familyDisplayName))))
        }
        // AppKit draws the headers as given: they are looked up here.
        if !menu.added.isEmpty {
            entries.append(.header(String(localized:"Added")))
            entries += menu.added.map { .family($0) }
        }
        entries.append(.header(String(localized:"System")))
        entries += menu.system.map { .family($0) }
        return entries
    }
    var body: some View {
        let current = FontLibrary.face(fontName)
        let menu = FontMenu.families(revision,addedIn:addedFolder)
        let listed = Set((menu.added+menu.system).map(\.name))
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("Font").foregroundStyle(Theme.muted); Spacer()
                // Each family in its own face, so the menu shows what it offers.
                FontPopUp(entries:familyEntries(current:current,menu:menu,listed:listed),selected:current?.family ?? FontMenu.missingTag,
                          title:current?.familyDisplayName ?? missingTitle,label:String(localized:"Font family")) { family in
                    guard family != FontMenu.missingTag, family != current?.family,
                          let face = FontLibrary.closestFace(inFamily:family,toWeight:current?.weight ?? 0.4,italic:current?.isItalic ?? false) else { return }
                    apply(face.postScriptName)
                }.frame(maxWidth:170)
            }
            if let current {
                let faces = FontLibrary.faces(ofFamily:current.family)
                let repeated = Dictionary(grouping:faces,by:\.style).filter { $0.value.count > 1 }.keys
                if faces.count > 1 {
                    HStack {
                        Text("Style").foregroundStyle(Theme.muted); Spacer()
                        // Two faces with one style name (a static file and a variable font of the
                        // same family) are told apart by their PostScript names.
                        let readable = FontMenu.previewFace(of:FontLibrary.Family(name:current.family,displayName:current.familyDisplayName)) != nil
                        let entries = faces.map { face in
                            FontPopUp.Entry.item(tag:face.postScriptName,title:repeated.contains(face.style) ? "\(face.style) · \(face.postScriptName)" : face.style,
                                                 face:readable ? face.postScriptName : nil)
                        }
                        FontPopUp(entries:entries,selected:current.postScriptName,title:current.style,label:String(localized:"Font style")) { name in
                            if name != current.postScriptName { apply(name) }
                        }.frame(maxWidth:170)
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
        let (all,faces) = await Task.detached(priority:.utility) { () -> ([FontLibrary.Family],[String:String?]) in
            let all = FontLibrary.families()
            return (all,Dictionary(uniqueKeysWithValues:all.map { ($0.name,FontLibrary.previewFace(of:$0)) }))
        }.value
        let added = Set(FontLibrary.addedFaces(in:folder).map(\.family))
        cache = (revision,all.filter { added.contains($0.name) },all.filter { !added.contains($0.name) })
        previews.merge(faces) { _,new in new }
    }
    /// The face each family's name is shown in (nil: the system font), worked out off the main
    /// thread by warm(), or here on first use.
    private static var previews: [String:String?] = [:]
    static func previewFace(of family: FontLibrary.Family) -> String? {
        if let known = previews[family.name] { return known }
        let face = FontLibrary.previewFace(of:family)
        previews[family.name] = .some(face)
        return face
    }
    static func families(_ revision: Int, addedIn folder: URL) -> (added: [FontLibrary.Family], system: [FontLibrary.Family]) {
        if let cache, cache.revision == revision { return (cache.added,cache.system) }
        let all = FontLibrary.families(), added = Set(FontLibrary.addedFaces(in:folder).map(\.family))
        let split = (all.filter { added.contains($0.name) },all.filter { !added.contains($0.name) })
        cache = (revision,split.0,split.1)
        return split
    }
}


/// A pop-up menu whose items are drawn in their own fonts. The button shows the choice in the
/// system font (a script or display face would overflow it), and the items are made when the
/// menu opens, so selecting a title never waits for some 250 fonts to load.
struct FontPopUp: NSViewRepresentable {
    enum Entry: Equatable {
        case header(String)
        case item(tag: String, title: String, face: String?)
        /// A font family: tagged by its name, shown in its preview face (looked up as the menu opens).
        case family(FontLibrary.Family)
    }
    let entries: [Entry]
    let selected: String
    let title: String
    let label: String
    let choose: (String) -> Void

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var entries: [Entry] = [], selected = "", choose: (String) -> Void = { _ in }
        weak var button: NSPopUpButton?
        private var built: (entries: [Entry], selected: String)?
        /// The shared font objects, one per face, at a size that fits a menu row.
        private static var fonts: [String:NSFont] = [:]
        static func previewFont(_ face: String) -> NSFont? {
            if let font = fonts[face] { return font }
            guard var font = NSFont(name:face,size:13) else { return nil }
            // Very tall faces (Zapfino) are made smaller, to a slightly taller row, but kept readable.
            let height = font.ascender-font.descender+font.leading
            if height > 26, let smaller = NSFont(name:face,size:max(10,13*26/height)) { font = smaller }
            fonts[face] = font
            return font
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard built?.entries != entries || built?.selected != selected else { return }
            built = (entries,selected)
            menu.removeAllItems()
            var chosen: NSMenuItem?
            for entry in entries {
                switch entry {
                case .header(let title): menu.addItem(.sectionHeader(title:title))
                case .item,.family:
                    let (tag,title,face): (String,String,String?) = switch entry {
                    case .item(let tag,let title,let face): (tag,title,face)
                    case .family(let family): (family.name,family.displayName,FontMenu.previewFace(of:family))
                    case .header: ("","",nil)
                    }
                    let item = NSMenuItem(title:title,action:#selector(picked(_:)),keyEquivalent:"")
                    item.target = self; item.representedObject = tag
                    if let face, let font = Self.previewFont(face) { item.attributedTitle = NSAttributedString(string:title,attributes:[.font:font]) }
                    if tag == selected { item.state = .on; chosen = item }
                    menu.addItem(item)
                }
            }
            // Opens with the current choice under the pointer, as a pop-up menu does.
            if let chosen { button?.select(chosen) }
        }
        @objc func picked(_ item: NSMenuItem) { if let tag = item.representedObject as? String { choose(tag) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame:.zero,pullsDown:false)
        button.controlSize = .small; button.font = .systemFont(ofSize:NSFont.smallSystemFontSize)
        button.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let cell = button.cell as? NSPopUpButtonCell
        cell?.usesItemFromMenu = false; cell?.menuItem = NSMenuItem(title:title,action:nil,keyEquivalent:"")
        button.menu?.addItem(withTitle:title,action:nil,keyEquivalent:"")      // until the menu first opens
        button.menu?.delegate = context.coordinator
        context.coordinator.button = button
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.entries = entries; coordinator.selected = selected; coordinator.choose = choose
        if let cell = button.cell as? NSPopUpButtonCell, cell.menuItem?.title != title { cell.menuItem = NSMenuItem(title:title,action:nil,keyEquivalent:""); button.needsDisplay = true }
        button.setAccessibilityLabel(label); button.toolTip = title
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width:min(proposal.width ?? 170,170),height:nsView.cell?.cellSize.height ?? 22)
    }
}

/// The selected clip's speed, editable: "2.5", "2.5x" or "250%", applied with Return. Leaving the
/// field without Return puts back the speed the clip has.
struct SpeedField: View {
    @ObservedObject var store: EditorStore
    var width: CGFloat = 62
    var focusOnAppear = false
    var onCommit: () -> Void = {}
    @State private var text = ""
    @FocusState private var focused: Bool
    private var shown: String { String(format:"%.2fx",store.selectedSpeed) }
    var body: some View {
        TextField("",text:$text)
            .textFieldStyle(.roundedBorder).controlSize(.mini)
            .font(.system(size:10,design:.monospaced)).multilineTextAlignment(.trailing)
            .frame(width:width).focused($focused)
            .onSubmit { if store.setCustomSpeed(text) { onCommit() }; text = shown }
            .onAppear { text = shown; if focusOnAppear { focused = true } }
            .onChange(of:store.selectedSpeed) { if !focused { text = shown } }
            .onChange(of:store.selectedClipID) { text = shown }
            .onChange(of:focused) { _,now in if !now { text = shown } }
            .help("Type a speed from 0.1x to 10x and press Return")
            .accessibilityLabel("Custom speed")
    }
}

/// What a folded section's title line shows: the effect's amount and colour, Off, or whether the
/// section's settings are as they came in.
enum FoldingSummary { case amount(String, TitleColor), off, unchanged, changed }

/// An inspector section that folds away under its title, which then says what it holds: the
/// effect's amount and colour or Off, or whether its settings are changed.
struct FoldingSection<Content: View>: View {
    let title: String
    @Binding var isOpen: Bool
    let summary: FoldingSummary
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Button { withAnimation(.snappy(duration:0.22)) { isOpen.toggle() } } label: {
                // The title in line with the other sections'; the fold switch at the end of its line.
                HStack(spacing:6) {
                    panelTitle(title)
                    Spacer(minLength:6)
                    if !isOpen { folded.font(.system(size:10)).lineLimit(1).transition(.opacity) }
                    Image(systemName:"chevron.right").font(.system(size:8,weight:.bold)).foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width:18,height:18).background(Theme.raised,in:Circle())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? LocalizedStringKey("Hide these settings") : LocalizedStringKey("Show these settings"))
            .accessibilityLabel(Text(LocalizedStringKey(title)))
            .accessibilityValue(isOpen ? Text("Expanded") : Text("Collapsed"))
            if isOpen { VStack(alignment:.leading,spacing:10) { content() }.transition(.opacity) }
        }
        .font(.system(size:11))
    }
    @ViewBuilder private var folded: some View {
        switch summary {
        case let .amount(value,color):
            HStack(spacing:6) {
                Text(verbatim:value).font(.system(size:10,design:.monospaced)).foregroundStyle(Theme.muted)
                Circle().fill(Color(color)).frame(width:9,height:9).overlay(Circle().strokeBorder(.white.opacity(0.25),lineWidth:1))
            }
        case .off: Text("Off").foregroundStyle(Theme.muted)
        case .unchanged: Text("Default").foregroundStyle(Theme.muted)
        case .changed: Text("Edited").foregroundStyle(Theme.accent)
        }
    }
}
