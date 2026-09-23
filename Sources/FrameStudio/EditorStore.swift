import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import UniformTypeIdentifiers
import FrameCore
import FrameMedia

@MainActor final class EditorStore: ObservableObject {
    @Published private(set) var project = Project()
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
    private var periodic: Any?
    private var itemObservation: NSKeyValueObservation?
    let player = AVPlayer()
    var dirty: Bool { project != saved }
    var selectedClip: Clip? { project.clips.first { $0.id == selectedClipID } }
    var selectedMedia: MediaReference? { project.media.first { $0.id == selectedMediaID } }
    var canUndo: Bool { history.canUndo }
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
        periodic = player.addPeriodicTimeObserver(forInterval:CMTime(value:1,timescale:30),queue:.main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if !self.seeking && !self.isBuilding && self.player.rate > 0 { self.playhead = min(self.project.duration,self.project.frameRate.quantize(MediaTime(time))) }
                self.isPlaying = self.player.rate > 0
            }
        }
    }
    func report(_ error: Error) { if !(error is CancellationError) { message = error.localizedDescription; status = "Action could not be completed" } }
    @discardableResult func edit(_ name: String, _ operation: (inout Project) throws -> Void) -> Bool {
        do {
            var next = project; try operation(&next); _ = try next.validated()
            guard next != project else { return true }
            if interactionStart == nil { history.record(project,name:name) }
            // Any timeline change can move the edges a gap selection was measured from.
            project = next; selectedGap = nil; rebuild(); return true
        } catch { report(error); return false }
    }
    func beginInteraction() { if interactionStart == nil { interactionStart = project } }
    func endInteraction() {
        if let before = interactionStart, before != project { history.record(before,name:"Adjust clip") }
        interactionStart = nil; objectWillChange.send()
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
    func previewSourceSize(for clip: Clip) -> CGSize? {
        if let instruction = player.currentItem?.videoComposition?.instructions.first as? FrameInstruction,
           let image = instruction.layers.first(where: { $0.clip.id == clip.id })?.image {
            return image.extent.size
        }
        guard let media = project.media(for:clip), media.width > 0, media.height > 0 else { return nil }
        return CGSize(width:media.width,height:media.height)
    }
    func undo() { endInteraction(); selectedGap = nil; if let previous = history.undo(project) { project = previous; restoreAccess(); rebuild() } }
    func redo() { endInteraction(); selectedGap = nil; if let next = history.redo(project) { project = next; restoreAccess(); rebuild() } }
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
    func seek(_ time: MediaTime) {
        let target = project.frameRate.quantize(min(max(.zero,time),project.duration))
        playhead = target; seekRevision += 1; let token = seekRevision; seeking = true
        player.currentItem?.cancelPendingSeeks()
        player.seek(to:target.cmTime,toleranceBefore:.zero,toleranceAfter:.zero) { [weak self] _ in
            Task { @MainActor in if let self, self.seekRevision == token { self.seeking = false } }
        }
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
    func pause() { player.pause(); isPlaying = false }
    func togglePlayback() {
        guard !isBuilding, player.currentItem != nil else { return }
        if isPlaying { pause() }
        else { previewTransformID = nil; if playhead >= project.duration { seek(.zero) }; player.play(); isPlaying = true }
    }
    private func rebuild() {
        revision += 1; let token = revision
        rebuildTask?.cancel(); let resume = isPlaying; pause()
        playhead = min(playhead,project.duration)
        guard !project.clips.isEmpty else { player.replaceCurrentItem(with:nil); isBuilding = false; return }
        guard missing.isEmpty else {
            player.replaceCurrentItem(with:nil); isBuilding = false
            status = "\(missing.count) missing files · Use Relink in the library"; return
        }
        let snapshot = project, mediaURLs = urls
        isBuilding = true
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for:.milliseconds(140))
                let bundle = try await builder.build(snapshot,urls:mediaURLs)
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
                if resume { player.play(); isPlaying = true }
                status = "\(project.clips.filter { $0.kind != .audio || $0.linkID == nil }.count) clips · SDR Rec.709"
            } catch {
                guard revision == token else { return }; isBuilding = false
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
                    history.record(project,name:"Import media"); project.media.append(media); urls[media.id] = url; selectedMediaID = media.id
                    analyze(media,url:url)
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
                    urls[media.id] = url; missing.remove(media.id); analyze(replacement,url:url); rebuild()
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
        previewTransformID = nil
        pause(); revision += 1; rebuildTask?.cancel(); importTask?.cancel(); isBuilding = false; isImporting = false
        snapshotTask?.cancel(); snapshotTask = nil; snapshotID = nil; isCapturingSnapshot = false
        for task in analysisTasks.values { task.cancel() }; analysisTasks.removeAll()
        player.replaceCurrentItem(with:nil); history = EditHistory(); playhead = .zero
        selectedClipID = nil; selectedGap = nil; selectedMediaID = nil; thumbnails.removeAll(); waveforms.removeAll(); urls.removeAll(); missing.removeAll()
        // Keep security scopes until app termination: an in-flight cancelled reader may still own a buffer.
    }
    func newProject() {
        guard !isExporting, confirmDiscard() else { return }
        resetSession(); project = Project(); saved = project; documentURL = nil; status = "New project · Choose a frame rate, then import media"
    }
    @discardableResult func save(as: Bool = false) -> Bool {
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
            NSDocumentController.shared.noteNewRecentDocumentURL(target)
            status = "Saved \(target.lastPathComponent)"; return true
        } catch { report(error); return false }
    }
    func chooseOpen() {
        let panel = NSOpenPanel(); panel.title = "Open project"
        panel.allowedContentTypes = [UTType(exportedAs:"com.framestudio.project",conformingTo:.json),.json]
        if panel.runModal() == .OK, let url = panel.url { openProject(url) }
    }
    func openProject(_ url: URL) {
        guard !isExporting, confirmDiscard() else { return }
        do {
            let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
            let loaded = try ProjectFile.decode(Data(contentsOf:url))
            resetSession(); project = loaded; documentURL = url; restoreAccess(); saved = project
            if missing.isEmpty { rebuild() } else { status = "\(missing.count) sources need relinking · Use Relink in the library" }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch { report(error) }
    }
    func chooseSnapshot() {
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
