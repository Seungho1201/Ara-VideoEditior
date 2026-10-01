import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var store: EditorStore?
    private var pendingURLs: [URL] = []
    private var approvedClose = false
    func attach(_ editor: EditorStore) {
        store = editor
        if !pendingURLs.isEmpty { let urls = pendingURLs; pendingURLs.removeAll(); application(NSApplication.shared,open:urls) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if approvedClose && !sender.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { return .terminateNow }
        guard let store else { return .terminateNow }
        if store.isExporting || store.isCapturingSnapshot {
            let alert = NSAlert(); alert.messageText = String(localized:"An output is being saved")
            alert.informativeText = store.isCapturingSnapshot ? String(localized:"Wait for the snapshot to finish saving before quitting.") : String(localized:"Cancel the export before quitting.")
            alert.runModal(); return .terminateCancel
        }
        return store.confirmDiscard() ? .terminateNow : .terminateCancel
    }
    /// Set while quitting to start Ara again (a language change); cleared if the quit is cancelled.
    static var relaunchOnQuit = false
    func applicationWillTerminate(_ notification: Notification) {
        guard Self.relaunchOnQuit else { return }
        // A helper waits for this copy to exit, then opens the app again.
        let task = Process()
        task.executableURL = URL(fileURLWithPath:"/bin/sh")
        task.arguments = ["-c","while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",Bundle.main.bundlePath]
        try? task.run()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        approvedClose = store?.isExporting == false && store?.isCapturingSnapshot == false && (store?.confirmDiscard() ?? true)
        return approvedClose
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let store else { pendingURLs.append(contentsOf:urls); return }
        // Fonts go to the font library; a project opens, and media opened with it go into it.
        store.importFiles(urls)
    }
    /// Sources moved or deleted in Finder while Ara was in the background are found again (or
    /// marked missing) now, not when the next edit fails.
    func applicationDidBecomeActive(_ notification: Notification) { store?.refreshSources() }
}

@main struct AraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = EditorStore()
    @StateObject private var shortcuts = ShortcutSettings.shared
    @State private var launched = false
    var body: some Scene {
        WindowGroup("Ara", id:"editor") {
            EditorView(store:store)
                .frame(minWidth:1060,minHeight:760)
                .preferredColorScheme(.dark)
                // Keep the native title and window controls over the editor's panel colour.
                .containerBackground(Theme.panel,for:.window)
                .toolbarBackgroundVisibility(.hidden,for:.windowToolbar)
                .onAppear {
                    delegate.attach(store)
                    if let window = NSApplication.shared.windows.first { window.delegate = delegate; window.title = "Ara" }
                    if !launched {
                        launched = true
                        let args = CommandLine.arguments
                        if let i = args.firstIndex(of:"--project"), args.indices.contains(i+1) { store.openProject(URL(fileURLWithPath:args[i+1])) }
                        else if let i = args.firstIndex(of:"--import"), args.indices.contains(i+1) { store.importFiles(args[(i+1)...].map { URL(fileURLWithPath:$0) }) }
                    }
                }
        }
        .defaultSize(width:1440,height:920)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing:.newItem) {
                // Off while a sheet is up; during an export they say why they wait instead.
                Button("New Project") { store.newProject() }.keyboardShortcut(shortcuts.keyboardShortcut(.newProject)).disabled(store.showNewProjectSheet || store.showExportSheet)
                Button("Open Project…") { store.chooseOpen() }.keyboardShortcut(shortcuts.keyboardShortcut(.openProject)).disabled(store.showNewProjectSheet || store.showExportSheet)
                Button("Start Screen") { store.showStartScreen() }.keyboardShortcut(shortcuts.keyboardShortcut(.startScreen))
                    .disabled(store.showLauncher || store.showNewProjectSheet || store.isExporting || store.isCapturingSnapshot)
                Divider()
                // Everything below acts on the open project, which is hidden behind the start screen.
                Group {
                    Button("Save Project") { store.save() }.keyboardShortcut(shortcuts.keyboardShortcut(.save))
                    Button("Save Project As…") { store.save(as:true) }.keyboardShortcut(shortcuts.keyboardShortcut(.saveAs))
                    Divider()
                    Button("Import Media…") { store.chooseImport() }.keyboardShortcut(shortcuts.keyboardShortcut(.importMedia)).disabled(store.editingSuspended)
                    Button("Add Fonts…") { store.chooseFonts() }.disabled(store.isAddingFonts)
                    Button("Export Movie…") { store.showExportSheet = true }.keyboardShortcut(shortcuts.keyboardShortcut(.exportMovie)).disabled(store.isExporting || store.isCapturingSnapshot)
                    Button("Save Timeline Snapshot…") { store.chooseSnapshot() }.keyboardShortcut(shortcuts.keyboardShortcut(.snapshot)).disabled(!store.canCaptureSnapshot)
                }.disabled(store.showLauncher || store.showNewProjectSheet)
            }
            CommandGroup(replacing:.undoRedo) {
                Button("Undo \(EditorStore.localizedAction(store.undoName))") { store.undo() }.keyboardShortcut(shortcuts.keyboardShortcut(.undo)).disabled(!store.canUndo || store.editingSuspended)
                Button("Redo \(EditorStore.localizedAction(store.history.redoName))") { store.redo() }.keyboardShortcut(shortcuts.keyboardShortcut(.redo)).disabled(!store.canRedo || store.editingSuspended)
            }
            CommandGroup(before:.help) {
                Button("Show Tips") { store.showHelp.toggle() }.disabled(store.showLauncher || store.showNewProjectSheet)
            }
            CommandMenu("Timeline") {
                // Unmodified keys (Space, arrows, Delete, N) must not reach a project the user cannot see
                // (the start screen, a sheet, an export) or is reading tips over, and must not steal
                // typing from the start screen's search field.
                Group {
                Button("Play / Pause") { store.togglePlayback() }.keyboardShortcut(shortcuts.keyboardShortcut(.playPause))
                // Arrow equivalents win over any focused text view, so they yield while a title is edited.
                // With a clip's outline up an arrow key moves the clip instead (EditorStore.nudge).
                Button("Previous Frame") { if !store.nudge(NSApp.currentEvent) { store.step(-1) } }.keyboardShortcut(shortcuts.keyboardShortcut(.previousFrame)).disabled(store.isEditingText)
                Button("Next Frame") { if !store.nudge(NSApp.currentEvent) { store.step(1) } }.keyboardShortcut(shortcuts.keyboardShortcut(.nextFrame)).disabled(store.isEditingText)
                Button("Go to Selected Clip Start") { store.goToSelectedClipStart() }.keyboardShortcut(shortcuts.keyboardShortcut(.clipStart)).disabled(store.selectedClip == nil || store.isEditingText)
                Button("Go to Selected Clip End") { store.goToSelectedClipEnd() }.keyboardShortcut(shortcuts.keyboardShortcut(.clipEnd)).disabled(store.selectedClip == nil || store.isEditingText)
                Divider()
                Button("Split at Playhead") { store.split() }.keyboardShortcut(shortcuts.keyboardShortcut(.split)).disabled(store.selectedClip == nil)
                Button("Delete Linked Selection") { store.deleteSelection() }.keyboardShortcut(shortcuts.keyboardShortcut(.delete)).disabled(!store.canDeleteSelection)
                Button("Close Gap") { store.closeSelectedGap() }.keyboardShortcut(shortcuts.keyboardShortcut(.closeGap)).disabled(store.selectedGap == nil)
                Button("Add Text Clip") { store.addText() }.keyboardShortcut(shortcuts.keyboardShortcut(.addText))
                Toggle("Snapping",isOn:$store.snapping).keyboardShortcut(shortcuts.keyboardShortcut(.snapping))
                Toggle("Trackpad Haptics",isOn:$store.scrubHaptics)
                }.disabled(store.editingSuspended)
            }
        }
        Settings {
            SettingsView(store:store)
        }
    }
}
