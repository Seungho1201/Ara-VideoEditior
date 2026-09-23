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
            let alert = NSAlert(); alert.messageText = "An output is being saved"
            alert.informativeText = store.isCapturingSnapshot ? "Wait for the snapshot to finish saving before quitting." : "Cancel the export before quitting."
            alert.runModal(); return .terminateCancel
        }
        return store.confirmDiscard() ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        approvedClose = store?.isExporting == false && store?.isCapturingSnapshot == false && (store?.confirmDiscard() ?? true)
        return approvedClose
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard store != nil else { pendingURLs.append(contentsOf:urls); return }
        if let url = urls.first(where: { $0.pathExtension == "framestudio" }) { store?.openProject(url) }
        else { store?.importFiles(urls) }
    }
}

@main struct AraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = EditorStore()
    @State private var launched = false
    var body: some Scene {
        WindowGroup("Ara", id:"editor") {
            EditorView(store:store)
                .frame(minWidth:1060,minHeight:760)
                .preferredColorScheme(.dark)
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
                Button("New Project") { store.newProject() }.keyboardShortcut("n")
                Button("Open Project…") { store.chooseOpen() }.keyboardShortcut("o")
                Button("Start Screen") { store.showStartScreen() }.keyboardShortcut("1",modifiers:[.command,.shift])
                    .disabled(store.showLauncher || store.isExporting || store.isCapturingSnapshot)
                Divider()
                // Everything below acts on the open project, which is hidden behind the start screen.
                Group {
                    Button("Save Project") { store.save() }.keyboardShortcut("s")
                    Button("Save Project As…") { store.save(as:true) }.keyboardShortcut("s",modifiers:[.command,.shift])
                    Divider()
                    Button("Import Media…") { store.chooseImport() }.keyboardShortcut("i")
                    Button("Export Movie…") { store.showExportSheet = true }.keyboardShortcut("e").disabled(store.project.clips.isEmpty || store.isExporting)
                    Button("Save Timeline Snapshot…") { store.chooseSnapshot() }.keyboardShortcut("e",modifiers:[.command,.shift]).disabled(!store.canCaptureSnapshot)
                }.disabled(store.showLauncher)
            }
            CommandGroup(replacing:.undoRedo) {
                Button("Undo \(store.undoName)") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo || store.showLauncher)
                Button("Redo \(store.history.redoName)") { store.redo() }.keyboardShortcut("z",modifiers:[.command,.shift]).disabled(!store.canRedo || store.showLauncher)
            }
            CommandMenu("Timeline") {
                // Unmodified keys (Space, arrows, Delete, N) must not reach a project the user cannot see,
                // and must not steal typing from the start screen's search field.
                Group {
                Button("Play / Pause") { store.togglePlayback() }.keyboardShortcut(.space,modifiers:[])
                // Arrow equivalents win over any focused text view, so they yield while a title is edited.
                Button("Previous Frame") { store.step(-1) }.keyboardShortcut(.leftArrow,modifiers:[]).disabled(store.isEditingText)
                Button("Next Frame") { store.step(1) }.keyboardShortcut(.rightArrow,modifiers:[]).disabled(store.isEditingText)
                Button("Go to Selected Clip Start") { store.goToSelectedClipStart() }.keyboardShortcut(.leftArrow,modifiers:[.option]).disabled(store.selectedClip == nil || store.isEditingText)
                Button("Go to Selected Clip End") { store.goToSelectedClipEnd() }.keyboardShortcut(.rightArrow,modifiers:[.option]).disabled(store.selectedClip == nil || store.isEditingText)
                Divider()
                Button("Split at Playhead") { store.split() }.keyboardShortcut("b").disabled(store.selectedClip == nil)
                Button("Delete Linked Selection") { store.deleteSelection() }.keyboardShortcut(.delete,modifiers:[]).disabled(store.selectedClip == nil)
                Button("Close Gap") { store.closeSelectedGap() }.keyboardShortcut(.delete,modifiers:[.command]).disabled(store.selectedGap == nil)
                Button("Add Text Clip") { store.addText() }.keyboardShortcut("t",modifiers:[.command,.shift])
                Toggle("Snapping",isOn:$store.snapping).keyboardShortcut("n",modifiers:[])
                }.disabled(store.showLauncher)
            }
        }
    }
}
