import SwiftUI
import FrameCore

struct ExportSettingsView: View {
    @ObservedObject var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    @State private var aspectRatio: VideoAspectRatio
    @State private var frameRate: FrameRate
    @State private var resolution: Int
    @State private var error: String?

    init(store: EditorStore) {
        self.store = store
        _aspectRatio = State(initialValue:store.project.aspectRatio)
        _frameRate = State(initialValue:store.project.frameRate)
        _resolution = State(initialValue:store.exportHeight)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Text("Export movie").font(.title2.weight(.semibold))
            Text("H.264 video · AAC stereo audio · SDR Rec.709").foregroundStyle(Theme.muted)
            Grid(alignment:.leading,horizontalSpacing:24,verticalSpacing:16) {
                GridRow {
                    Text("Aspect ratio")
                    Picker("Aspect ratio",selection:$aspectRatio) {
                        ForEach(VideoAspectRatio.allCases) { Text($0.name).tag($0) }
                    }.labelsHidden().frame(maxWidth:.infinity)
                }
                GridRow {
                    Text("Frame rate")
                    Picker("Frame rate",selection:$frameRate) {
                        ForEach(FrameRate.supported.sorted { $0.value < $1.value }) { Text("\($0.label) fps").tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Resolution")
                    Picker("Resolution",selection:$resolution) {
                        Text("Full HD · \(aspectRatio.dimensions())").tag(1080)
                        Text("4K · \(aspectRatio.dimensions(resolution:2160))").tag(2160)
                    }.labelsHidden()
                }
            }
            HStack(spacing:14) {
                ZStack {
                    RoundedRectangle(cornerRadius:3).fill(Theme.background)
                    RoundedRectangle(cornerRadius:2).stroke(Theme.accent,lineWidth:1.5)
                        .aspectRatio(aspectRatio.value,contentMode:.fit).padding(5)
                }.frame(width:54,height:54)
                VStack(alignment:.leading,spacing:5) {
                    Text("\(aspectRatio.dimensions(resolution:resolution)) · \(frameRate.label) fps")
                        .font(.system(size:12,weight:.medium,design:.monospaced))
                    Text("SDR Rec.709 · Non-drop timecode").font(.system(size:11)).foregroundStyle(Theme.muted)
                }
            }
            Text("Aspect ratio and frame rate also apply to the project preview and snapshots. Use Apply to update the project without exporting. Changes can be undone.")
                .font(.system(size:11)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
            if store.project.clips.isEmpty {
                Text("Add a clip to the timeline to export a movie.").font(.system(size:11)).foregroundStyle(Theme.muted)
            }
            if let error { Text(error).font(.system(size:11)).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") {
                    do {
                        try store.setVideoSettings(aspectRatio:aspectRatio,frameRate:frameRate,resolution:resolution)
                        dismiss()
                    }
                    catch { self.error = error.localizedDescription }
                }
                Button("Choose destination…") {
                    do {
                        store.commitPendingEdits()
                        var candidate = store.project
                        try Editing.setVideoSettings(aspectRatio:aspectRatio,frameRate:frameRate,resolution:resolution,in:&candidate)
                        let session = store.session
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
                            guard store.session == session else { return }
                            store.chooseExport(aspectRatio:aspectRatio,frameRate:frameRate,height:resolution)
                        }
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(store.project.clips.isEmpty)
            }
        }.padding(28).frame(width:470).background(Theme.panel).tint(Theme.accent)
            .onChange(of:aspectRatio) { error = nil }
            .onChange(of:frameRate) { error = nil }
    }
}
