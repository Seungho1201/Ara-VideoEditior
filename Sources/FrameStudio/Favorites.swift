import SwiftUI
import AppKit
import FrameCore
import FrameMedia

/// A clip kept to use again, in this project or any other: a copy of it, of the sound a video
/// brought along, and of the source it plays (with its bookmark, so another project finds it).
struct FavoriteClip: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var clip: Clip
    /// A video's own sound, kept with it.
    var sound: Clip?
    var media: MediaReference?
    /// A still of the source for its card (JPEG), so it shows in any project.
    var thumbnail: Data?
    /// Its transitions, as a copy takes them: its fades, and a cut to a neighbour as a fade of the
    /// same kind on its side. Absent from favourites kept before they were kept.
    var transitions: [FrameCore.Transition]?
    /// The clip it was kept from: that clip's star shows it kept.
    var origin: UUID
    var name: String { clip.kind == .text ? clip.style.text : clip.name }
}

/// Where favourites are kept and how they travel: one JSON file beside the added fonts, and a
/// pasteboard type for a favourite dragged onto the timeline.
enum Favorites {
    static var file: URL { FontLibrary.folder.deletingLastPathComponent().appendingPathComponent("Favorites.json") }
    static let pasteboardType = NSPasteboard.PasteboardType("com.framestudio.favorite")
    static let prefix = "ara.favorite:"
    static func load(from url: URL) -> [FavoriteClip] {
        guard let data = try? Data(contentsOf:url) else { return [] }
        return (try? JSONDecoder().decode([FavoriteClip].self,from:data)) ?? []
    }
    static func save(_ favorites: [FavoriteClip], to url: URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(favorites).write(to:url,options:.atomic)
    }
    static func id(from pasteboard: NSPasteboard) -> UUID? {
        if let value = pasteboard.string(forType:pasteboardType) { return UUID(uuidString:value) }
        guard let text = pasteboard.string(forType:.string), text.hasPrefix(prefix) else { return nil }
        return UUID(uuidString:String(text.dropFirst(prefix.count)))
    }
    /// What a favourite shows while it is dragged, as a media card does: its card's picture (the
    /// title in its own font and colours, or the source's still) at 140 × 80, on solid ground so
    /// it reads over the timeline.
    @MainActor static func dragPicture(_ favorite: FavoriteClip) -> NSImage {
        let card = ZStack { Theme.panel; FavoritePreview(favorite:favorite) }
            .frame(width:140,height:80).clipShape(RoundedRectangle(cornerRadius:6))
            .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(.white.opacity(0.18),lineWidth:1))
            .environment(\.colorScheme,.dark)
        let renderer = ImageRenderer(content:card)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage(size:NSSize(width:140,height:80))
    }
    /// A small JPEG of a source's still, for a favourite's card.
    static func jpeg(_ image: NSImage) -> Data? {
        guard let source = image.cgImage(forProposedRect:nil,context:nil,hints:nil), source.width > 0 else { return nil }
        let width = min(320,source.width), height = max(1,Int((Double(source.height)*Double(width)/Double(source.width)).rounded()))
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                                      bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
        return context.makeImage().flatMap { NSBitmapImageRep(cgImage:$0).representation(using:.jpeg,properties:[.compressionFactor:0.75]) }
    }
    /// `favorite` put on `lane` at `time`: a new clip, with its sound on the paired track, on this
    /// project's frames, playing `mediaID`. `media` is its source when the project lacks it.
    @discardableResult static func place(_ favorite: FavoriteClip, lane: Lane, at time: MediaTime, mediaID: UUID?, adding media: MediaReference?, in project: inout Project) throws -> UUID {
        guard lane.isVideo == (favorite.clip.kind != .audio) else { throw EditError("Drop video and images on a video track (V), and audio on an audio track (A).") }
        guard project.hasLane(lane) else { throw EditError("\(lane.rawValue) does not exist. Add a track first.") }
        if let media { project.media.append(media) }
        let rate = project.frameRate
        var clip = favorite.clip
        clip.id = UUID(); clip.lane = lane; clip.start = max(.zero,rate.quantize(time)); clip.mediaID = mediaID; clip.favoriteID = favorite.id
        // Whole frames of this project, never more of the source than was kept.
        clip.duration = max(rate.frame,rate.floor(clip.duration)); clip.retimedSourceLength = nil
        let link: UUID? = favorite.sound == nil ? nil : UUID()
        clip.linkID = link
        project.clips.append(clip)
        if var sound = favorite.sound {
            try project.ensureLane(lane.paired)
            sound.id = UUID(); sound.lane = lane.paired; sound.mediaID = mediaID; sound.linkID = link; sound.retimedSourceLength = nil; sound.favoriteID = favorite.id
            sound.start = clip.start; sound.duration = clip.duration; sound.sourceStart = clip.sourceStart; sound.speed = clip.speed
            project.clips.append(sound)
        }
        // Its transitions on the new clip, on this project's frames; validation fits their lengths.
        for original in favorite.transitions ?? [] {
            var transition = original; transition.id = UUID()
            func placed(_ id: UUID?) -> UUID? { id == favorite.clip.id ? clip.id : nil }
            transition.from = placed(original.from); transition.to = placed(original.to)
            guard transition.from != nil || transition.to != nil else { continue }
            transition.duration = max(rate.frame,rate.quantize(original.duration))
            project.transitions.append(transition)
        }
        return clip.id
    }
}

/// The favourite clips, newest first, as cards to drag onto the timeline; each can be let go.
struct FavoritesPanel: View {
    @ObservedObject var store: EditorStore
    @State private var hovered: UUID?
    @State private var hoveredTrash: UUID?
    /// A favourite's length on its card: minutes and seconds.
    static func length(_ duration: MediaTime) -> String {
        let seconds = max(0,Int(duration.seconds.rounded(.down)))
        return String(format:"%02d:%02d",seconds/60,seconds%60)
    }
    private let columns = [GridItem(.flexible(),spacing:10),GridItem(.flexible(),spacing:10)]
    var body: some View {
        if store.favorites.isEmpty {
            VStack(spacing:10) {
                Image(systemName:"star").font(.system(size:24,weight:.light))
                Text("No favourite clips yet").font(.system(size:12,weight:.medium))
                Text("Select a clip and click ☆ beside its name in the inspector to keep it here.")
                    .font(.system(size:11)).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
            }
            .foregroundStyle(Theme.muted).padding(24).frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    Text("Drag a clip onto the timeline. It comes with its look and transitions, and a video with its sound.")
                        .font(.system(size:11)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                    LazyVGrid(columns:columns,spacing:12) {
                        ForEach(store.favorites) { favorite in card(favorite) }
                    }
                }.padding(14)
            }
        }
    }
    private func card(_ favorite: FavoriteClip) -> some View {
        VStack(alignment:.leading,spacing:5) {
            FavoritePreview(favorite:favorite)
                .aspectRatio(16/9,contentMode:.fit)
                .clipShape(RoundedRectangle(cornerRadius:4))
                .overlay(RoundedRectangle(cornerRadius:4).stroke(hovered == favorite.id ? Theme.accent : .white.opacity(0.12),lineWidth:1))
            Text(verbatim:favorite.name).font(.system(size:10,weight:.medium)).lineLimit(1)
            HStack(spacing:4) {
                Image(systemName:favorite.clip.kind == .text ? "textformat" : favorite.clip.kind == .audio ? "waveform" : favorite.clip.kind == .image ? "photo" : "film")
                Text(verbatim:Self.length(favorite.clip.duration))
                if favorite.sound != nil { Image(systemName:"speaker.wave.2.fill") }
                if !(favorite.transitions ?? []).isEmpty { Image(systemName:"square.on.square").help("Keeps its transitions") }
                Spacer(minLength:22)                  // the room of the trash button laid over this line
            }.font(.system(size:9)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { inside in if inside { hovered = favorite.id } else if hovered == favorite.id { hovered = nil } }
        // AppKit owns the mouse, as for transitions and media: the drag carries the favourite.
        .overlay { FavoriteDragHandle(favorite:favorite,remove:{ store.removeFavorite(favorite.id) }).accessibilityHidden(true) }
        // Over the drag handle, so it takes its own clicks: at the end of the length's line.
        .overlay(alignment:.bottomTrailing) {
            Button { store.removeFavorite(favorite.id) } label: {
                Image(systemName:"trash").font(.system(size:10,weight:.medium))
                    .foregroundStyle(hoveredTrash == favorite.id ? Color.red.opacity(0.9) : Theme.muted)
                    .frame(width:20,height:18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).offset(y:4)          // level with the length's text
            .onHover { inside in hoveredTrash = inside ? favorite.id : (hoveredTrash == favorite.id ? nil : hoveredTrash) }
            .help("Remove from Favourites")
            .accessibilityLabel(Text("Remove \(favorite.name) from Favourites"))
        }
        .help("Drag onto the timeline")
        .accessibilityElement(children:.combine)
        .accessibilityLabel(Text("Favourite: \(favorite.name)"))
        .accessibilityAction(named:Text("Remove from Favourites")) { store.removeFavorite(favorite.id) }
    }
}

/// A favourite's card picture: its source's still, or a title set in its own font and colours.
struct FavoritePreview: View {
    let favorite: FavoriteClip
    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            if favorite.clip.kind == .text {
                let style = favorite.clip.style
                Text(verbatim:style.text).font(.custom(style.fontName,size:15)).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.5)
                    .foregroundStyle(Color(red:style.red,green:style.green,blue:style.blue))
                    .shadow(color:style.hasOutline ? Color(red:style.outlineRed,green:style.outlineGreen,blue:style.outlineBlue) : .clear,radius:0.8)
                    .padding(6)
            } else if let data = favorite.thumbnail, let image = NSImage(data:data) {
                Image(nsImage:image).resizable().aspectRatio(contentMode:.fill)
            } else {
                Image(systemName:favorite.clip.kind == .audio ? "waveform" : "film").font(.system(size:20,weight:.light)).foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct FavoriteDragHandle: NSViewRepresentable {
    let favorite: FavoriteClip
    let remove: () -> Void
    func makeNSView(context: Context) -> FavoriteDragView { FavoriteDragView() }
    func updateNSView(_ view: FavoriteDragView, context: Context) { view.favorite = favorite; view.remove = remove }
}

/// Starts the drag of a favourite: its id rides on the pasteboard, readable by the timeline from
/// the first moment of the drag. A right-click offers to let the favourite go.
@MainActor private final class FavoriteDragView: NSView, NSDraggingSource {
    var favorite: FavoriteClip?
    var remove: (() -> Void)?
    private var origin = NSPoint.zero
    private var didDrag = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { origin = convert(event.locationInWindow,from:nil); didDrag = false }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        guard let favorite, !didDrag, hypot(point.x-origin.x,point.y-origin.y) > 4 else { return }
        didDrag = true
        let item = NSPasteboardItem()
        item.setString(favorite.id.uuidString,forType:Favorites.pasteboardType)
        item.setString(Favorites.prefix+favorite.id.uuidString,forType:.string)
        let drag = NSDraggingItem(pasteboardWriter:item)
        drag.setDraggingFrame(NSRect(x:point.x-70,y:point.y-40,width:140,height:80),contents:Favorites.dragPicture(favorite))
        beginDraggingSession(with:[drag],event:event,source:self)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title:String(localized:"Remove from Favourites"),action:#selector(removeFavorite),keyEquivalent:"")
        item.target = self; menu.addItem(item)
        return menu
    }
    @objc private func removeFavorite() { remove?() }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
