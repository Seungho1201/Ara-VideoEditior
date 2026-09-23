import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import UniformTypeIdentifiers
import FrameCore
import FrameMedia

@MainActor final class EditorStore: ObservableObject {
    @Published private(set) var project = Project()
    /// The start screen is up instead of the editor. A launch that names a project or media
    /// (Finder, `--project`, `--import`) goes straight to the editor.
    @Published private(set) var showLauncher = !CommandLine.arguments.contains("--project") && !CommandLine.arguments.contains("--import")
    let registry = ProjectRegistry()
    /// A text field in the inspector has focus. Unmodified arrow-key menu equivalents beat any
    /// first responder, so the frame-step items must stand down or the caret cannot move.
    @Published var isEditingText = false
    @Published var selectedClipID: UUID? {
        didSet { if previewTransformID != selectedClipID { previewTransformID = nil } }
    }
    @Published var previewTransformID: UUID?
    @Published var selectedGap: TimelineGap?
    @Published var selectedMediaID: UUID?
    @Published var playhead = MediaTime.zero
    @Published private(set) var revealPlayheadRequest = 0
    @Published var zoom: Double = 64
    @Published var snapping = true
    @Published var isPlaying = false
    @Published var isBuilding = false
    @Published var isImporting = false
    @Published var isExporting = false
    @Published private(set) var isCapturingSnapshot = false
    @Published var exportProgress: Double = 0
    @Published var showExportSheet = false
    @Published var exportHeight = 1080
    @Published var message: String?
    @Published var status = "Import media to start editing"
    @Published var thumbnails: [UUID:NSImage] = [:]
    @Published var waveforms: [UUID:[Float]] = [:]
    @Published var missing: Set<UUID> = []
    @Published private(set) var documentURL: URL?
    private var saved = Project()
    private(set) var history = EditHistory()
    private var interactionStart: Project?
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
    private let library = MediaLibrary()
    private let builder = CompositionBuilder()
    private let exporter = MovieExporter()
    private let snapshotExporter = SnapshotExporter()
    private var rebuildTask: Task<Void,Never>?
    private var importTask: Task<Void,Never>?
    private var analysisTasks: [UUID:Task<Void,Never>] = [:]
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
    /// supersedes the first, which would otherwise read "not playing" and leave playback stopped.
    private var resumeAfterBuild = false
    private var rateObservation: NSKeyValueObservation?
    private var proxySwapDeferred = false
    private var periodic: Any?
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
    var canCopyClip: Bool { selectedClip != nil }
    /// Only clips backed by a media stream can be retimed; text and stills have no source to speed up.
    var canRetimeSelection: Bool { selectedClip.map { $0.kind == .video || $0.kind == .audio } ?? false }
    var selectedSpeed: Double { selectedClip?.speed ?? 1 }
    var canPasteClip: Bool { NSPasteboard.general.availableType(from:[Self.clipPasteboardType]) != nil }
    var canCaptureSnapshot: Bool { project.duration > .zero && missing.isEmpty && !isBuilding && !isCapturingSnapshot && !isExporting }
    init() {
        saved = project
        player.actionAtItemEnd = .pause
        Task.detached(priority:.background) { ProxyMaker.prune() }
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
    func report(_ error: Error) { if !(error is CancellationError) { message = error.localizedDescription; status = "Action could not be completed" } }
    @discardableResult func edit(_ name: String, _ operation: (inout Project) throws -> Void) -> Bool {
        commitPendingEdits()
        do {
            var next = project; try operation(&next); _ = try next.validated()
            guard next != project else { return true }
            if interactionStart == nil { history.record(project,name:name) }
            // Any timeline change can move the edges a gap selection was measured from.
            project = next; selectedGap = nil; rebuild(); return true
        } catch { report(error); return false }
    }
    func beginInteraction() { commitPendingEdits(); if interactionStart == nil { interactionStart = project } }
    func endInteraction() {
        if let before = interactionStart, before != project { history.record(before,name:"Adjust clip") }
        interactionStart = nil; objectWillChange.send()
        applyDeferredProxySwap()
    }
    func updateStyle(_ update: (inout ClipStyle) -> Void) {
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
        guard let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var clip = project.clips[index]
        update(&clip.style)
        guard clip != project.clips[index] else { return }
        var candidate = project; candidate.clips[index] = clip
        guard (try? candidate.validated()) != nil else { return }
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
    /// Re-renders one layer of the current preview in place. False when there is no settled
    /// player item to patch (nothing loaded yet, or a rebuild is in flight whose snapshot is
    /// already stale) — the caller then rebuilds from the current project instead.
    private func refreshPreviewLayer(_ clip: Clip) -> Bool {
        guard !isBuilding, let item = player.currentItem,
              let composition = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition,
              let instruction = composition.instructions.first as? FrameInstruction,
              instruction.layers.contains(where: { $0.clip.id == clip.id }) else { return false }
        var image: CIImage?
        if clip.kind == .text { guard let text = try? FrameRenderer.textImage(clip.style) else { return false }; image = text }
        composition.instructions = [instruction.replacingLayer(for:clip,image:image)]
        // A fresh composition re-renders a paused frame without replacing the player item (QA1966).
        item.videoComposition = composition
        return true
    }
    /// Direct manipulation changes only placement; it does not rebuild tracks or audio.
    func updatePreviewTransform(_ id: UUID, style: ClipStyle) {
        guard previewTransformID == id, !isBuilding,
              let index = project.clips.firstIndex(where: { $0.id == id }),
              let item = player.currentItem,
              let composition = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition,
              let instruction = composition.instructions.first as? FrameInstruction,
              instruction.layers.contains(where: { $0.clip.id == id }) else { return }
        var clip = project.clips[index]
        clip.style.x = style.x; clip.style.y = style.y; clip.style.scale = style.scale
        guard clip != project.clips[index] else { return }
        var candidate = project; candidate.clips[index] = clip
        guard (try? candidate.validated()) != nil else { return }
        project = candidate
        composition.instructions = [instruction.replacingTransform(of:clip)]
        // A fresh composition re-renders a paused frame without replacing the player item (QA1966).
        item.videoComposition = composition
    }
    /// The rendered image a text or still layer shows in the current preview.
    func previewLayerImage(for clip: Clip) -> CIImage? {
        (player.currentItem?.videoComposition?.instructions.first as? FrameInstruction)?
            .layers.first(where: { $0.clip.id == clip.id })?.image
    }
    /// What the preview decodes for this clip: its FHD proxy when there is one.
    func previewSourceURL(for clip: Clip) -> URL? { clip.mediaID.flatMap { proxies[$0] ?? urls[$0] } }
    func previewSourceSize(for clip: Clip) -> CGSize? {
        if let instruction = player.currentItem?.videoComposition?.instructions.first as? FrameInstruction,
           let image = instruction.layers.first(where: { $0.clip.id == clip.id })?.image {
            return image.extent.size
        }
        guard let media = project.media(for:clip), media.width > 0, media.height > 0 else { return nil }
        return CGSize(width:media.width,height:media.height)
    }
    func undo() { commitPendingEdits(); endInteraction(); selectedGap = nil; if let previous = history.undo(project) { project = previous; restoreAccess(); rebuild() } }
    func redo() { commitPendingEdits(); endInteraction(); selectedGap = nil; if let next = history.redo(project) { project = next; restoreAccess(); rebuild() } }
    func split() { guard let id = selectedClipID else { return }; edit("Split clip") { try Editing.split(id,at:playhead,in:&$0) } }
    /// Retiming changes the clip's timeline length, so it is one undoable step per commit,
    /// not per slider sample: the caller brackets a drag with begin/endInteraction.
    func setSpeed(_ speed: Double) {
        guard let id = selectedClipID else { return }
        edit("Change speed") { try Editing.setSpeed(id,to:speed,in:&$0) }
    }
    /// Slider path: every sample resolves against the snapshot the drag started from, so
    /// dragging back to where you began restores the clip exactly instead of ratcheting down.
    func setSpeedInteractively(_ speed: Double) {
        guard let id = selectedClipID else { return }
        let base = interactionStart
        edit("Change speed") { try Editing.setSpeed(id,to:speed,in:&$0,basedOn:base) }
    }
    func deleteSelection() { guard let id = selectedClipID else { return }; if edit("Delete clip",{ Editing.delete(id,from:&$0) }) { selectedClipID = nil } }
    func copySelection() {
        guard let id = selectedClipID else { return }
        do {
            let payload = try ClipClipboard(copying:id,from:project)
            let item = NSPasteboardItem()
            guard item.setData(try payload.encoded(),forType:Self.clipPasteboardType) else { throw EditError("Cannot copy this clip.") }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([item]) else { throw EditError("Cannot write to the clipboard.") }
            status = payload.clips.count == 2 ? "Copied clip and linked audio · ⌘V at playhead" : "Copied clip · ⌘V at playhead"
        } catch { report(error) }
    }
    func pasteClips() {
        guard let data = NSPasteboard.general.data(forType:Self.clipPasteboardType) else { return }
        do {
            let payload = try ClipClipboard.decode(data)
            endInteraction(); pause()
            let oldMedia = project.media
            var insertedID: UUID?
            if edit("Paste clip",{ insertedID = try Editing.paste(payload,at:playhead,into:&$0) }) {
                selectedClipID = insertedID; selectedGap = nil
                if project.media != oldMedia { restoreAccess(); rebuild() }
                revealPlayheadRequest += 1
                status = "Pasted clip at \(timecode) · ⌘Z to undo"
            }
        } catch { report(error) }
    }
    func selectGap(_ gap: TimelineGap?) { selectedGap = gap; if gap != nil { selectedClipID = nil } }
    func closeSelectedGap() {
        guard let gap = selectedGap else { return }
        // edit() clears selectedGap on success; restore it on failure so the outline stays put.
        if !edit("Close gap",{ try Editing.closeGap(gap,in:&$0) }) { selectedGap = gap }
    }
    func addMedia(_ id: UUID, lane: Lane? = nil, at time: MediaTime? = nil) {
        guard let media = project.media.first(where: { $0.id == id }) else { return }
        guard !missing.contains(id) else { message = "Relink this source in the library before adding it."; return }
        let target = lane ?? (media.kind == .audio ? .a1 : .v1)
        let end = project.clips.filter { $0.lane == target || (media.hasAudio && $0.lane == target.paired) }.map(\.end).max() ?? .zero
        var result: UUID?
        if edit("Add clip", { result = try Editing.add(mediaID:id,lane:target,at:time ?? end,to:&$0) }) { selectedClipID = result; status = "Added \(media.name) to \(target.rawValue)" }
    }
    func addText() {
        var id: UUID?
        if edit("Add text", { id = try Editing.addText(at:playhead,to:&$0) }) { selectedClipID = id }
    }
    func move(_ id: UUID, to time: MediaTime, lane: Lane) { edit("Move clip") { try Editing.move(id,to:time,lane:lane,in:&$0) } }
    func trim(_ id: UUID, leading: Bool, to time: MediaTime) { edit("Trim clip") { try Editing.trim(id,leading:leading,to:time,in:&$0) } }
    func setRate(_ rate: FrameRate) {
        guard project.clips.isEmpty else { return }
        edit("Project frame rate") { $0.frameRate = rate }
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
        guard !isBuilding, player.currentItem != nil else { return }
        if isPlaying { pause() }
        else { previewTransformID = nil; if playhead >= project.duration { seek(.zero) }; settleSeek(); player.play(); isPlaying = true }
    }
    private func rebuild() {
        proxySwapDeferred = false               // this build picks up the current proxies
        revision += 1; let token = revision
        rebuildTask?.cancel(); let resume = isPlaying || resumeAfterBuild; pause()
        resumeAfterBuild = resume                // after pause(), which clears it
        playhead = min(playhead,project.duration)
        guard !project.clips.isEmpty else { player.replaceCurrentItem(with:nil); isBuilding = false; resumeAfterBuild = false; return }
        guard missing.isEmpty else {
            player.replaceCurrentItem(with:nil); isBuilding = false; resumeAfterBuild = false
            status = "\(missing.count) missing files · Use Relink in the library"; return
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
                        let text = item.error?.localizedDescription ?? "Preview failed."
                        Task { @MainActor in self?.message = text }
                    }
                }
                player.replaceCurrentItem(with:item); isBuilding = false; seek(playhead)
                resumeAfterBuild = false
                if resume { player.play(); isPlaying = true }
                status = "\(project.clips.filter { $0.kind != .audio || $0.linkID == nil }.count) clips · SDR Rec.709"
            } catch {
                guard revision == token else { return }; isBuilding = false; resumeAfterBuild = false
                if !(error is CancellationError) { player.replaceCurrentItem(with:nil); report(error) }
            }
        }
    }
    func chooseImport() {
        let panel = NSOpenPanel(); panel.title = "Import media"; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie,.audio,.png,.jpeg,.tiff]
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }
    private func hold(_ url: URL) {
        if scopes[url] == nil { scopes[url] = url.startAccessingSecurityScopedResource() }
    }
    func importFiles(_ files: [URL]) {
        guard !isImporting else { message = "An import is already running. Wait for it to finish."; return }
        showLauncher = false
        for url in files { hold(url) }
        let projectID = project.id; isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            var errors: [String] = []
            for url in files {
                guard !Task.isCancelled, project.id == projectID else { break }
                if let existing = project.media.first(where: { $0.path == url.path }) { selectedMediaID = existing.id; continue }
                status = "Reading \(url.lastPathComponent)…"
                do {
                    let media = try await library.inspect(url)
                    guard !Task.isCancelled, project.id == projectID else { break }
                    commitPendingEdits(); history.record(project,name:"Import media"); project.media.append(media); urls[media.id] = url; selectedMediaID = media.id
                    analyze(media,url:url); ensureProxies()
                } catch { if !(error is CancellationError) { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") } }
            }
            if project.id == projectID { isImporting = false; status = "\(project.media.count) media items"; if !errors.isEmpty { message = errors.joined(separator:"\n\n") } }
        }
    }
    private func analyze(_ media: MediaReference, url: URL) {
        analysisTasks[media.id]?.cancel(); let projectID = project.id
        analysisTasks[media.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let analysis = try await library.analyze(media,at:url)
                guard !Task.isCancelled, project.id == projectID, project.media.contains(where: { $0.id == media.id }) else { return }
                if let data = analysis.thumbnail { thumbnails[media.id] = NSImage(data:data) }
                waveforms[media.id] = analysis.peaks
            } catch { if !(error is CancellationError), project.id == projectID { status = "Analysis unavailable for \(media.name): \(error.localizedDescription)" } }
        }
    }
    private func restoreAccess() {
        missing.removeAll(); urls.removeAll()
        for i in project.media.indices {
            let resolved = MediaPaths.resolve(project.media[i])
            guard !resolved.needsRelink else { missing.insert(project.media[i].id); continue }
            hold(resolved.url)
            if FileManager.default.isReadableFile(atPath:resolved.url.path) {
                urls[project.media[i].id] = resolved.url
                if resolved.stale {
                    project.media[i].path = resolved.url.path
                    let projectID = project.id, mediaID = project.media[i].id, url = resolved.url
                    // Creating a security bookmark may wait on file-system/permission services.
                    // Never do it synchronously inside an Open Documents Apple event on the UI thread.
                    Task.detached(priority:.utility) { [weak self] in
                        let bookmark = MediaPaths.bookmark(for:url)
                        await self?.refreshBookmark(bookmark,for:mediaID,projectID:projectID,path:url.path)
                    }
                }
                if thumbnails[project.media[i].id] == nil { analyze(project.media[i],url:resolved.url) }
            } else { missing.insert(project.media[i].id) }
        }
        ensureProxies()
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
                    status = "FHD preview media unavailable for \(name) · Previewing the original"
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
        if saved.id == projectID, let savedIndex = saved.media.firstIndex(where:{$0 == before}) {
            saved.media[savedIndex].bookmark = bookmark
        }
    }
    func relink(_ media: MediaReference) {
        let panel = NSOpenPanel(); panel.title = "Relink \(media.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }; hold(url)
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
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to \(project.name)?"
        alert.informativeText = "Your source media files are never modified."
        alert.addButton(withTitle:"Save"); alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    private func resetSession() {
        // The previous document's open live-edit run is discarded, not recorded: its idle timer
        // would otherwise write the old document into the new one's undo history.
        liveEditEnd?.cancel(); liveEditEnd = nil; liveEditStart = nil; interactionStart = nil; proxySwapDeferred = false
        session = UUID()
        previewTransformID = nil
        pause(); revision += 1; rebuildTask?.cancel(); importTask?.cancel(); isBuilding = false; isImporting = false
        snapshotTask?.cancel(); snapshotTask = nil; snapshotID = nil; isCapturingSnapshot = false
        for task in analysisTasks.values { task.cancel() }; analysisTasks.removeAll()
        player.replaceCurrentItem(with:nil); history = EditHistory(); playhead = .zero
        seekInFlight = nil; chaseTarget = nil; seeking = false
        proxyTask?.cancel(); proxyTask = nil; proxyJob = nil; proxyProgress = nil; proxies.removeAll(); proxyFailures.removeAll()
        selectedClipID = nil; selectedGap = nil; selectedMediaID = nil; thumbnails.removeAll(); waveforms.removeAll(); urls.removeAll(); missing.removeAll()
        // Keep security scopes until app termination: an in-flight cancelled reader may still own a buffer.
    }
    func newProject() {
        commitPendingEdits()
        guard !isExporting, confirmDiscard() else { return }
        resetSession(); project = Project(); saved = project; documentURL = nil; status = "New project · Choose a frame rate, then import media"
        showLauncher = false
    }
    @discardableResult func save(as: Bool = false) -> Bool {
        commitPendingEdits()
        var target = documentURL
        if target == nil || `as` {
            let panel = NSSavePanel(); panel.title = "Save Ara project"
            panel.allowedContentTypes = [UTType(exportedAs:"com.framestudio.project",conformingTo:.json)]
            panel.nameFieldStringValue = project.name+".framestudio"
            guard panel.runModal() == .OK, let url = panel.url else { return false }; target = url
        }
        guard let target else { return false }
        do {
            var next = project; next.name = target.deletingPathExtension().lastPathComponent
            try ProjectFile.encode(next).write(to:target,options:.atomic)
            project = next; saved = project; documentURL = target
            NSDocumentController.shared.noteNewRecentDocumentURL(target); registry.record(target)
            status = "Saved \(target.lastPathComponent)"; return true
        } catch { report(error); return false }
    }
    /// Returning to the start screen keeps the current project loaded; choosing another one
    /// from there goes through openProject, which asks before discarding unsaved changes.
    func showStartScreen() {
        commitPendingEdits()
        guard !isExporting, !isCapturingSnapshot else { return }
        pause(); selectedGap = nil; showLauncher = true; registry.refresh()
    }
    /// True when there is something worth returning to from the start screen.
    var hasOpenWork: Bool { documentURL != nil || !project.clips.isEmpty || !project.media.isEmpty }
    func resumeEditing() { if hasOpenWork { showLauncher = false } }
    func openFromLauncher(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if let current = documentURL, ProjectHistory.normalized(current.path) == ProjectHistory.normalized(path) { showLauncher = false; return }
        openProject(url)
        if showLauncher { registry.refresh() }   // failed: the card re-reads and shows why
    }
    /// Collects every .framestudio inside the chosen folders (or the chosen files) into the list.
    /// The user picks the folder, so no protected location is ever read without consent.
    func addProjectsFromFolder() {
        let panel = NSOpenPanel(); panel.title = "Add projects"
        panel.message = "Choose folders or project files. Ara lists every .framestudio project it finds."
        panel.prompt = "Add Projects"
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(exportedAs:"com.framestudio.project",conformingTo:.json)]
        guard panel.runModal() == .OK else { return }
        addProjects(panel.urls)
    }
    func addProjects(_ urls: [URL]) {
        Task {
            let added = await registry.add(from:urls)
            if added == 0 { message = "No new .framestudio projects were found there." }
        }
    }
    func chooseOpen() {
        let panel = NSOpenPanel(); panel.title = "Open project"
        panel.allowedContentTypes = [UTType(exportedAs:"com.framestudio.project",conformingTo:.json),.json]
        if panel.runModal() == .OK, let url = panel.url { openProject(url) }
    }
    func openProject(_ url: URL) {
        commitPendingEdits()
        guard !isExporting, confirmDiscard() else { return }
        do {
            let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
            let loaded = try ProjectFile.decode(Data(contentsOf:url))
            resetSession(); project = loaded; documentURL = url; restoreAccess(); saved = project
            if missing.isEmpty { rebuild() } else { status = "\(missing.count) sources need relinking · Use Relink in the library" }
            NSDocumentController.shared.noteNewRecentDocumentURL(url); registry.record(url)
            showLauncher = false
        } catch { report(error) }
    }
    func chooseSnapshot() {
        commitPendingEdits()
        guard canCaptureSnapshot, let time = project.snapshotTime(at:playhead) else { return }
        pause(); seek(time)
        let snapshot = project, mediaURLs = urls
        let timecode = snapshot.frameRate.timecode(time)
        let panel = NSSavePanel(); panel.title = "Save timeline snapshot"; panel.allowedContentTypes = [.png]
        panel.message = "Current composed frame · \(timecode) · 1920 × 1080 PNG"
        panel.nameFieldStringValue = snapshot.name+"-"+timecode.replacingOccurrences(of:":",with:"-")+".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !mediaURLs.values.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() }) else {
            message = "Choose a different filename. A snapshot cannot replace source media."; return
        }
        let token = UUID(); snapshotID = token; isCapturingSnapshot = true
        status = "Saving snapshot at \(timecode)…"
        snapshotTask = Task { [self] in
            do {
                let bundle = try await builder.build(snapshot,urls:mediaURLs)
                try Task.checkCancellation()
                try await snapshotExporter.export(bundle,at:time,to:url)
                guard snapshotID == token else { return }
                isCapturingSnapshot = false; snapshotTask = nil; snapshotID = nil
                status = "Snapshot saved · \(url.lastPathComponent) · 1920 × 1080"
            } catch {
                guard snapshotID == token else { return }
                isCapturingSnapshot = false; snapshotTask = nil; snapshotID = nil
                if error is CancellationError { status = "Snapshot cancelled" } else { report(error) }
            }
        }
    }
    func chooseExport() {
        commitPendingEdits()
        guard !project.clips.isEmpty, !isExporting else { return }
        let panel = NSSavePanel(); panel.title = "Export H.264 / AAC MP4"; panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = project.name+".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !urls.values.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() }) else {
            message = "Choose a different output filename. Export cannot replace source media."; return
        }
        let snapshot = project, mediaURLs = urls, height = exportHeight
        pause(); isExporting = true; exportProgress = 0; status = "Preparing export…"
        exportTask = Task { [self] in
            do {
                let bundle = try await builder.build(snapshot,urls:mediaURLs,height:height)
                try await exporter.export(bundle,to:url) { [weak self] value in
                    await MainActor.run { self?.exportProgress = value }
                }
                status = "Exported \(url.lastPathComponent)"; isExporting = false
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                isExporting = false
                if error is CancellationError { status = "Export cancelled · Partial file removed" } else { report(error) }
            }
        }
    }
    func cancelExport() { exportTask?.cancel(); status = "Cancelling export…" }
}
