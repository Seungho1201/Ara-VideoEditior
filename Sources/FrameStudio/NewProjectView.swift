import SwiftUI
import FrameCore

struct NewProjectView: View {
    @ObservedObject var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = "Untitled"
    @State private var resolution = 1080
    @State private var aspectRatio = VideoAspectRatio.landscape
    @State private var frameRate = FrameRate(30)
    @State private var error: String?

    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Text("New project").font(.title2.weight(.semibold))
            Text("Give your project a name and choose its video format.")
                .font(.system(size:12)).foregroundStyle(Theme.muted)
            Grid(alignment:.leading,horizontalSpacing:24,verticalSpacing:16) {
                GridRow {
                    Text("Name")
                    TextField("Project name",text:$name).textFieldStyle(.roundedBorder)
                        .focused($nameFocused).accessibilityLabel("Project name")
                }
                GridRow {
                    Text("Quality")
                    Picker("Quality",selection:$resolution) {
                        ForEach(OutputQuality.allCases) { quality in
                            Text(verbatim:"\(quality.name) · \(aspectRatio.dimensions(resolution:quality.rawValue))").tag(quality.rawValue)
                        }
                    }.labelsHidden().frame(maxWidth:.infinity)
                }
                GridRow {
                    Text("Aspect ratio")
                    Picker("Aspect ratio",selection:$aspectRatio) {
                        ForEach(VideoAspectRatio.allCases) { Text(LocalizedStringKey($0.name)).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Frame rate")
                    Picker("Frame rate",selection:$frameRate) {
                        ForEach(FrameRate.supported.sorted { $0.value < $1.value }) { Text("\($0.label) fps").tag($0) }
                    }.labelsHidden()
                }
            }
            HStack(spacing:14) {
                ZStack {
                    RoundedRectangle(cornerRadius:3).fill(Theme.background)
                    RoundedRectangle(cornerRadius:2).stroke(Theme.accent,lineWidth:1.5)
                        .aspectRatio(aspectRatio.value,contentMode:.fit).padding(5)
                }.frame(width:54,height:54).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:5) {
                    Text("\(aspectRatio.dimensions(resolution:resolution)) · \(frameRate.label) fps")
                        .font(.system(size:12,weight:.medium,design:.monospaced))
                    Text("SDR Rec.709").font(.system(size:11)).foregroundStyle(Theme.muted)
                }
            }
            Text("Video settings can be changed later in Export.")
                .font(.system(size:11)).foregroundStyle(Theme.muted)
            if let error { Text(error).font(.system(size:11)).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create Project") {
                    do {
                        if try store.createProject(name:name,aspectRatio:aspectRatio,frameRate:frameRate,resolution:resolution) { dismiss() }
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width:470).background(Theme.panel).tint(Theme.accent)
            .onAppear { nameFocused = true }
            .onChange(of:name) { error = nil }
    }
}
