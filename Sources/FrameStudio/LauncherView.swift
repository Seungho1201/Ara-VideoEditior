import SwiftUI
import AppKit
import FrameCore

/// The start screen: every project the user has opened or saved, most recent first.
struct LauncherView: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var registry: ProjectRegistry
    @State private var selection: String?
    @State private var query = ""
    @State private var dropTargeted = false

    private var entries: [ProjectHistory.Entry] {
        let all = registry.history.entries
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return all }
        return all.filter { entry in
            if entry.path.localizedCaseInsensitiveContains(term) { return true }
            if case let .ready(summary, _)? = registry.status[entry.path] { return summary.name.localizedCaseInsensitiveContains(term) }
            return false
        }
    }
    private let columns = [GridItem(.adaptive(minimum:236,maximum:300),spacing:18,alignment:.top)]

    var body: some View {
        HStack(spacing:0) {
            sidebar.frame(width:300).background(Theme.panel)
            Rectangle().fill(.white.opacity(0.08)).frame(width:1)
            projects.frame(maxWidth:.infinity,maxHeight:.infinity)
                .background(dropTargeted ? Theme.accent.opacity(0.08) : Theme.background)
                .overlay { if dropTargeted { RoundedRectangle(cornerRadius:10).stroke(Theme.accent,style:StrokeStyle(lineWidth:2,dash:[7,5])).padding(10) } }
                .onDrop(of:[.fileURL],isTargeted:$dropTargeted) { providers in
                    Task { @MainActor in
                        var urls: [URL] = []
                        for provider in providers {
                            let url: URL? = await withCheckedContinuation { continuation in
                                _ = provider.loadObject(ofClass:URL.self) { url,_ in continuation.resume(returning:url) }
                            }
                            if let url { urls.append(url) }
                        }
                        store.addProjects(urls)
                    }
                    return true
                }
        }
        .onAppear { registry.refresh(); selection = selection ?? registry.history.entries.first?.path }
    }

    private var sidebar: some View {
        VStack(alignment:.leading,spacing:0) {
            Image(nsImage:NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high).aspectRatio(contentMode:.fit)
                .frame(width:84,height:84).accessibilityHidden(true)
                .padding(.bottom,14)
            Text("Ara").font(.system(size:28,weight:.bold)).tracking(1)
            Text("Local video editing on your Mac").font(.system(size:12)).foregroundStyle(Theme.muted).padding(.top,4)
            VStack(spacing:10) {
                // ⌘N and ⌘O come from the File menu, which stays live on this screen.
                launchButton("New Project",detail:"Start an empty timeline  ⌘N",icon:"plus.rectangle.on.rectangle",prominent:true) { store.newProject() }
                launchButton("Open…",detail:"Choose a .framestudio file  ⌘O",icon:"doc") { store.chooseOpen() }
                launchButton("Add Projects…",detail:"Collect projects from a folder",icon:"folder.badge.plus") { store.addProjectsFromFolder() }
                if store.hasOpenWork {
                    launchButton("Back to \(store.project.name)",detail:store.dirty ? "Unsaved changes" : "Continue editing",icon:"arrow.uturn.backward") { store.resumeEditing() }
                        .keyboardShortcut(.escape,modifiers:[])
                }
            }.padding(.top,34)
            Spacer()
            Text("Projects you open or save appear here. Drop project files or folders onto the list to add them.\nOriginal media files are never copied or changed.")
                .font(.system(size:10)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
        }.padding(28)
    }

    private func launchButton(_ title:String,detail:String,icon:String,prominent:Bool = false,action:@escaping () -> Void) -> some View {
        Button(action:action) {
            HStack(spacing:12) {
                Image(systemName:icon).font(.system(size:16,weight:.medium)).frame(width:24)
                VStack(alignment:.leading,spacing:2) {
                    Text(title).font(.system(size:13,weight:.semibold)).lineLimit(1)
                    Text(detail).font(.system(size:10)).opacity(0.7).lineLimit(1)
                }
                Spacer(minLength:0)
            }
            .padding(.horizontal,14).frame(height:50)
            .foregroundStyle(prominent ? Theme.background : Color.primary)
            .background(prominent ? Theme.accent : Theme.raised,in:RoundedRectangle(cornerRadius:8))
            .contentShape(RoundedRectangle(cornerRadius:8))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private var projects: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                panelTitle("PROJECTS")
                Text("\(registry.history.entries.count)").font(.system(size:10,design:.monospaced)).foregroundStyle(Theme.muted)
                Spacer()
                if !registry.history.entries.isEmpty {
                    HStack(spacing:6) {
                        Image(systemName:"magnifyingglass").foregroundStyle(Theme.muted)
                        TextField("Search",text:$query).textFieldStyle(.plain).frame(width:170)
                    }
                    .font(.system(size:12)).padding(.horizontal,10).frame(height:28)
                    .background(Theme.raised,in:RoundedRectangle(cornerRadius:6))
                }
            }.padding(.horizontal,28).frame(height:64)
            Divider()
            // Return opens the selected card (or the top match while searching).
            Button("") { openSelection() }.keyboardShortcut(.defaultAction)
                .opacity(0).frame(width:0,height:0).accessibilityHidden(true)
            if registry.history.entries.isEmpty { emptyState }
            else if entries.isEmpty {
                Text("No projects match “\(query)”").font(.system(size:12)).foregroundStyle(Theme.muted)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns:columns,spacing:18) {
                        ForEach(entries) { entry in card(entry) }
                    }.padding(28)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing:14) {
            Image(systemName:"film.stack").font(.system(size:40,weight:.ultraLight)).foregroundStyle(Theme.accent)
            Text("No projects yet").font(.system(size:16,weight:.medium))
            Text("Create a new project, open a .framestudio file, or drop a folder of projects here.\nEverything you open or save from now on is listed here.")
                .font(.system(size:12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }

    private func card(_ entry: ProjectHistory.Entry) -> some View {
        let status = registry.status[entry.path]
        let selected = selection == entry.path
        let openable: Bool = { if case .ready? = status { return true }; return false }()
        return VStack(alignment:.leading,spacing:0) {
            ZStack {
                Rectangle().fill(.black.opacity(0.4))
                if let poster = registry.posters[entry.path] {
                    Image(nsImage:poster).resizable().aspectRatio(contentMode:.fill)
                } else {
                    Image(systemName:placeholderIcon(status)).font(.system(size:30,weight:.ultraLight)).foregroundStyle(Theme.muted)
                }
                if case let .ready(summary, _)? = status {
                    VStack { Spacer(); HStack {
                        Text("\(summary.frameRate.label) FPS").font(.system(size:8,weight:.bold)).tracking(1)
                        Spacer()
                        Text(summary.frameRate.timecode(summary.duration)).font(.system(size:9,design:.monospaced))
                    }.padding(6).background(.black.opacity(0.7)) }
                }
            }
            .frame(height:132).clipped()
            VStack(alignment:.leading,spacing:5) {
                Text(title(entry,status)).font(.system(size:13,weight:.semibold)).lineLimit(1)
                Text(detail(status)).font(.system(size:10)).foregroundStyle(detailColor(status)).lineLimit(1)
                Text(location(entry.path)).font(.system(size:9)).foregroundStyle(Theme.muted.opacity(0.8)).lineLimit(1).truncationMode(.middle)
            }.padding(12)
        }
        .background(selected ? Theme.accent.opacity(0.1) : Theme.raised.opacity(0.55),in:RoundedRectangle(cornerRadius:9))
        .overlay(RoundedRectangle(cornerRadius:9).stroke(selected ? Theme.accent.opacity(0.85) : .white.opacity(0.06),lineWidth:selected ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius:9))
        .opacity(openable || status == nil || isLoading(status) ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius:9))
        .onTapGesture(count:2) { if openable { store.openFromLauncher(entry.path) } }
        .onTapGesture { selection = entry.path }
        .contextMenu {
            Button("Open") { store.openFromLauncher(entry.path) }.disabled(!openable)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:entry.path)]) }
                .disabled(!FileManager.default.fileExists(atPath:entry.path))
            Divider()
            Button("Remove from List") { registry.remove(entry.path); if selection == entry.path { selection = nil } }
        }
        .accessibilityElement(children:.combine)
        .accessibilityLabel("\(title(entry,status)), \(detail(status))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if openable { store.openFromLauncher(entry.path) } }
    }

    private func openSelection() {
        let visible = entries
        guard let target = visible.first(where: { $0.path == selection }) ?? visible.first else { return }
        if case .ready? = registry.status[target.path] { store.openFromLauncher(target.path) }
    }
    private func isLoading(_ status: ProjectRegistry.Status?) -> Bool { if case .loading? = status { return true }; return false }
    private func placeholderIcon(_ status: ProjectRegistry.Status?) -> String {
        switch status {
        case .missing?: "questionmark.folder"
        case .unreadable?: "exclamationmark.triangle"
        default: "film"
        }
    }
    private func title(_ entry: ProjectHistory.Entry,_ status: ProjectRegistry.Status?) -> String {
        if case let .ready(summary, _)? = status { return summary.name }
        return URL(fileURLWithPath:entry.path).deletingPathExtension().lastPathComponent
    }
    private func detail(_ status: ProjectRegistry.Status?) -> String {
        switch status {
        case let .ready(summary, modified)?:
            let clips = summary.clipCount == 1 ? "1 clip" : "\(summary.clipCount) clips"
            guard let modified else { return clips }
            return "\(clips) · Edited \(modified.formatted(.relative(presentation:.named)))"
        case .missing?: return "File not found · Right-click to remove"
        case let .unreadable(message)?: return "Can’t open · \(message)"
        case .loading?, nil: return "Reading…"
        }
    }
    private func detailColor(_ status: ProjectRegistry.Status?) -> Color {
        switch status { case .missing?, .unreadable?: .orange; default: Theme.muted }
    }
    private func location(_ path: String) -> String {
        (URL(fileURLWithPath:path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}
