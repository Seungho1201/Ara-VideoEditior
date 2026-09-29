import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import UniformTypeIdentifiers
import Combine
import FrameCore
import FrameMedia

@MainActor final class EditorStore: ObservableObject {
    @Published private(set) var project = Project()
    /// The start screen is up instead of the editor. A launch that names a project or media
    /// (Finder, `--project`, `--import`) goes straight to the editor.
    @Published private(set) var showLauncher = !CommandLine.arguments.contains("--project") && !CommandLine.arguments.contains("--import")
    let registry: ProjectRegistry
    /// A text field in the inspector has focus. Unmodified arrow-key menu equivalents beat any
    /// first responder, so the frame-step items must stand down or the caret cannot move.
    @Published var isEditingText = false
    /// The one clip the inspector, transform, split and speed work on. Nil while several are
    /// selected (selectedClipIDs), so single-clip actions stand down.
    @Published var selectedClipID: UUID? {
        didSet {
            if previewTransformID != selectedClipID { previewTransformID = nil }
            if selectedClipID != nil, selectedTransitionID != nil { selectedTransitionID = nil }
            // Choosing one clip (or none) ends a multiple selection; while one is being made,
            // selectedClipID is set to nil with the set already in place, and that keeps it.
            if let id = selectedClipID { if selectedClipIDs != [id] { selectedClipIDs = [id] } }
            else if selectedClipIDs.count == 1 { selectedClipIDs = [] }
        }
    }
    /// The timeline toolbar's rectangle select: the next drag across the tracks selects the clips
    /// it covers, without Shift, and then it switches itself off. Esc switches it off too.
    @Published var dragSelectArmed = false {
        didSet { if dragSelectArmed, !oldValue { status = String(localized:"Drag across the timeline to select clips · Esc to cancel") } }
    }
    /// Every selected clip: the one above, or several picked with Shift on the timeline. Each
    /// stands for its linked group.
    @Published private(set) var selectedClipIDs: Set<UUID> = []
    /// Selects these clips (and so their linked partners): one of them becomes the single
    /// selection, several a multiple selection with no inspector clip.
    func selectClips(_ ids: Set<UUID>) {
        let clips = Dictionary(project.clips.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
        let ids = ids.filter { clips[$0] != nil }
        if !ids.isEmpty { selectedGap = nil; selectedTransitionID = nil }
        // A video and its linked audio are one clip: both halves picked is still one selection,
        // shown by its picture half.
        let groups = Set(ids.compactMap { clips[$0].map { $0.linkID ?? $0.id } })
        if groups.count <= 1 {
            let single = ids.min { (clips[$0]!.kind == .audio ? 1 : 0) < (clips[$1]!.kind == .audio ? 1 : 0) }
            selectedClipIDs = single.map { [$0] } ?? []; selectedClipID = single; return
        }
        selectedClipIDs = ids; selectedClipID = nil; previewTransformID = nil
    }
    /// The clips a Delete, Copy or group move acts on, as long as they still exist.
    var selectionForEditing: Set<UUID> {
        guard !selectedClipIDs.isEmpty else { return [] }
        let existing = Set(project.clips.map(\.id))
        return selectedClipIDs.intersection(existing)
    }
    /// How many clips are selected, a video with its linked audio counting once.
    var selectedGroupCount: Int {
        let ids = selectionForEditing
        guard ids.count > 1 else { return ids.count }
        return Set(project.clips.filter { ids.contains($0.id) }.map { $0.linkID ?? $0.id }).count
    }
    /// More than one clip selected.
    var hasMultipleSelection: Bool { selectedGroupCount > 1 }
    /// After an undo or redo some selected clips may be gone: keep the rest, as a single or
    /// multiple selection, so what is drawn selected is what Delete and ⌘X act on.
    private func pruneSelection() {
        guard !selectedClipIDs.isEmpty else { return }
        let kept = selectionForEditing
        if kept != selectedClipIDs || (kept.count > 1) != (selectedClipID == nil) { selectClips(kept) }
    }
    @Published var previewTransformID: UUID? {
        didSet { if previewTransformID == nil || previewTransformID != anchorEditID { anchorEditID = nil } }
    }
    /// Placing the alignment point of this clip (the inspector's Adjust button): a click or drag
    /// in the preview puts it there.
    @Published var anchorEditID: UUID?
    /// Bumped when placing an alignment point starts: the preview takes the keyboard, so Return
    /// and Esc end the placing there, as after a click in it.
    @Published private(set) var previewFocusRequest = 0
    @Published var selectedGap: TimelineGap?
    /// A transition picked on the timeline; exclusive with a clip or gap selection.
    @Published var selectedTransitionID: UUID?
    enum SidePanel: String, CaseIterable { case inspector = "INSPECTOR", transitions = "TRANSITIONS" }
    @Published var sidePanel: SidePanel = .inspector
    /// Help mode: callouts over the editor (the timeline's ? button).
    @Published var showHelp = false
    @Published var selectedMediaID: UUID?
    /// The playhead has its own observable. It moves up to 60 times a second while scrubbing and
    /// 30 while playing; published through the store, every move re-evaluated the whole editor
    /// (a selected clip's inspector included) and redrew the entire timeline, and the main thread
    /// fell behind the preview. Only the timecode, the timeline's playhead strip and the transform
    /// chrome follow it now.
    let clock = PlayheadClock()
    var playhead: MediaTime {
        get { clock.time }
        set { if clock.time != newValue { clock.time = newValue } }
    }
    @Published private(set) var revealPlayheadRequest = 0
    @Published var zoom: Double = 64
    /// Kept across launches, like the other Settings switches.
    @Published var snapping = UserDefaults.standard.object(forKey:"timeline.snapping") as? Bool ?? true {
        didSet { UserDefaults.standard.set(snapping,forKey:"timeline.snapping") }
    }
    @Published var scrubHaptics = UserDefaults.standard.object(forKey:"timeline.scrubHaptics") as? Bool ?? true {
        didSet { UserDefaults.standard.set(scrubHaptics,forKey:"timeline.scrubHaptics") }
    }
    /// Kinds of haptic turned off in Settings (all on by default); `scrubHaptics` turns them all off.
    @Published var hapticsOff: Set<HapticKind> = Set((UserDefaults.standard.stringArray(forKey:"haptics.off") ?? []).compactMap(HapticKind.init)) {
        didSet { UserDefaults.standard.set(hapticsOff.map(\.rawValue).sorted(),forKey:"haptics.off") }
    }
    /// How often skimming pulses: every frame change up to the full rate, 90 % or 70 % of it.
    @Published var skimHapticStrength = ScrubFeedbackCadence.Strength(rawValue:UserDefaults.standard.string(forKey:"haptics.skimStrength") ?? "") ?? .standard {
        didSet { UserDefaults.standard.set(skimHapticStrength.rawValue,forKey:"haptics.skimStrength") }
    }
    /// Whether this kind of haptic plays.
    func haptics(_ kind: HapticKind) -> Bool { scrubHaptics && !hapticsOff.contains(kind) }
    @Published var isPlaying = false
    @Published var isBuilding = false
    @Published var isImporting = false
    @Published var isExporting = false
    @Published private(set) var isCapturingSnapshot = false
    @Published var exportProgress: Double = 0
    @Published var showExportSheet = false
    @Published var showNewProjectSheet = false
    /// Bumped when fonts are added, so font menus list them.
    @Published private(set) var fontsRevision = 0
    /// Bumped when an undo or redo puts the project back. The inspector's title field follows it
    /// even when SwiftUI never drew the text in between (typing committed and undone in one call).
    @Published private(set) var textRevision = 0
    @Published private(set) var isAddingFonts = false
    /// Where added fonts are kept (tests point it elsewhere).
    var fontFolder = FontLibrary.folder
    var exportHeight: Int { project.outputResolution }
    @Published var message: String?
    @Published var status = String(localized:"Import media to start editing") { didSet { statusWrites &+= 1 } }
    /// Counts what is written to the status, so a build does not replace a note written after it
    /// began (why the speed slider stopped, what was deleted) with its summary.
    private var statusWrites = 0
    @Published var thumbnails: [UUID:NSImage] = [:]
    @Published var waveforms: [UUID:[Float]] = [:]
    @Published var missing: Set<UUID> = []
    /// Missing sources that clips on the timeline use. Only these stop the preview, snapshots and
    /// export; an unused one is just marked Missing in the library.
    var missingInUse: Set<UUID> { missing.intersection(project.clips.compactMap(\.mediaID)) }
    @Published private(set) var documentURL: URL?
    /// A bookmark of the open document, so ⌘S follows it when it is renamed or moved in Finder.
    private(set) var documentBookmark: Data?
    private var saved: Project?
    private(set) var history = EditHistory()
    private var interactionStart: Project?
    /// A drag (in the preview, or on a slider) is open as one undo step. An undo or redo closes it,
    /// which ends a drag still going in the preview.
    var isInteracting: Bool { interactionStart != nil }
    /// What the open interaction's edits are called, so one drag is one undo step named after
    /// what it changed (a slider's speed or transition length). Nil: direct manipulation.
    private var interactionName: String?
    /// A speed slider drag has met the next clip and said so; once a drag is enough.
    private var speedHeld = false
    /// An open run of render-only style edits (typing a title, dragging the colour well) that
    /// will become ONE undo step when it ends: after a short idle, on focus loss, or before any
    /// other edit, so history order stays correct.
    private var liveEditStart: Project?
    private var liveEditName = "Adjust clip"
    private var liveEditEnd: Task<Void,Never>?
    /// Set by the inspector while a title draft is waiting on its short commit delay. Anything
    /// that reads or leaves the document (save, export, snapshot, switching project) runs it
    /// first, so the last keystrokes are never left out.
    var flushPendingEdits: (@MainActor () -> Void)?
    /// Changes every time the open document is replaced. Work captured against one document
    /// (a title draft, an async callback) checks it before writing, because clip ids survive
    /// Save As and reopening, so an id alone cannot tell two documents apart.
    private(set) var session = UUID()
    func commitPendingEdits() { flushPendingEdits?(); endLiveEdit() }
    private var urls: [UUID:URL] = [:]
    private var scopes: [URL:Bool] = [:]
    /// Titles being drawn off the main actor for the preview, by clip (see drawTitle).
    private var titleDraws: [UUID:UUID] = [:]
    /// A title's new picture is still being drawn for the preview.
    var isDrawingTitles: Bool { !titleDraws.isEmpty }
    private let library = MediaLibrary()
    private let builder = CompositionBuilder()
    private let exporter = MovieExporter()
    private let snapshotExporter = SnapshotExporter()
    private var rebuildTask: Task<Void,Never>?
    private var importTask: Task<Void,Never>?
    private var analysisTasks: [UUID:Task<Void,Never>] = [:]
    /// The source path each media item's thumbnail and waveform were read from (or are being
    /// read from). A relink, or an undo of one, points the item at another file: its old
    /// pictures are dropped and the new file is read.
    private var analyzed: [UUID:String] = [:]
    private var exportTask: Task<Void,Never>?
    private var snapshotTask: Task<Void,Never>?
    private var snapshotID: UUID?
    private var revision = 0
    private var seekRevision = 0
    private var seeking = false
    /// The one seek AVPlayer is working on, and where the playhead has moved since it was issued.
    private var seekInFlight: (target: MediaTime, item: AVPlayerItem, issued: CFTimeInterval)?
    private var chaseTarget: MediaTime?
    /// FHD preview stand-ins for sources larger than 1920 × 1080, by media id. Only the preview
    /// reads them; export and snapshots use the originals.
    @Published private(set) var proxies: [UUID:URL] = [:]
    /// The proxy being made, for the status bar.
    @Published private(set) var proxyProgress: (name: String, fraction: Double, remaining: Int)?
    private var proxyTask: Task<Void,Never>?
    /// Proxies that could not be made, by proxy location: a changed or replaced source gets a new
    /// location and is tried again, and relinking retries explicitly.
    private var proxyFailures: Set<URL> = []
    /// The encode in progress, so one whose source left the project (undo, relink) can be stopped.
    private var proxyJob: (id: UUID, key: URL, task: Task<URL?,Error>)?
    /// A rebuild interrupted playback and means to resume it. Survives a newer rebuild that
    /// supersedes the first, which would otherwise read "not playing" and leave playback stopped;
    /// a pause meanwhile clears it, and the build then leaves playback stopped.
    private var resumeAfterBuild = false
    private var rateObservation: NSKeyValueObservation?
    private var fontsObserver: NSObjectProtocol?
    private var proxySwapDeferred = false
    private var periodic: Any?
    private var mountObserver: NSObjectProtocol?
    private var itemObservation: NSKeyValueObservation?
    let player = AVPlayer()
    var dirty: Bool { project != saved }
    var selectedClip: Clip? { project.clips.first { $0.id == selectedClipID } }
    var selectedMedia: MediaReference? { project.media.first { $0.id == selectedMediaID } }
    var canUndo: Bool { history.canUndo || (liveEditStart.map { $0 != project } ?? false) }
    var undoName: String { liveEditStart != nil ? liveEditName : history.undoName }
    var canRedo: Bool { history.canRedo }
    var timecode: String { project.frameRate.timecode(playhead) }
    static let clipPasteboardType = NSPasteboard.PasteboardType("com.framestudio.timeline-clips")
    /// Where clips are copied to: the system clipboard (tests use a private one).
    var pasteboard = NSPasteboard.general
    var canCopyClip: Bool { selectedClip != nil || hasMultipleSelection }
    /// Delete has something to remove: a clip, several, or a transition (picked on the timeline or
    /// just added from the panel), so the menu item and the trash button work wherever focus is.
    var canDeleteSelection: Bool { selectedClip != nil || hasMultipleSelection || selectedTransition != nil }
    /// The menus' editing commands (Undo, Redo, Import, the Timeline menu) stand down: the start
    /// screen or a sheet (New Project, Export) hides the project, an export is reading it, or help
    /// mode dims it while its tips are read.
    var editingSuspended: Bool { showLauncher || showNewProjectSheet || showExportSheet || isExporting || showHelp }
    /// The shortcuts that status texts name (tests give their own).
    var shortcuts = ShortcutSettings.shared
    /// Only clips backed by a media stream can be retimed; text and stills have no source to speed up.
    var canRetimeSelection: Bool { selectedClip.map { $0.kind == .video || $0.kind == .audio } ?? false }
    var selectedSpeed: Double { selectedClip?.speed ?? 1 }
    var canPasteClip: Bool { pasteboard.availableType(from:[Self.clipPasteboardType]) != nil }
    /// Runs a question and returns the button chosen (tests answer it without a window).
    var runAlert: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    var canCaptureSnapshot: Bool { project.duration > .zero && missingInUse.isEmpty && !isBuilding && !isCapturingSnapshot && !isExporting }
    /// `registry` is the start screen's list (tests give it their own defaults).
    init(registry: ProjectRegistry = ProjectRegistry()) {
        self.registry = registry
        // Named in Ara's language, as the New Project sheet names one: media opened with Ara before
        // any New Project go into it. FrameCore's own default stays English.
        project.name = String(localized:"Untitled")
        saved = project
        player.actionAtItemEnd = .pause
        Task.detached(priority:.background) { ProxyMaker.prune() }
        // Before anything renders a title: added fonts are registered for this process only.
        FontLibrary.registerAddedFonts()
        // Fonts installed or removed while Ara runs (Font Book, or Ara adding its own): refresh the
        // font menus and redraw titles set in a font other than the default.
        let startRevision = fontsRevision, startFolder = fontFolder
        Task { await FontMenu.warm(startRevision,addedIn:startFolder) }
        fontsObserver = NotificationCenter.default.addObserver(forName:Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fontsRevision += 1
                self.redrawTitles { $0.style.fontName != ClipStyle.defaultFontName }
                let revision = self.fontsRevision, folder = self.fontFolder
                Task { await FontMenu.warm(revision,addedIn:folder) }
            }
        }
        // A drive plugged in again brings back the sources on it, with no edit or trip to another app.
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didMountNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSources() }
        }
        periodic = player.addPeriodicTimeObserver(forInterval:CMTime(value:1,timescale:30),queue:.main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                // Publish only real changes: this also fires on every completed seek, and each
                // publish re-renders the whole editor.
                if !self.seeking && !self.isBuilding && self.player.rate > 0 {
                    let now = min(self.project.duration,self.project.frameRate.quantize(MediaTime(time)))
                    if self.playhead != now { self.playhead = now }
                }
                let playing = self.player.rate > 0
                if self.isPlaying != playing { self.isPlaying = playing }
            }
        }
        // Reaching the end stops the player (actionAtItemEnd = .pause) with no pause() and no
        // further time-observer callback, so isPlaying would stay on. Treat it as a pause.
        rateObservation = player.observe(\.rate,options:[.new]) { [weak self] _,_ in
            Task { @MainActor in
                guard let self, self.isPlaying, self.player.rate == 0, !self.isBuilding else { return }
                if !self.seeking { self.playhead = self.project.frameRate.quantize(min(self.project.duration,MediaTime(self.player.currentTime()))) }
                self.pause()
            }
        }
    }
    func report(_ error: Error) { if !(error is CancellationError) { message = error.localizedDescription; status = String(localized:"Action could not be completed") } }
    @discardableResult func edit(_ name: String, _ operation: (inout Project) throws -> Void) -> Bool {
        // The export reads this project until it is done: no edit lands meanwhile, whatever asks.
        guard !isExporting else { return false }
        commitPendingEdits()
        do {
            var next = project; try operation(&next); next = try next.validated()   // also settles transitions
            guard next != project else { return true }
            if interactionStart == nil { history.record(project,name:name) } else if interactionName == nil { interactionName = name }
            // Any timeline change can move the edges a gap selection was measured from.
            project = next; selectedGap = nil; rebuild(); return true
        } catch { report(error); return false }
    }
    func beginInteraction() { commitPendingEdits(); if interactionStart == nil { interactionStart = project; interactionName = nil; speedHeld = false } }
    /// One drag, one undo step: named after its edits ("Change speed", "Transition length"), or
    /// "Adjust clip" for direct manipulation in the preview.
    func endInteraction() {
        if let before = interactionStart, before != project { history.record(before,name:interactionName ?? "Adjust clip") }
        interactionStart = nil; interactionName = nil; objectWillChange.send()
        applyDeferredProxySwap()
    }
    func updateStyle(_ update: (inout ClipStyle) -> Void) {
        // A title typed a moment ago lands first, so the style below starts from it (Reset
        // appearance keeps the text just typed).
        commitPendingEdits()
        guard let clip = selectedClip else { return }
        var style = clip.style; update(&style)
        edit("Adjust clip") { project in
            if let index = project.clips.firstIndex(where: { $0.id == clip.id }) { project.clips[index].style = style }
            // Volume/mute on a selected video is applied to its linked source audio.
            if clip.kind == .video, let link = clip.linkID,
               let index = project.clips.firstIndex(where: { $0.linkID == link && $0.kind == .audio }) {
                project.clips[index].style.volume = style.volume; project.clips[index].style.muted = style.muted
            }
            if clip.kind == .audio, let link = clip.linkID,
               let index = project.clips.firstIndex(where: { $0.linkID == link && $0.kind == .video }) {
                project.clips[index].style.volume = style.volume; project.clips[index].style.muted = style.muted
            }
        }
    }
    /// Text, font and text colour only change how one layer is drawn. Apply them by swapping the
    /// paused video composition's instruction (as direct manipulation does) instead of rebuilding
    /// the AVComposition and replacing the player item: doing that on every keystroke stalled the
    /// main thread and, by re-rendering the text view mid-composition, dropped Hangul input.
    /// Audio (volume, mute) and timing are never routed here; they change the composition itself.
    func updateStyleLive(_ id: UUID, name: String, closesWhenIdle: Bool = true, _ update: (inout ClipStyle) -> Void) {
        guard !isExporting, let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var clip = project.clips[index]
        update(&clip.style)
        guard clip != project.clips[index] else { return }
        var candidate = project; candidate.clips[index] = clip
        guard (try? candidate.validated()) != nil else { return }
        // A different edit landing mid-run (the title's text committing during a slider drag) is
        // its own undo step.
        if liveEditStart != nil, liveEditName != name { endLiveEdit() }
        if liveEditStart == nil { liveEditStart = project; liveEditName = name }
        project = candidate; selectedGap = nil
        if !refreshPreviewLayer(clip) { rebuild() }
        liveEditEnd?.cancel(); liveEditEnd = nil
        guard closesWhenIdle else { return }
        liveEditEnd = Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.endLiveEdit()
        }
    }
    /// Closes the open run of live edits as a single undo step.
    func endLiveEdit() {
        liveEditEnd?.cancel(); liveEditEnd = nil
        guard let before = liveEditStart else { return }
        liveEditStart = nil
        if before != project { history.record(before,name:liveEditName); objectWillChange.send() }
    }
    /// Re-renders one layer of the current preview in place, a title with `image` or with its
    /// picture as `titleImage` finds it. False when there is no settled player item to patch
    /// (nothing loaded yet, or a rebuild is in flight whose snapshot is already stale) — the
    /// caller then rebuilds from the current project instead.
    @discardableResult private func refreshPreviewLayer(_ clip: Clip, image drawn: CIImage? = nil) -> Bool {
        guard !isBuilding, let item = player.currentItem,
              let composition = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition,
              let instruction = composition.instructions.first as? FrameInstruction,
              instruction.layers.contains(where: { $0.clip.id == clip.id }) else { return false }
        let image = drawn ?? (clip.kind == .text ? titleImage(clip) : nil)
        composition.instructions = [instruction.replacingLayer(for:clip,image:image)]
        // A fresh composition re-renders a paused frame without replacing the player item (QA1966).
        item.videoComposition = composition
        return true
    }
    /// A title's picture for the preview when it has been drawn. Otherwise nil: it is drawn off the
    /// main actor (a big title with an outline or shadow takes tens of milliseconds, too long to hold
    /// up a slider or the pointer) and put in when ready; the preview keeps its last picture meanwhile.
    private func titleImage(_ clip: Clip) -> CIImage? {
        if let drawn = FrameRenderer.drawnTextImage(clip.style) { return drawn }
        drawTitle(clip.id); return nil
    }
    /// Draws a title's picture off the main actor, one at a time for each title: the steps that
    /// come meanwhile are drawn after it, from the newest, and those in between are skipped.
    private func drawTitle(_ id: UUID) {
        guard titleDraws[id] == nil, let style = project.clips.first(where: { $0.id == id })?.style else { return }
        let token = UUID(); titleDraws[id] = token
        Task { [weak self] in
            let image = await Task.detached(priority:.userInitiated) { try? FrameRenderer.textImage(style) }.value
            // A build since, or another document, has its own pictures.
            guard let self, titleDraws[id] == token else { return }
            titleDraws[id] = nil
            guard let clip = project.clips.first(where: { $0.id == id }), clip.kind == .text else { return }
            if let newest = FrameRenderer.drawnTextImage(clip.style) { refreshPreviewLayer(clip,image:newest); return }
            // A newer step came meanwhile: this picture is nearer to it than the one shown.
            if let image { refreshPreviewLayer(clip,image:image) }
            if image != nil || clip.style != style { drawTitle(id) }
        }
    }
    /// Starts (or ends) placing a clip's alignment point in the preview. The playhead goes into
    /// the clip first if it is elsewhere, so the clip is there to click on.
    func editAnchor(_ clip: Clip) {
        if anchorEditID == clip.id { anchorEditID = nil; return }
        pause(); commitPendingEdits()
        if playhead < clip.start || playhead >= clip.end { seek(clip.start) }
        selectedClipID = clip.id; selectedGap = nil; previewTransformID = clip.id; anchorEditID = clip.id; previewFocusRequest += 1
        status = String(localized:"Click or drag in the preview to place the alignment point · Return to finish")
    }
    /// The alignment point back in the middle of the clip.
    func resetAnchor(_ clip: Clip) {
        updateStyleLive(clip.id,name:"Alignment point",closesWhenIdle:false) { $0.anchorX = 0; $0.anchorY = 0 }
        endLiveEdit()
    }
    /// Direct manipulation changes only placement (position, scale, rotation); it does not
    /// rebuild tracks or audio.
    func updatePreviewTransform(_ id: UUID, style: ClipStyle) {
        guard previewTransformID == id, !isBuilding, !isExporting,
              let index = project.clips.firstIndex(where: { $0.id == id }),
              let item = player.currentItem,
              let composition = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition,
              let instruction = composition.instructions.first as? FrameInstruction,
              instruction.layers.contains(where: { $0.clip.id == id }) else { return }
        var clip = project.clips[index]
        clip.style.x = style.x; clip.style.y = style.y; clip.style.scale = style.scale; clip.style.rotation = style.rotation
        clip.style.anchorX = style.anchorX; clip.style.anchorY = style.anchorY
        guard clip != project.clips[index] else { return }
        var candidate = project; candidate.clips[index] = clip
        guard (try? candidate.validated()) != nil else { return }
        let turned = clip.style.rotation != project.clips[index].style.rotation
        project = candidate
        // A title's shadow keeps its screen direction, so turning a shadowed title redraws it.
        if turned, clip.kind == .text, clip.style.hasShadow {
            composition.instructions = [instruction.replacingLayer(for:clip,image:titleImage(clip))]
        } else {
            composition.instructions = [instruction.replacingTransform(of:clip)]
        }
        // A fresh composition re-renders a paused frame without replacing the player item (QA1966).
        item.videoComposition = composition
    }
    /// How far a title's image reaches past its letters' box on every side (see previewSourceSize),
    /// measured from the style it was drawn with.
    func previewSourceMargin(for clip: Clip) -> CGFloat {
        guard let layer = (player.currentItem?.videoComposition?.instructions.first as? FrameInstruction)?.layers.first(where: { $0.clip.id == clip.id }),
              layer.clip.kind == .text, layer.image != nil else { return 0 }
        return FrameRenderer.effectMargin(layer.clip.style)
    }
    /// The rendered image a text or still layer shows in the current preview.
    func previewLayerImage(for clip: Clip) -> CIImage? {
        (player.currentItem?.videoComposition?.instructions.first as? FrameInstruction)?
            .layers.first(where: { $0.clip.id == clip.id })?.image
    }
    /// What the preview decodes for this clip: its FHD proxy when there is one.
    func previewSourceURL(for clip: Clip) -> URL? { clip.mediaID.flatMap { proxies[$0] ?? urls[$0] } }
    /// For a title, the size of its letters' box: the image less the room kept for its outline
    /// and shadow (`previewSourceMargin`), so the transform box fits the letters.
    func previewSourceSize(for clip: Clip) -> CGSize? {
        if let instruction = player.currentItem?.videoComposition?.instructions.first as? FrameInstruction,
           let layer = instruction.layers.first(where: { $0.clip.id == clip.id }), let image = layer.image {
            let margin = layer.clip.kind == .text ? FrameRenderer.effectMargin(layer.clip.style) : 0
            return CGSize(width:max(1,image.extent.width-2*margin),height:max(1,image.extent.height-2*margin))
        }
        guard let media = project.media(for:clip), media.width > 0, media.height > 0 else { return nil }
        return CGSize(width:media.width,height:media.height)
    }
    func undo() { guard !isExporting else { return }; commitPendingEdits(); endInteraction(); selectedGap = nil; if let previous = history.undo(project) { restore(previous) } }
    func redo() { guard !isExporting else { return }; commitPendingEdits(); endInteraction(); selectedGap = nil; if let next = history.redo(project) { restore(next) } }
    /// An undo or redo step. The project keeps its name: the name follows the document's file,
    /// which Save and Save As rename without an undo step of their own.
    private func restore(_ snapshot: Project) {
        var snapshot = snapshot; snapshot.name = project.name
        project = snapshot; textRevision += 1; pruneSelection(); restoreAccess(); rebuild()
    }
    func split() { guard let id = selectedClipID else { return }; edit("Split clip") { try Editing.split(id,at:playhead,in:&$0) } }
    /// Retiming changes the clip's timeline length, so it is one undoable step per commit,
    /// not per slider sample: the caller brackets a drag with begin/endInteraction. A slower
    /// speed with no room for the longer clip is refused, saying why. False when not applied.
    @discardableResult func setSpeed(_ speed: Double) -> Bool {
        guard let id = selectedClipID, !isExporting else { return false }
        if speedAgainstNextClip(id,for:speed) != nil { message = noRoom(for:speed); return false }
        return edit("Change speed") { try Editing.setSpeed(id,to:speed,in:&$0) }
    }
    /// Slowing a clip lengthens it. When the clips after it (on its track, or its linked audio's)
    /// leave no room for `speed`, the speed at which it meets them instead: the longest clip
    /// there is room for, at the fastest speed giving that length, so it keeps its source (with
    /// no room at all, its own speed). Nil when `speed` fits, or something other than room stops it.
    private func speedAgainstNextClip(_ id: UUID, for speed: Double, basedOn base: Project? = nil) -> Double? {
        func length(_ speed: Double) -> MediaTime? {
            var probe = project
            guard (try? Editing.setSpeed(id,to:speed,in:&probe,basedOn:base)) != nil else { return nil }
            return probe.clips.first { $0.id == id }?.duration
        }
        guard let current = (base ?? project).clips.first(where: { $0.id == id })?.speed, speed < current,
              length(speed) == nil, let now = length(current) else { return nil }
        /// Where `holds` changes between `low` and `high`, to the three decimals speeds are kept
        /// to: the end on the side where it holds.
        func edge(_ low: Double, _ high: Double, holdsAtHigh: Bool, _ holds: (Double) -> Bool) -> Double {
            var low = low, high = high
            while true {
                let middle = ((low+high)/2*1000).rounded()/1000
                guard middle > low, middle < high else { return holdsAtHigh ? high : low }
                if holds(middle) == holdsAtHigh { high = middle } else { low = middle }
            }
        }
        let slowest = edge(speed,current,holdsAtHigh:true) { length($0) != nil }, longest = length(slowest)
        return now == longest ? current : edge(slowest,current,holdsAtHigh:false) { length($0) == longest }
    }
    private func noRoom(for speed: Double) -> String {
        String(localized:"There isn't room after this clip for \(String(format:"%gx",speed)) speed. Move the next clip or use another track.")
    }
    /// The toolbar and inspector presets.
    static let speedPresets: [Double] = [0.25,0.5,0.75,1,1.5,2,3,4,5]
    /// A typed speed: "2.5", "2.5x", "2,5" or "250%". Nil when it is not a number in range.
    static func parseSpeed(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in:.whitespaces).lowercased().replacingOccurrences(of:",",with:".")
        var scale = 1.0
        if t.hasSuffix("%") { t.removeLast(); scale = 0.01 }
        else if t.hasSuffix("x") || t.hasSuffix("×") { t.removeLast() }
        guard let value = Double(t.trimmingCharacters(in:.whitespaces)), value.isFinite else { return nil }
        // Two decimals, as the speed is shown.
        let speed = (value*scale*100).rounded()/100
        return Clip.speedRange.contains(speed) ? speed : nil
    }
    /// Applies a typed speed to the selected clip. False (with a note) when it is not usable or
    /// was refused, so the Custom… popover stays open for another value.
    @discardableResult func setCustomSpeed(_ text: String) -> Bool {
        guard let speed = Self.parseSpeed(text) else {
            status = String(localized:"Enter a speed from 0.1x to 10x"); NSSound.beep(); return false
        }
        return abs(speed-selectedSpeed) <= 0.0001 || setSpeed(speed)
    }
    /// Slider path: every sample resolves against the snapshot the drag started from, so
    /// dragging back to where you began restores the clip exactly instead of ratcheting down.
    /// Slowed into the next clip, the clip stops against it and the status says why, once a drag.
    func setSpeedInteractively(_ speed: Double) {
        guard let id = selectedClipID else { return }
        let base = interactionStart, asked = speed
        var speed = speed, note = false
        if let fit = speedAgainstNextClip(id,for:speed,basedOn:base) {
            note = !speedHeld; speedHeld = base != nil; speed = fit
        }
        edit("Change speed") { try Editing.setSpeed(id,to:speed,in:&$0,basedOn:base) }
        // After the edit, so the build it starts keeps the note.
        if note { status = noRoom(for:asked) }
    }
    func deleteSelection() {
        if selectedTransitionID != nil { removeSelectedTransition(); return }
        if hasMultipleSelection {
            let ids = selectionForEditing, count = selectedGroupCount
            if edit("Delete clips",{ Editing.delete(ids,from:&$0) }) { selectClips([]); status = String(localized:"Deleted \(count) clips")+undoHint }
            return
        }
        guard let id = selectedClipID else { return }; if edit("Delete clip",{ Editing.delete(id,from:&$0) }) { selectedClipID = nil }
    }
    /// Moves the selected clips together by `delta`, as one undo step.
    func moveClips(_ ids: Set<UUID>, by delta: MediaTime) {
        guard !isExporting else { return }
        edit("Move clips") { try Editing.move(ids,by:delta,in:&$0) }
    }
    /// Every clip on the timeline.
    func selectAllClips() { selectClips(Set(project.clips.map(\.id))) }
    /// Copy, then delete what was copied, as one undo step.
    func cutSelection() {
        let ids = selectionForEditing, count = selectedGroupCount
        guard !ids.isEmpty, !isExporting else { return }
        guard copySelection() else { return }                          // nothing is deleted unless it was copied
        if edit(count > 1 ? "Cut clips" : "Cut clip",{ Editing.delete(ids,from:&$0) }) {
            selectClips([]); status = count > 1 ? String(localized:"Cut \(count) clips · ⌘V at playhead") : String(localized:"Cut clip · ⌘V at playhead")
        }
    }
    var selectedTransition: FrameCore.Transition? { selectedTransitionID.flatMap { id in project.transitions.first { $0.id == id } } }
    func selectTransition(_ id: UUID?) {
        selectedTransitionID = id
        if id != nil { selectClips([]); selectedGap = nil; sidePanel = .inspector }
    }
    /// Adds (or replaces) a transition on a clip edge and selects it. A new one takes its kind's
    /// usual length; swapping the kind keeps the length and direction already there.
    @discardableResult func applyTransition(_ kind: TransitionKind, from: UUID?, to: UUID?) -> Bool {
        guard !isExporting else { return false }
        endInteraction()
        var id: UUID?
        if edit(from != nil && to != nil ? "Add transition" : to != nil ? "Add fade in" : "Add fade out", {
            let existing = project.transitions.first { $0.from == from && $0.to == to }
            id = try Editing.setTransition(kind,direction:existing?.direction ?? .left,duration:existing?.duration,from:from,to:to,in:&$0)
        }), let id {
            selectClips([]); selectedTransitionID = id; selectedGap = nil
            // The key Delete is set to now, if any.
            let key = shortcuts.label(.delete)
            status = key.isEmpty ? String(localized:"\(kind.displayName) added") : String(localized:"\(kind.displayName) added · \(key) to remove")
            return true
        }
        return false
    }
    /// The selected clip's start or end: across the cut when a clip meets it there, else a fade.
    func transitionEdge(ofSelectedClipAtEnd end: Bool) -> (from: UUID?, to: UUID?)? {
        guard let clip = selectedClip, clip.lane.isVideo else { return nil }
        guard let edge = Editing.edge(on:clip.lane,at:end ? clip.end : clip.start,in:project) else { return nil }
        return end ? (from:clip.id,to:edge.to) : (from:edge.from,to:clip.id)
    }
    func updateSelectedTransition(kind: TransitionKind? = nil, direction: TransitionDirection? = nil, duration: MediaTime? = nil) {
        guard let id = selectedTransitionID else { return }
        let name = duration != nil ? "Transition length" : direction != nil ? "Transition direction" : "Transition kind"
        edit(name) { try Editing.updateTransition(id,kind:kind,direction:direction,duration:duration,in:&$0) }
    }
    /// Timeline edge drags preview locally, then commit their final length as one undo step.
    func setTransitionDuration(_ id: UUID, to duration: MediaTime) {
        guard !isExporting, project.transitions.contains(where: { $0.id == id }) else { return }
        if edit("Transition length",{ try Editing.updateTransition(id,duration:duration,in:&$0) }),
           let transition = project.transitions.first(where: { $0.id == id }) {
            status = "\(transition.kind.displayName) · \(String(format:String(localized:"%.2f s"),transition.duration.seconds))"
        }
    }
    func removeSelectedTransition() {
        guard let id = selectedTransitionID else { return }
        if edit("Remove transition",{ Editing.removeTransition(id,from:&$0) }) { selectedTransitionID = nil }
    }
    @discardableResult func copySelection() -> Bool {
        let ids = selectionForEditing
        guard !ids.isEmpty else { return false }
        do {
            let payload = ids.count == 1 ? try ClipClipboard(copying:ids.first!,from:project) : try ClipClipboard(copying:Array(ids),from:project)
            let item = NSPasteboardItem()
            guard item.setData(try payload.encoded(),forType:Self.clipPasteboardType) else { throw EditError("Cannot copy this clip.") }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else { throw EditError("Cannot write to the clipboard.") }
            status = payload.version == 2 ? String(localized:"Copied \(selectedGroupCount) clips · ⌘V at playhead")
                   : payload.clips.count == 2 ? String(localized:"Copied clip and linked audio · ⌘V at playhead") : String(localized:"Copied clip · ⌘V at playhead")
            return true
        } catch { report(error); return false }
    }
    func pasteClips() {
        guard let data = pasteboard.data(forType:Self.clipPasteboardType) else { return }
        do {
            let payload = try ClipClipboard.decode(data)
            endInteraction(); pause()
            let oldMedia = project.media
            var inserted: (anchor: UUID, clips: [UUID], raised: Int)?
            let several = payload.version == 2
            if edit(several ? "Paste clips" : "Paste clip",{ inserted = try Editing.pasteAll(payload,at:playhead,into:&$0) }), let inserted {
                // Several pasted clips stay selected together, ready to move or copy again.
                if several { selectClips(Set(inserted.clips)) } else { selectedClipID = inserted.anchor }
                selectedGap = nil
                if project.media != oldMedia { restoreAccess(); rebuild() }
                revealPlayheadRequest += 1
                let lane = project.clip(inserted.anchor)?.lane.rawValue ?? ""
                status = (inserted.raised > 0 ? String(localized:"Pasted on \(lane) at \(timecode): the track below was in use here")
                                              : String(localized:"Pasted clip at \(timecode)"))+undoHint
            }
        } catch { report(error) }
    }
    func selectGap(_ gap: TimelineGap?) { if gap != nil { selectClips([]); selectedTransitionID = nil }; selectedGap = gap }
    func closeSelectedGap() {
        guard let gap = selectedGap else { return }
        // edit() clears selectedGap on success; restore it on failure so the outline stays put.
        if !edit("Close gap",{ try Editing.closeGap(gap,in:&$0) }) { selectedGap = gap }
    }
    @discardableResult func addMedia(_ id: UUID, lane: Lane? = nil, at time: MediaTime? = nil) -> Bool {
        guard !isExporting, let media = project.media.first(where: { $0.id == id }) else { return false }
        guard !missing.contains(id) else { message = String(localized:"Relink this source in the library before adding it."); return false }
        let target = lane ?? (media.kind == .audio ? .a1 : .v1)
        // A video with sound lands on both lanes of the pair, so it goes after the end of both.
        // An audio file or a still fills only its own lane.
        let paired = media.kind == .video && media.hasAudio
        let end = project.clips.filter { $0.lane == target || (paired && $0.lane == target.paired) }.map(\.end).max() ?? .zero
        var result: UUID?
        guard edit("Add clip", { result = try Editing.add(mediaID:id,lane:target,at:time ?? end,to:&$0) }) else { return false }
        selectedClipID = result; status = String(localized:"Added \(media.name) to \(target.rawValue)")
        return true
    }
    /// A new empty track above the top video track, or below the bottom audio track.
    func addTrack(_ kind: Lane.Kind) {
        var added: Lane?
        if edit(kind == .video ? "Add video track" : "Add audio track", { added = try Editing.addTrack(kind,to:&$0) }), let added {
            status = String(localized:"Added \(added.rawValue)")+undoHint
        }
    }
    /// Removes an empty added track; the tracks above move down one number. The undo step is named
    /// by kind, like adding one: undo names are looked up whole in the string table.
    func removeTrack(_ lane: Lane) {
        if edit(lane.isVideo ? "Remove video track" : "Remove audio track", { try Editing.removeTrack(lane,from:&$0) }) {
            status = String(localized:"Removed \(lane.rawValue)")+undoHint
        }
    }
    func addText() {
        var id: UUID?
        if edit("Add text", { project in
            let added = try Editing.addText(at:playhead,to:&project)
            // A new title reads in Ara's language; FrameCore's default words are English.
            if let index = project.clips.firstIndex(where: { $0.id == added }) {
                project.clips[index].name = String(localized:"Title"); project.clips[index].style.text = String(localized:"Your story starts here")
            }
            id = added
        }) { selectedClipID = id }
    }
    func move(_ id: UUID, to time: MediaTime, lane: Lane) { edit("Move clip") { try Editing.move(id,to:time,lane:lane,in:&$0) } }
    func trim(_ id: UUID, leading: Bool, to time: MediaTime) { edit("Trim clip") { try Editing.trim(id,leading:leading,to:time,in:&$0) } }
    func setVideoSettings(aspectRatio: VideoAspectRatio, frameRate: FrameRate, resolution: Int? = nil) throws {
        commitPendingEdits(); endInteraction()
        var next = project
        try Editing.setVideoSettings(aspectRatio:aspectRatio,frameRate:frameRate,resolution:resolution,in:&next)
        guard next != project else { return }
        pause(); previewTransformID = nil
        edit("Timeline settings") { $0 = next }
    }
    /// Frame-exact seeks, chased rather than stacked (Apple QA1820). At most one is in flight;
    /// when it lands, the next goes to wherever the playhead has moved since. Cancelling and
    /// reissuing on every mouse event threw away each half-decoded frame, so a fast scrub showed
    /// almost nothing. The player item waits for the composed frame before a seek completes, so
    /// "landed" means on screen. The playhead follows the mouse immediately either way.
    func seek(_ time: MediaTime) {
        let target = project.frameRate.quantize(min(max(.zero,time),project.duration))
        if playhead != target { playhead = target }      // a drag sends many events per frame
        guard let item = player.currentItem else { chaseTarget = nil; seekInFlight = nil; seeking = false; return }
        seeking = true
        if let flight = seekInFlight, flight.item === item, CACurrentMediaTime() - flight.issued < 1 {
            chaseTarget = flight.target == target ? nil : target
            return
        }
        // Nothing in flight, a different item (a rebuild replaced it), or a seek that never
        // reported back: go straight there.
        chaseTarget = target; issueSeek()
    }
    private func issueSeek() {
        guard let target = chaseTarget, let item = player.currentItem else { seekInFlight = nil; seeking = false; return }
        chaseTarget = nil; seekRevision += 1; let token = seekRevision
        seekInFlight = (target,item,CACurrentMediaTime())
        player.seek(to:target.cmTime,toleranceBefore:.zero,toleranceAfter:.zero) { [weak self] _ in
            Task { @MainActor in self?.seekLanded(token) }
        }
        // A seek waits for its frame to be drawn. Should that never happen (nothing on screen to
        // draw into), the chase must not stall with `seeking` stuck on, which would freeze the
        // playhead during playback.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for:.seconds(2))
            self?.seekLanded(token)
        }
    }
    private func seekLanded(_ token: Int) {
        guard seekRevision == token, seekInFlight != nil else { return }
        seekInFlight = nil
        if chaseTarget != nil { issueSeek() } else { seeking = false }
    }
    /// Sends the chased position now, superseding the seek in flight, so playback starts
    /// exactly where the playhead is instead of being corrected after it has begun.
    private func settleSeek() {
        guard chaseTarget != nil else { return }
        player.currentItem?.cancelPendingSeeks(); issueSeek()
    }
    func step(_ count: Int) { pause(); seek(playhead + MediaTime(ticks:project.frameRate.frame.ticks * Int64(count))) }
    func goToSelectedClipStart() {
        guard let clip = selectedClip else { return }
        pause(); seek(clip.start); revealPlayheadRequest += 1
    }
    func goToSelectedClipEnd() {
        guard let clip = selectedClip else { return }
        pause(); seek(clip.lastFrameTime(at:project.frameRate)); revealPlayheadRequest += 1
    }
    func pause() { player.pause(); resumeAfterBuild = false; if isPlaying { isPlaying = false }; applyDeferredProxySwap() }
    func togglePlayback() {
        guard !isExporting else { return }
        // Mid-rebuild the key pauses what the build would resume, as it would the playback itself.
        guard !isBuilding else { if resumeAfterBuild { pause() }; return }
        guard player.currentItem != nil else { return }
        if isPlaying { pause() }
        else {
            previewTransformID = nil; if playhead >= project.duration { seek(.zero) }; settleSeek(); player.play(); isPlaying = true
            revealPlayheadRequest += 1                  // playing from a playhead scrolled out of view: show it
        }
    }
    private func rebuild() {
        // A used source moved or deleted in Finder since it was read is looked for again first, and
        // a missing one put back (a drive plugged in again) is found.
        recheckSources(Set(project.clips.compactMap(\.mediaID)))
        proxySwapDeferred = false               // this build picks up the current proxies
        titleDraws.removeAll()                  // and draws every title as it is now
        revision += 1; let token = revision, writes = statusWrites
        rebuildTask?.cancel(); let resume = isPlaying || resumeAfterBuild; pause()
        resumeAfterBuild = resume                // after pause(), which clears it
        playhead = project.frameRate.quantize(min(playhead,project.duration))
        guard !project.clips.isEmpty else { player.replaceCurrentItem(with:nil); isBuilding = false; resumeAfterBuild = false; return }
        guard missingInUse.isEmpty else {
            player.replaceCurrentItem(with:nil); isBuilding = false; resumeAfterBuild = false
            status = String(localized:"Missing sources: \(missingInUse.count) · Use Relink in the library"); return
        }
        let snapshot = project, mediaURLs = urls, pictures = proxies
        isBuilding = true
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for:.milliseconds(140))
                let bundle = try await builder.build(snapshot,urls:mediaURLs,videoURLs:pictures)
                try Task.checkCancellation()
                guard revision == token else { return }
                let item = bundle.playerItem()
                itemObservation = item.observe(\.status,options:[.new]) { [weak self] item,_ in
                    if item.status == .failed {
                        let text = item.error?.localizedDescription ?? String(localized:"Preview failed.")
                        Task { @MainActor in self?.message = text }
                    }
                }
                player.replaceCurrentItem(with:item); isBuilding = false; seek(playhead)
                // Only if still wanted: a pause during the build (Space, a scrub) cleared it.
                if resumeAfterBuild { resumeAfterBuild = false; player.play(); isPlaying = true }
                // A note written since the build began (by the edit that asked for it) stays.
                if statusWrites == writes { status = String(localized:"Clips: \(project.clips.filter { $0.kind != .audio || $0.linkID == nil }.count) · SDR Rec.709") }
            } catch {
                guard revision == token else { return }; isBuilding = false; resumeAfterBuild = false
                guard !(error is CancellationError) else { return }
                // A source that went away while this build ran is followed or marked missing, not reported.
                if recheckSources(Set(project.clips.compactMap(\.mediaID))) { rebuild(); return }
                player.replaceCurrentItem(with:nil); report(error)
            }
        }
    }
    func chooseImport() {
        let panel = NSOpenPanel(); panel.title = String(localized:"Import media"); panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie,.audio,.png,.jpeg,.tiff]
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }
    /// `applyToSelection` for a title's own Add Font… button; File > Add Fonts… only adds.
    func chooseFonts(applyToSelection: Bool = false) {
        let panel = NSOpenPanel(); panel.title = String(localized:"Add fonts"); panel.prompt = String(localized:"Add"); panel.allowsMultipleSelection = true
        panel.message = String(localized:"Choose font files (TTF, OTF, TTC) or the ZIP archive they came in.")
        panel.allowedContentTypes = [.zip] + FontLibrary.fileExtensions.sorted().compactMap { UTType(filenameExtension:$0) }
        if panel.runModal() == .OK { addFonts(panel.urls,applyToSelection:applyToSelection) }
    }
    /// Copies fonts into Ara's font folder and makes them available to titles. Titles that were
    /// waiting for one of these fonts (drawn in the default font) are redrawn in it. With a title
    /// selected from its inspector's Add Font…, a new family is put on it straight away: the face
    /// closest to the title's weight and slant.
    func addFonts(_ urls: [URL], applyToSelection: Bool) {
        guard !urls.isEmpty else { return }
        guard !isAddingFonts else { message = String(localized:"Fonts are still being added. Add these again when that finishes."); return }
        isAddingFonts = true; status = String(localized:"Adding fonts…")
        let target = applyToSelection ? selectedClip.flatMap { $0.kind == .text ? $0.id : nil } : nil
        let folder = fontFolder, session = session
        Task { [weak self] in
            let result = await Task.detached(priority:.userInitiated) { Result { try FontLibrary.importFonts(urls,into:folder) } }.value
            guard let self else { return }
            isAddingFonts = false
            switch result {
            case .failure(let error): report(error)
            case .success(let imported):
                fontsRevision += 1
                let names = Set(imported.added.map(\.postScriptName)), count = imported.added.count
                let families = Array(NSOrderedSet(array:imported.added.map(\.familyDisplayName))) as? [String] ?? []
                status = count == 1 ? String(localized:"Added 1 font · \(families.joined(separator:", "))") : String(localized:"Added \(count) fonts · \(families.joined(separator:", "))")
                redrawTitles { names.contains($0.style.fontName) }
                var applied = false
                // Only in the document the font was asked for, and not when the title was already
                // waiting for one of these fonts (it now shows it).
                if session == self.session, let target, let clip = project.clips.first(where: { $0.id == target }),
                   !names.contains(clip.style.fontName), let family = imported.added.first?.family {
                    let current = FontLibrary.face(clip.style.fontName)
                    if let face = FontLibrary.closestFace(inFamily:family,toWeight:current?.weight ?? 0.4,italic:current?.isItalic ?? false) {
                        applyFont(face.postScriptName,to:target); applied = true
                    }
                } else if session == self.session, let target, let clip = project.clips.first(where: { $0.id == target }), names.contains(clip.style.fontName) {
                    applied = true
                }
                var notes: [String] = []
                if !applied {
                    notes.append(count == 1 ? String(localized:"Added \(families.joined(separator:", ")) (1 style). Choose it from a title's Font menu.")
                                            : String(localized:"Added \(families.joined(separator:", ")) (\(count) styles). Choose it from a title's Font menu."))
                }
                if !imported.skipped.isEmpty { notes.append(String(localized:"Some files were not added:")+"\n" + imported.skipped.joined(separator:"\n")) }
                if !notes.isEmpty { message = notes.joined(separator:"\n\n") }
            }
        }
    }
    /// Puts a font on a title: one undo step, redrawn in place like typing.
    func applyFont(_ postScriptName: String, to id: UUID? = nil) {
        guard let id = id ?? selectedClipID, project.clips.first(where: { $0.id == id })?.kind == .text else { return }
        commitPendingEdits(); endLiveEdit()
        updateStyleLive(id,name:"Font",closesWhenIdle:false) { $0.fontName = postScriptName }
        endLiveEdit()
    }
    /// Titles are drawn into images when the preview is built. When the fonts on this Mac change
    /// (added in Ara or installed in Font Book), titles whose font may now resolve differently are
    /// drawn again, in place when possible.
    private func redrawTitles(where needsIt: (Clip) -> Bool) {
        for clip in project.clips where clip.kind == .text && needsIt(clip) {
            if !refreshPreviewLayer(clip) { rebuild(); return }
        }
    }
    /// Fonts named by titles that this Mac does not have; those titles are drawn in the default font.
    var missingFonts: [String] {
        Array(Set(project.clips.filter { $0.kind == .text }.map(\.style.fontName))).filter { !FontLibrary.isAvailable($0) }.sorted()
    }
    private func hold(_ url: URL) {
        if scopes[url] == nil { scopes[url] = url.startAccessingSecurityScopedResource() }
    }
    /// A project document: `.framestudio` in any case, as Launch Services matches it.
    static func isProjectFile(_ url: URL) -> Bool { url.pathExtension.lowercased() == "framestudio" }
    /// Files opened with Ara (Finder, the Dock) or dropped on the library or timeline. A project
    /// among them opens first, and the media that came with it are imported into it. Ara keeps one
    /// project open: other projects go on the start screen, and a note says so.
    func importFiles(_ files: [URL]) {
        // Fonts dropped on the window (or opened with Ara) go to the font library, not the media.
        let fonts = files.filter(FontLibrary.accepts)
        if !fonts.isEmpty { addFonts(fonts,applyToSelection:false) }
        var files = files.filter { !FontLibrary.accepts($0) }
        let documents = files.filter(Self.isProjectFile)
        if let document = documents.first {
            files.removeAll(where:Self.isProjectFile)
            guard openProject(document) else { return }
            var seen: Set<String> = [ProjectHistory.normalized(document.path)]
            let others = documents.dropFirst().filter { seen.insert(ProjectHistory.normalized($0.path)).inserted }
            if !others.isEmpty {
                for url in others { registry.record(url) }
                let note = String(localized:"Ara opens one project at a time. These were put on the start screen instead: \(others.map(\.lastPathComponent).joined(separator:", ")).")
                message = message.map { $0+"\n\n"+note } ?? note
            }
        }
        guard !files.isEmpty else { return }
        guard !waitsForExport(String(localized:"Import these files again once the export has finished.")) else { return }
        guard !isImporting else { message = String(localized:"An import is already running. Wait for it to finish."); return }
        showLauncher = false
        for url in files { hold(url) }
        let projectID = project.id; isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            var errors: [String] = []
            for url in files {
                guard !Task.isCancelled, project.id == projectID else { break }
                // The same file spelled another way (through a symbolic link, /tmp for /private/tmp)
                // is the source already there.
                let path = ProjectHistory.normalized(url.path)
                if let existing = project.media.first(where: { ProjectHistory.normalized($0.path) == path }) { selectedMediaID = existing.id; continue }
                status = String(localized:"Reading \(url.lastPathComponent)…")
                do {
                    let media = try await library.inspect(url)
                    guard !Task.isCancelled, project.id == projectID else { break }
                    commitPendingEdits()
                    // Landing during a drag (in the preview, on a slider), the import is an undo step
                    // before the drag's, which starts from the project with the media: undoing the
                    // drag keeps them.
                    if var start = interactionStart { history.record(start,name:"Import media"); start.media.append(media); interactionStart = start }
                    else { history.record(project,name:"Import media") }
                    project.media.append(media); urls[media.id] = url; selectedMediaID = media.id
                    analyze(media,url:url); ensureProxies()
                } catch { if !(error is CancellationError) { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") } }
            }
            if project.id == projectID { isImporting = false; status = String(localized:"Media items: \(project.media.count)"); if !errors.isEmpty { message = errors.joined(separator:"\n\n") } }
        }
    }
    /// Reads a source's thumbnail and waveform. Those of another file (the item was relinked, or
    /// an undo put its first file back) are dropped at once, and a result that lands after the
    /// item has moved on to another file is thrown away.
    private func analyze(_ media: MediaReference, url: URL) {
        if analyzed[media.id] != media.path { thumbnails[media.id] = nil; waveforms[media.id] = nil }
        analyzed[media.id] = media.path
        analysisTasks[media.id]?.cancel(); let projectID = project.id
        analysisTasks[media.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let analysis = try await library.analyze(media,at:url)
                guard !Task.isCancelled, project.id == projectID, analyzed[media.id] == media.path,
                      project.media.contains(where: { $0.id == media.id }) else { return }
                if let data = analysis.thumbnail { thumbnails[media.id] = NSImage(data:data) }
                waveforms[media.id] = analysis.peaks
            } catch {
                if !(error is CancellationError), project.id == projectID, analyzed[media.id] == media.path {
                    status = String(localized:"Analysis unavailable for \(media.name): \(error.localizedDescription)")
                }
            }
        }
    }
    private func restoreAccess() {
        missing.removeAll(); urls.removeAll()
        for i in project.media.indices { locate(i) }
        ensureProxies()
    }
    /// Finds one source through its bookmark, following a file moved or renamed since, and reads
    /// its thumbnail and waveform unless it has those of this file. One that cannot be read is missing.
    private func locate(_ i: Int) {
        let media = project.media[i], resolved = MediaPaths.resolve(media)
        guard !resolved.needsRelink else { lose(media); return }
        // Deleted in Finder, a file goes to the Trash and its bookmark follows it there: it is gone
        // (for good once the Trash is emptied), not moved. Put Back brings it to its place again.
        guard !Self.isInTrash(resolved.url) || Self.isInTrash(URL(fileURLWithPath:media.path)) else { lose(media); return }
        hold(resolved.url)
        guard FileManager.default.isReadableFile(atPath:resolved.url.path) else { lose(media); return }
        urls[media.id] = resolved.url; missing.remove(media.id)
        if resolved.stale {
            project.media[i].path = resolved.url.path
            // Where the saved document named the same file, following it is no unsaved change.
            if saved?.id == project.id, let index = saved?.media.firstIndex(of:media) { saved?.media[index].path = resolved.url.path }
            let projectID = project.id, mediaID = media.id, url = resolved.url
            // Creating a security bookmark may wait on file-system/permission services.
            // Never do it synchronously inside an Open Documents Apple event on the UI thread.
            Task.detached(priority:.utility) { [weak self] in
                let bookmark = MediaPaths.bookmark(for:url)
                await self?.refreshBookmark(bookmark,for:mediaID,projectID:projectID,path:url.path)
            }
        }
        if thumbnails[media.id] == nil || analyzed[media.id] != project.media[i].path { analyze(project.media[i],url:resolved.url) }
    }
    /// A source that cannot be found is missing. It keeps its thumbnail when that shows this very
    /// file, so the library still shows what to look for.
    private func lose(_ media: MediaReference) {
        missing.insert(media.id); urls[media.id] = nil
        guard analyzed[media.id] != media.path else { return }
        analysisTasks[media.id]?.cancel(); analyzed[media.id] = nil; thumbnails[media.id] = nil; waveforms[media.id] = nil
    }
    /// Sources can be moved, renamed or deleted in Finder while the project is open. Each of these
    /// that can no longer be read where it was is looked for again: a moved file is followed
    /// through its bookmark, one that is gone is marked missing (the library then offers Relink…
    /// and the viewer asks to reconnect), and a missing one may be back. True when any changed.
    @discardableResult private func recheckSources(_ ids: Set<UUID>) -> Bool {
        var changed = false
        for i in project.media.indices where ids.contains(project.media[i].id) {
            let id = project.media[i].id, before = urls[id]
            if let url = before {
                if FileManager.default.isReadableFile(atPath:url.path) { continue }
            } else {
                // A missing one is looked for once something is back at its place (a drive
                // reconnected, the file put back). One never looked for is left alone.
                guard missing.contains(id), FileManager.default.fileExists(atPath:project.media[i].path) else { continue }
            }
            locate(i)
            if urls[id] != before { changed = true }
        }
        if changed { ensureProxies() }
        return changed
    }
    /// Ara is back in front: sources moved or deleted in the meantime are found again or marked
    /// missing, and missing ones put back are picked up, before an edit runs into them.
    func refreshSources() {
        if recheckSources(Set(project.media.map(\.id))) { rebuild() }
    }
    /// Points the preview at the FHD proxy of every source larger than 1920 × 1080 that has one
    /// on disk, and makes the missing ones in the background, one at a time. Until a source's
    /// proxy lands the preview reads the original, so nothing waits on this.
    private func ensureProxies() {
        if let job = proxyJob, urls[job.id].map(ProxyMaker.url(for:)) != job.key { job.task.cancel() }
        mapProxies()
        guard proxyTask == nil, nextProxyJob() != nil else { return }
        proxyTask = Task { [weak self] in await self?.makeProxies() }
    }
    private func wantsProxy(_ media: MediaReference) -> Bool {
        media.kind == .video && ProxyMaker.wantsProxy(width:media.width,height:media.height)
    }
    private func mapProxies() {
        var ready: [UUID:URL] = [:]
        for media in project.media where wantsProxy(media) {
            guard let url = urls[media.id] else { continue }
            let expected = ProxyMaker.url(for:url)
            if proxies[media.id] == expected, FileManager.default.isReadableFile(atPath:expected.path) { ready[media.id] = expected }
            else if let proxy = ProxyMaker.existing(for:url) { ready[media.id] = proxy }
        }
        guard ready != proxies else { return }
        let changed = Set(ready.keys).union(proxies.keys).filter { ready[$0] != proxies[$0] }
        proxies = ready
        guard project.clips.contains(where: { $0.mediaID.map(changed.contains) ?? false }) else { return }
        // Switching the preview replaces the player item: a hitch in playback, and a transform or
        // slider drag loses input until the new item is up. Wait until neither is happening.
        if isPlaying || resumeAfterBuild || interactionStart != nil { proxySwapDeferred = true } else { rebuild() }
    }
    private func applyDeferredProxySwap() {
        guard proxySwapDeferred, !isPlaying, !resumeAfterBuild, interactionStart == nil else { return }
        proxySwapDeferred = false; rebuild()
    }
    private func nextProxyJob() -> (media: MediaReference, url: URL, remaining: Int)? {
        let waiting = project.media.filter { media in
            guard wantsProxy(media), proxies[media.id] == nil, let url = urls[media.id] else { return false }
            return !proxyFailures.contains(ProxyMaker.url(for:url))
        }
        guard let first = waiting.first, let url = urls[first.id] else { return nil }
        return (first,url,waiting.count)
    }
    private func makeProxies() async {
        let session = self.session
        while !Task.isCancelled, session == self.session, let job = nextProxyJob() {
            let name = job.media.name
            proxyProgress = (name,0,job.remaining)
            let key = ProxyMaker.url(for:job.url)
            let work = Task { [weak self] in
                try await ProxyMaker.make(from:job.url) { fraction in
                    Task { @MainActor in
                        guard let self, self.session == session, self.proxyProgress?.name == name else { return }
                        self.proxyProgress?.fraction = fraction
                    }
                }
            }
            proxyJob = (job.media.id,key,work)
            do {
                let made = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                if proxyJob?.task == work { proxyJob = nil }     // a newer document may have its own job by now
                guard !Task.isCancelled, session == self.session else { return }
                // nil: a stream this proxy cannot stand in for (already FHD, alpha, non-square
                // pixels, colour tags the writer refuses). The preview keeps the original.
                if made == nil { proxyFailures.insert(key) }
            } catch {
                if proxyJob?.task == work { proxyJob = nil }
                guard !Task.isCancelled, session == self.session else { return }
                // Stopped because its source left the project: not a failure, move on.
                if !(error is CancellationError) {
                    proxyFailures.insert(key)
                    status = String(localized:"FHD preview media unavailable for \(name) · Previewing the original")
                }
            }
            mapProxies()
        }
        if session == self.session { proxyProgress = nil; proxyTask = nil }
    }
    private func refreshBookmark(_ bookmark:Data?,for mediaID:UUID,projectID:UUID,path:String) {
        guard project.id == projectID, let bookmark,
              let i = project.media.firstIndex(where:{$0.id == mediaID && $0.path == path}) else { return }
        let before = project.media[i]
        project.media[i].bookmark = bookmark
        if saved?.id == projectID, let savedIndex = saved?.media.firstIndex(where:{$0 == before}) {
            saved?.media[savedIndex].bookmark = bookmark
        }
    }
    func relink(_ media: MediaReference) {
        let panel = NSOpenPanel(); panel.title = String(localized:"Relink \(media.name)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relink(media,to:url)
    }
    /// Points a media item at another file; its clips stay where they are.
    func relink(_ media: MediaReference, to url: URL) {
        hold(url)
        let projectID = project.id
        Task {
            do {
                var replacement = try await library.inspect(url)
                guard project.id == projectID else { return }
                guard replacement.kind == media.kind, !media.hasAudio || replacement.hasAudio else { throw EditError("Choose a file with the same media type and required audio stream.") }
                replacement.id = media.id
                if edit("Relink media", { p in if let i = p.media.firstIndex(where: { $0.id == media.id }) { p.media[i] = replacement } }) {
                    urls[media.id] = url; missing.remove(media.id); analyze(replacement,url:url)
                    proxyFailures.remove(ProxyMaker.url(for:url)); ensureProxies(); rebuild()
                }
            } catch { report(error) }
        }
    }
    func confirmDiscard() -> Bool {
        // A title typed a moment ago is still waiting on its commit delay: it counts.
        commitPendingEdits()
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = String(localized:"Save changes to \(project.name)?")
        alert.informativeText = String(localized:"Your source media files are never modified.")
        alert.addButton(withTitle:String(localized:"Save")); alert.addButton(withTitle:String(localized:"Cancel")); alert.addButton(withTitle:String(localized:"Discard Changes"))
        switch runAlert(alert) {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    private func resetSession() {
        // The previous document's open live-edit run is discarded, not recorded: its idle timer
        // would otherwise write the old document into the new one's undo history.
        liveEditEnd?.cancel(); liveEditEnd = nil; liveEditStart = nil; interactionStart = nil; proxySwapDeferred = false
        session = UUID(); titleDraws.removeAll()
        // A sheet made for the previous document (its export settings) closes with it.
        showNewProjectSheet = false; showExportSheet = false
        previewTransformID = nil
        pause(); revision += 1; rebuildTask?.cancel(); importTask?.cancel(); isBuilding = false; isImporting = false
        snapshotTask?.cancel(); snapshotTask = nil; snapshotID = nil; isCapturingSnapshot = false
        for task in analysisTasks.values { task.cancel() }; analysisTasks.removeAll(); analyzed.removeAll(); documentBookmark = nil
        player.replaceCurrentItem(with:nil); history = EditHistory(); playhead = .zero
        seekInFlight = nil; chaseTarget = nil; seeking = false
        proxyTask?.cancel(); proxyTask = nil; proxyJob = nil; proxyProgress = nil; proxies.removeAll(); proxyFailures.removeAll()
        selectClips([]); dragSelectArmed = false; selectedGap = nil; selectedMediaID = nil; selectedTransitionID = nil; thumbnails.removeAll(); waveforms.removeAll(); urls.removeAll(); missing.removeAll()
        // Keep security scopes until app termination: an in-flight cancelled reader may still own a buffer.
    }
    func newProject() {
        guard !waitsForExport(String(localized:"Start a new project once the export has finished.")) else { return }
        guard !isCapturingSnapshot, !showExportSheet else { return }
        pause(); showNewProjectSheet = true
    }
    /// The export reads this project until it is done. New, Open and Import say so rather than do
    /// nothing: true when `advice` was shown and the request goes no further.
    private func waitsForExport(_ advice: @autoclosure () -> String) -> Bool {
        guard isExporting else { return false }
        let alert = NSAlert(); alert.messageText = String(localized:"An output is being saved"); alert.informativeText = advice()
        _ = runAlert(alert); return true
    }
    /// A project name with something to see. One of only spaces and characters that draw nothing
    /// (a joiner, a direction mark, a soft hyphen) would show blank everywhere.
    static func isVisibleName(_ name: String) -> Bool {
        name.unicodeScalars.contains { !$0.properties.isDefaultIgnorableCodePoint && !$0.properties.isWhitespace }
    }
    /// The setup sheet owns a draft. Only an accepted, valid setup can replace open work.
    @discardableResult func createProject(name: String, aspectRatio: VideoAspectRatio, frameRate: FrameRate, resolution: Int) throws -> Bool {
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard Self.isVisibleName(name) else { throw EditError(String(localized:"Enter a project name.")) }
        // Line breaks and control characters only. Format characters (the joiner in family and flag
        // emoji, ZWNJ, a soft hyphen, a direction mark) are ordinary parts of a name.
        guard name.count <= 120, !name.unicodeScalars.contains(where:{ $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0) }) else {
            throw EditError(String(localized:"Use a project name of up to 120 characters, without line breaks or tabs."))
        }
        var next = Project(); next.name = name; next.aspectRatio = aspectRatio
        next.frameRate = frameRate; next.outputResolution = resolution
        next = try next.validated()
        commitPendingEdits()
        guard !isExporting, !isCapturingSnapshot, confirmDiscard() else { return false }
        resetSession(); project = next; saved = nil; documentURL = nil
        status = String(localized:"New project · \(next.aspectRatio.dimensions(resolution:next.outputResolution)) · \(next.frameRate.label) fps")
        showNewProjectSheet = false; showLauncher = false
        return true
    }
    @discardableResult func save(as: Bool = false) -> Bool {
        commitPendingEdits()
        var target = `as` ? nil : documentLocation()
        if target == nil {
            let panel = NSSavePanel(); panel.title = String(localized:"Save Ara project")
            panel.allowedContentTypes = [UTType(exportedAs:"com.framestudio.project",conformingTo:.json)]
            panel.nameFieldStringValue = project.name+".framestudio"
            guard panel.runModal() == .OK, let url = panel.url else { return false }; target = url
        }
        guard let target else { return false }
        do {
            var next = project; next.name = target.deletingPathExtension().lastPathComponent
            try Self.writeDocument(ProjectFile.encode(next),to:target)
            // Renamed or moved in Finder while open: its start-screen card goes with it.
            if !`as`, let old = documentURL, old != target { registry.relocate(old,to:target) }
            project = next; saved = project; documentURL = target; followDocument(target)
            NSDocumentController.shared.noteNewRecentDocumentURL(target); registry.record(target)
            status = String(localized:"Saved \(target.lastPathComponent)"); return true
        } catch { report(error); return false }
    }
    /// Where the open document is now. Renamed or moved in Finder since it was opened or saved, it
    /// is found through its bookmark; deleted (or put in the Trash), it is written where it was.
    private func documentLocation() -> URL? {
        guard let url = documentURL, let bookmark = documentBookmark else { return documentURL }
        var stale = false
        guard let found = try? URL(resolvingBookmarkData:bookmark,options:[.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale),
              ProjectHistory.normalized(found.path) != ProjectHistory.normalized(url.path),
              FileManager.default.fileExists(atPath:found.path), !Self.isInTrash(found) else { return url }
        return found
    }
    /// In a Trash: the home folder's, another volume's or iCloud Drive's.
    static func isInTrash(_ url: URL) -> Bool { url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" } }
    /// Keeps a bookmark of the open document. It is made off the main actor: opening is reached
    /// from the Open Documents Apple event, and making one can wait on file-system services.
    private func followDocument(_ url: URL) {
        documentBookmark = nil
        let path = url.path
        Task { [weak self] in
            let bookmark = await Task.detached(priority:.utility) {
                try? URL(fileURLWithPath:path).bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
            }.value
            guard let self, documentURL?.path == path else { return }
            documentBookmark = bookmark
        }
    }
    /// Writes a document over the old one without losing what Finder keeps on the file: a symbolic
    /// link is written through to the file it points at, and the file keeps its tags and other
    /// extended attributes, its access list (a shared folder's entries included) and group, its
    /// permissions and creation date. The new contents are complete in a temporary file before
    /// they take the old one's place, so a failed save leaves it whole.
    static func writeDocument(_ data: Data, to url: URL) throws {
        let files = FileManager.default, destination = url.resolvingSymlinksInPath()
        guard let old = try? files.attributesOfItem(atPath:destination.path),
              let folder = try? files.url(for:.itemReplacementDirectory,in:.userDomainMask,appropriateFor:destination,create:true)
        else { try data.write(to:destination,options:.atomic); return }
        defer { try? files.removeItem(at:folder) }
        let staged = folder.appendingPathComponent(destination.lastPathComponent)
        try data.write(to:staged)
        _ = copyfile(destination.path,staged.path,nil,copyfile_flags_t(COPYFILE_XATTR))
        // The access list as it is, the entries it has from a shared folder included: copyfile
        // leaves those to the new file's own folder, and the staging folder has none.
        if let access = acl_get_file(destination.path,ACL_TYPE_EXTENDED) {
            _ = acl_set_file(staged.path,ACL_TYPE_EXTENDED,access); acl_free(UnsafeMutableRawPointer(access))
        }
        // Apart: a group the user is not in cannot be set, and must not stop the rest.
        try? files.setAttributes(old.filter { $0.key == .groupOwnerAccountID },ofItemAtPath:staged.path)
        try? files.setAttributes(old.filter { $0.key == .posixPermissions || $0.key == .creationDate },ofItemAtPath:staged.path)
        guard rename(staged.path,destination.path) == 0 else {
            let code = errno
            throw CocoaError(code == EACCES || code == EPERM ? .fileWriteNoPermission : .fileWriteUnknown,
                             userInfo:[NSURLErrorKey:destination,NSUnderlyingErrorKey:POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO)])
        }
    }
    /// Returning to the start screen keeps the current project loaded; choosing another one
    /// from there goes through openProject, which asks before discarding unsaved changes.
    func showStartScreen() {
        commitPendingEdits()
        guard !isExporting, !isCapturingSnapshot else { return }
        pause(); selectedGap = nil; showLauncher = true; registry.refresh()
    }
    /// True when there is something worth returning to from the start screen.
    var hasOpenWork: Bool { dirty || documentURL != nil || !project.clips.isEmpty || !project.media.isEmpty }
    func resumeEditing() { if hasOpenWork { showLauncher = false } }
    func openFromLauncher(_ path: String) {
        let url = URL(fileURLWithPath: path)
        // The open document, also when it was renamed or moved in Finder since (its card follows it).
        if let current = documentLocation(), ProjectHistory.normalized(current.path) == ProjectHistory.normalized(path) { showLauncher = false; return }
        openProject(url)
        if showLauncher { registry.refresh() }   // failed: the card re-reads and shows why
    }
    func addProjects(_ urls: [URL]) {
        Task {
            let result = await registry.add(from:urls)
            if result.unlisted > 0 {
                message = String(localized:"The start screen lists up to \(ProjectHistory.limit) projects and has no room for \(result.unlisted) found here. Remove projects from the list to make room.")
            } else if result.added == 0 { message = String(localized:"No new .framestudio projects were found there.") }
        }
    }
    func chooseOpen() {
        guard !waitsForExport(String(localized:"Open a project once the export has finished.")) else { return }
        let panel = NSOpenPanel(); panel.title = String(localized:"Open project")
        panel.allowedContentTypes = [UTType(exportedAs:"com.framestudio.project",conformingTo:.json),.json]
        if panel.runModal() == .OK, let url = panel.url { openProject(url) }
    }
    /// True when the project was opened (not cancelled, refused or unreadable).
    @discardableResult func openProject(_ url: URL) -> Bool {
        commitPendingEdits()
        guard !waitsForExport(String(localized:"Open “\(url.lastPathComponent)” again once the export has finished.")) else { return false }
        guard confirmDiscard() else { return false }
        do {
            let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
            let loaded = try ProjectFile.decode(Data(contentsOf:url))
            resetSession(); project = loaded; documentURL = url; followDocument(url); restoreAccess(); saved = project
            rebuild()                                   // held back only by missing sources the timeline uses
            let fonts = missingFonts
            if !fonts.isEmpty {
                message = String(localized:"This project uses fonts that aren't on this Mac: \(fonts.joined(separator:", ")). Titles in them are shown in Helvetica Neue Bold until you add the fonts (Add Font… in a title's inspector).")
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(url); registry.record(url)
            showLauncher = false
            return true
        } catch { report(error); return false }
    }
    func chooseSnapshot() {
        commitPendingEdits()
        guard canCaptureSnapshot, let time = project.snapshotTime(at:playhead) else { return }
        pause(); seek(time)
        let snapshot = project, mediaURLs = urls
        let timecode = snapshot.frameRate.timecode(time)
        let panel = NSSavePanel(); panel.title = String(localized:"Save timeline snapshot"); panel.allowedContentTypes = [.png]
        panel.message = String(localized:"Current composed frame · \(timecode) · \(snapshot.aspectRatio.dimensions()) PNG")
        panel.nameFieldStringValue = snapshot.name+"-"+timecode.replacingOccurrences(of:":",with:"-")+".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !mediaURLs.values.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() }) else {
            message = String(localized:"Choose a different filename. A snapshot cannot replace source media."); return
        }
        let token = UUID(); snapshotID = token; isCapturingSnapshot = true
        status = String(localized:"Saving snapshot at \(timecode)…")
        snapshotTask = Task { [self] in
            do {
                let bundle = try await builder.build(snapshot,urls:mediaURLs)
                try Task.checkCancellation()
                try await snapshotExporter.export(bundle,at:time,to:url)
                guard snapshotID == token else { return }
                isCapturingSnapshot = false; snapshotTask = nil; snapshotID = nil
                status = String(localized:"Snapshot saved · \(url.lastPathComponent) · \(snapshot.aspectRatio.dimensions())")
            } catch {
                guard snapshotID == token else { return }
                isCapturingSnapshot = false; snapshotTask = nil; snapshotID = nil
                if error is CancellationError { status = String(localized:"Snapshot cancelled") } else { report(error) }
            }
        }
    }
    func chooseExport(aspectRatio: VideoAspectRatio, frameRate: FrameRate, height: Int) {
        commitPendingEdits()
        guard !project.clips.isEmpty, !isExporting else { return }
        let panel = NSSavePanel(); panel.title = String(localized:"Export H.264 / AAC MP4"); panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = project.name+".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !urls.values.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() }) else {
            message = String(localized:"Choose a different output filename. Export cannot replace source media."); return
        }
        // Canceling the destination panel leaves the project and export preset untouched.
        do { try setVideoSettings(aspectRatio:aspectRatio,frameRate:frameRate,resolution:height) }
        catch { report(error); return }
        let snapshot = project, mediaURLs = urls
        pause(); isExporting = true; exportProgress = 0; status = String(localized:"Preparing export…")
        exportTask = Task { [self] in
            do {
                let bundle = try await builder.build(snapshot,urls:mediaURLs,height:height)
                try await exporter.export(bundle,to:url) { [weak self] value in
                    await MainActor.run { self?.exportProgress = value }
                }
                status = String(localized:"Exported \(url.lastPathComponent)"); isExporting = false
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                isExporting = false
                if error is CancellationError { status = String(localized:"Export cancelled · Partial file removed") } else { report(error) }
            }
        }
    }
    func cancelExport() { exportTask?.cancel(); status = String(localized:"Cancelling export…") }
}

@MainActor final class PlayheadClock: ObservableObject {
    @Published fileprivate(set) var time = MediaTime.zero { didSet { moved.send((oldValue,time)) } }
    /// For AppKit views: sent after each move, with where the playhead was and where it is now.
    let moved = PassthroughSubject<(old: MediaTime, new: MediaTime),Never>()
}
