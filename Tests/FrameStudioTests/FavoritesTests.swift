import AppKit
import XCTest
import FrameCore
@testable import FrameStudio

/// A favourite clip dragged in: the favourite's id on a pasteboard of its own.
@MainActor private final class FavoriteDropInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingDestinationWindow: NSWindow?
    var draggingLocation = NSPoint.zero
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    /// Carrying `id`, as a card of the favourites panel does.
    func carry(_ id: UUID) {
        draggingPasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(id.uuidString,forType:Favorites.pasteboardType); item.setString(Favorites.prefix+id.uuidString,forType:.string)
        draggingPasteboard.writeObjects([item])
    }
}

/// Clips kept in the favourites: kept and let go from the inspector's star, read by any project,
/// and dragged onto a timeline with their look, their sound and their source.
@MainActor final class FavoritesTests: XCTestCase {
    private var file: URL!
    override func setUp() { file = FileManager.default.temporaryDirectory.appendingPathComponent("ara-favorites-\(UUID().uuidString).json") }
    override func tearDown() { try? FileManager.default.removeItem(at:file) }
    private func title(_ text: String, _ lane: Lane, _ start: Double, _ length: Double) -> Clip {
        var clip = Clip(name:"T",kind:.text,lane:lane,start:.init(seconds:start),duration:.init(seconds:length))
        clip.style.text = text; clip.style.fontSize = 90; clip.style.red = 1; clip.style.green = 0.2; clip.style.blue = 0; clip.style.outlineWidth = 4
        return clip
    }

    func testAClipIsKeptAndEveryProjectReadsIt() throws {
        let video = timelineTestVideo()
        var ids: [String:UUID] = [:]
        let rig = TimelineRig { project in
            project.media = [video]
            ids["video"] = try Editing.add(mediaID:video.id,lane:.v1,at:.zero,to:&project)
            try Editing.trim(ids["video"]!,leading:false,to:.init(seconds:4),in:&project)
            let hello = self.title("Hello",.v2,1,3); ids["title"] = hello.id; project.clips.append(hello)
        }
        defer { rig.close() }
        let store = rig.store
        store.favoritesFile = file
        XCTAssertEqual(store.favorites,[])
        let still = NSImage(size:NSSize(width:64,height:36),flipped:false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        store.thumbnails[video.id] = still
        let hello = rig.clip(ids["title"]!), picture = rig.clip(ids["video"]!)
        let sound = try XCTUnwrap(store.project.group(for:picture.id).first { $0.kind == .audio })
        store.toggleFavorite(hello)
        XCTAssertTrue(store.isFavorite(hello)); XCTAssertFalse(store.isFavorite(picture))
        // The video's sound keeps the video, with the sound and the source.
        store.toggleFavorite(sound)
        XCTAssertTrue(store.isFavorite(picture)); XCTAssertTrue(store.isFavorite(sound))
        XCTAssertEqual(store.favorites.map(\.clip.kind),[.video,.text],"newest first")
        let kept = store.favorites[0]
        XCTAssertEqual(kept.clip.id,picture.id); XCTAssertEqual(kept.sound?.id,sound.id); XCTAssertEqual(kept.media?.path,video.path)
        XCTAssertNotNil(kept.thumbnail.flatMap(NSImage.init(data:)),"a still for its card")
        XCTAssertEqual(store.favorites[1].clip.style,hello.style)
        // Kept in the file: another project's store reads them.
        XCTAssertEqual(Favorites.load(from:file),store.favorites)
        let other = EditorStore(); other.favoritesFile = file
        XCTAssertEqual(other.favorites,store.favorites)
        // A second click lets it go, from the file too.
        store.toggleFavorite(hello)
        XCTAssertFalse(store.isFavorite(hello)); XCTAssertEqual(Favorites.load(from:file).map(\.clip.kind),[.video])
        store.removeFavorite(kept.id)
        XCTAssertEqual(Favorites.load(from:file),[])
        // A card gives its length in minutes and seconds.
        XCTAssertEqual(FavoritesPanel.length(.init(seconds:3.5)),"00:03"); XCTAssertEqual(FavoritesPanel.length(.init(seconds:75)),"01:15")
        XCTAssertEqual(FavoritesPanel.length(.init(seconds:0.4)),"00:00"); XCTAssertEqual(FavoritesPanel.length(.init(seconds:3661)),"61:01")
    }

    /// Dragged onto V2, a kept title lands where it is let go with its look and length, one undo
    /// step; over a clip it has no place; over V1's sound it goes onto V1's picture.
    func testAFavouriteDraggedOntoTheTimelineLandsWithItsLook() throws {
        var ids: [String:UUID] = [:]
        let rig = TimelineRig(width:1200) { project in
            let hello = self.title("Hello",.v2,1,3); ids["title"] = hello.id
            project.clips = [hello,self.title("Busy",.v1,0,4)]
        }
        defer { rig.close() }
        let store = rig.store
        store.favoritesFile = file; store.snapping = false
        store.resumeEditing()                                  // the editor, not the start screen, is in front
        store.toggleFavorite(rig.clip(ids["title"]!))
        let favorite = try XCTUnwrap(store.favorites.first)
        let info = FavoriteDropInfo(); info.draggingDestinationWindow = rig.window; info.carry(favorite.id)
        defer { info.draggingPasteboard.releaseGlobally() }
        func over(_ seconds: Double, _ lane: Lane, offset: Double = 20) { info.draggingLocation = rig.canvas.convert(NSPoint(x:seconds*TimelineRig.pps,y:rig.y(lane,offset)),to:nil) }
        let before = store.project
        // Over Busy on V1: no room there.
        over(2,.v1); info.draggingSequenceNumber += 1
        XCTAssertEqual(rig.canvas.draggingEntered(info),[])
        XCTAssertFalse(rig.canvas.performDragOperation(info)); XCTAssertEqual(store.project,before)
        // On V2 at 6 s.
        over(6,.v2); info.draggingSequenceNumber += 1
        XCTAssertEqual(rig.canvas.draggingEntered(info),.copy)
        XCTAssertTrue(rig.canvas.performDragOperation(info))
        let added = try XCTUnwrap(store.project.clips.first { $0.lane == .v2 && $0.start == .init(seconds:6) })
        XCTAssertNotEqual(added.id,favorite.clip.id)
        XCTAssertEqual(added.style,favorite.clip.style); XCTAssertEqual(added.duration,favorite.clip.duration)
        XCTAssertEqual(store.selectedClipID,added.id); XCTAssertEqual(store.undoName,"Add favourite")
        // It says where it came from: kept in the document, and a star before its name on the timeline.
        XCTAssertEqual(added.favoriteID,favorite.id); XCTAssertNil(favorite.clip.favoriteID)
        let saved = try JSONDecoder().decode(Project.self,from:JSONEncoder().encode(store.project))
        XCTAssertEqual(saved.clips.first { $0.id == added.id }?.favoriteID,favorite.id)
        XCTAssertTrue(store.isFavorite(added),"its inspector star shows the favourite it came from")
        let painted = rig.paint(), top = rig.y(.v2,0)
        func yellow(_ x: Double) -> Bool { (Int(top)+5..<Int(top)+16).contains { y in let c = TimelineRig.color(painted,x,Double(y)); return c.red > 200 && c.green > 170 && c.blue < 80 } }
        XCTAssertTrue((Int(6*TimelineRig.pps)+7..<Int(6*TimelineRig.pps)+19).contains { yellow(Double($0)) },"a star before the name")
        XCTAssertFalse((Int(1*TimelineRig.pps)+7..<Int(1*TimelineRig.pps)+19).contains { yellow(Double($0)) },"none on the clip it was kept from")
        store.undo(); XCTAssertEqual(store.project,before)
        // Over V1's sound at 5 s (past Busy): onto V1's picture.
        over(5,.a1); info.draggingSequenceNumber += 1
        XCTAssertEqual(rig.canvas.draggingEntered(info),.copy)
        XCTAssertTrue(rig.canvas.performDragOperation(info))
        XCTAssertEqual(store.project.clips.first { $0.start == .init(seconds:5) }?.lane,.v1)
    }

    /// A kept video goes into a project of another frame rate with its sound in step under it and
    /// its source added; a project with that source (the same file) uses its own; a source that
    /// cannot be found keeps the favourite out and says so.
    func testAVideoFavouriteBringsItsSourceAndSound() throws {
        let source = MediaReference(name:"Source",path:"/nonexistent/ara-tests/Source.mov",kind:.video,duration:.init(seconds:20),
                                    width:1920,height:1080,frameRate:30,hasAudio:true)
        var kept = Project(); kept.frameRate = .init(30); kept.media = [source]
        let id = try Editing.add(mediaID:source.id,lane:.v1,at:.init(seconds:2),to:&kept)
        try Editing.trim(id,leading:true,to:.init(seconds:3),in:&kept)                // source from 1 s
        try Editing.trim(id,leading:false,to:.init(seconds:7),in:&kept)
        let picture = try XCTUnwrap(kept.clips.first { $0.id == id }), sound = try XCTUnwrap(kept.group(for:id).first { $0.kind == .audio })
        let favorite = FavoriteClip(clip:picture,sound:sound,media:source,origin:picture.id)

        var other = Project(); other.frameRate = .init(24)
        let placed = try Favorites.place(favorite,lane:.v1,at:.init(seconds:10),mediaID:source.id,adding:source,in:&other)
        other = try other.validated()
        XCTAssertEqual(other.media.map(\.path),[source.path])
        let video = try XCTUnwrap(other.clips.first { $0.id == placed }), audio = try XCTUnwrap(other.group(for:placed).first { $0.kind == .audio })
        XCTAssertEqual(video.start,.init(seconds:10)); XCTAssertEqual(video.sourceStart,picture.sourceStart); XCTAssertEqual(video.duration,.init(seconds:4))
        XCTAssertEqual(audio.lane,.a1); XCTAssertEqual(audio.start,video.start); XCTAssertEqual(audio.duration,video.duration); XCTAssertEqual(audio.linkID,video.linkID)
        XCTAssertNotNil(video.linkID); XCTAssertNotEqual(video.linkID,picture.linkID)

        // Through the store: a project with the same file (under another id) plays its own.
        let rig = TimelineRig { project in
            var same = source; same.id = UUID(); project.media = [same]
        }
        defer { rig.close() }
        rig.store.favoritesFile = file
        try Favorites.save([favorite],to:file); rig.store.favoritesFile = file
        XCTAssertTrue(rig.store.placeFavorite(favorite.id,lane:.v1,at:.init(seconds:1)))
        XCTAssertEqual(rig.store.project.media.count,1)
        XCTAssertEqual(Set(rig.store.project.clips.compactMap(\.mediaID)),[rig.store.project.media[0].id])
        // One without that file, and no way to find it: kept out, and said why.
        let lost = TimelineRig { _ in }
        defer { lost.close() }
        lost.store.favoritesFile = file
        let before = lost.store.project
        XCTAssertFalse(lost.store.placeFavorite(favorite.id,lane:.v1,at:.zero))
        XCTAssertEqual(lost.store.project,before)
        XCTAssertTrue(lost.store.message?.contains("Source") == true,lost.store.message ?? "")
        lost.store.message = nil
    }

    /// A kept clip keeps its transitions as a copy does: its fade in as it is, and the dissolve into
    /// its neighbour as a dissolve fading it out, the part of it inside the clip. Placed, they are on
    /// the new clip, in one undo step with it. A favourite kept before this loads without any.
    func testAFavouriteKeepsItsTransitions() throws {
        var ids: [String:UUID] = [:]
        let rig = TimelineRig(width:1400) { project in
            let a = self.title("Hello",.v2,1,3), b = self.title("Next",.v2,4,3)
            ids["a"] = a.id; project.clips = [a,b]
            _ = try Editing.setTransition(.dipToBlack,duration:.init(seconds:1),from:nil,to:a.id,in:&project)
            _ = try Editing.setTransition(.crossDissolve,duration:.init(seconds:1),from:a.id,to:b.id,in:&project)
        }
        defer { rig.close() }
        let store = rig.store
        store.favoritesFile = file
        store.toggleFavorite(rig.clip(ids["a"]!))
        let favorite = try XCTUnwrap(store.favorites.first), kept = favorite.transitions ?? []
        XCTAssertEqual(kept.count,2)
        let fadeIn = kept.first { $0.from == nil && $0.to == favorite.clip.id }, fadeOut = kept.first { $0.from == favorite.clip.id && $0.to == nil }
        XCTAssertEqual(fadeIn?.kind,.dipToBlack); XCTAssertEqual(fadeIn?.duration,.init(seconds:1))
        XCTAssertEqual(fadeOut?.kind,.crossDissolve); XCTAssertEqual(fadeOut?.duration,.init(seconds:0.5),"the half inside the clip")
        XCTAssertEqual(Favorites.load(from:file).first?.transitions,kept,"kept in the file")

        let before = store.project
        XCTAssertTrue(store.placeFavorite(favorite.id,lane:.v1,at:.init(seconds:9)))
        let added = try XCTUnwrap(store.project.clips.first { $0.lane == .v1 && $0.start == .init(seconds:9) })
        let placed = store.project.transitions.filter { $0.from == added.id || $0.to == added.id }
        XCTAssertEqual(placed.first { $0.to == added.id }?.kind,.dipToBlack)
        XCTAssertEqual(placed.first { $0.from == added.id }?.kind,.crossDissolve)
        XCTAssertEqual(placed.count,2); XCTAssertTrue(placed.allSatisfy { !$0.isCut })
        XCTAssertEqual(Set(placed.map(\.id)).intersection(kept.map(\.id)),[],"fresh transitions")
        store.undo(); XCTAssertEqual(store.project,before)

        // One kept before favourites held transitions: no such key in its file.
        var older = favorite; older.id = UUID(); older.transitions = nil
        let json = String(decoding:try JSONEncoder().encode([older]),as:UTF8.self)
        XCTAssertFalse(json.contains("transitions"))
        try Favorites.save([older],to:file); store.favoritesFile = file
        XCTAssertEqual(store.favorites.count,1)
        XCTAssertTrue(store.placeFavorite(older.id,lane:.v1,at:.init(seconds:9)))
        let plain = try XCTUnwrap(store.project.clips.first { $0.lane == .v1 && $0.start == .init(seconds:9) })
        XCTAssertFalse(store.project.transitions.contains { $0.from == plain.id || $0.to == plain.id })
    }

    /// Keeping and removing favourites are undo steps among the project's edits: ⌘Z brings a
    /// removed favourite back (to its file too) and ⇧⌘Z takes it out again, in the order things were
    /// done, while the project stays as it is and is no unsaved change of theirs.
    func testAFavouriteComesBackWithUndo() throws {
        var ids: [String:UUID] = [:]
        let rig = TimelineRig { project in let hello = self.title("Hello",.v2,1,3); ids["title"] = hello.id; project.clips = [hello] }
        defer { rig.close() }
        let store = rig.store
        store.favoritesFile = file
        let dirty = store.dirty
        store.toggleFavorite(rig.clip(ids["title"]!))
        XCTAssertEqual(store.undoName,"Keep in Favourites"); XCTAssertEqual(store.dirty,dirty,"the document is not changed")
        let kept = try XCTUnwrap(store.favorites.first)
        // An edit of the project, then the favourite removed from its card.
        XCTAssertTrue(store.edit("Add text") { $0.clips.append(self.title("More",.v1,5,2)) })
        let edited = store.project
        store.removeFavorite(kept.id)
        XCTAssertEqual(store.favorites,[]); XCTAssertEqual(store.undoName,"Remove from Favourites")
        store.undo()
        XCTAssertEqual(store.favorites,[kept]); XCTAssertEqual(Favorites.load(from:file),[kept],"back in its file")
        XCTAssertEqual(store.project,edited,"the project as it was")
        store.redo()
        XCTAssertEqual(store.favorites,[]); XCTAssertEqual(Favorites.load(from:file),[])
        // Back in order: the favourite, then the edit, then keeping it.
        store.undo(); XCTAssertEqual(store.favorites,[kept]); XCTAssertEqual(store.project,edited)
        store.undo(); XCTAssertEqual(store.project.clips.count,1); XCTAssertEqual(store.favorites,[kept])
        store.undo(); XCTAssertEqual(store.favorites,[]); XCTAssertEqual(store.project.clips.count,1)
        XCTAssertEqual(store.undoName,"Fixture")
    }

    /// Dragged, a favourite shows its card's picture, as a media card shows its still: a title in
    /// its own colour, readable, at the size media is dragged at.
    func testADraggedFavouriteShowsItsCard() throws {
        _ = NSApplication.shared
        let hello = title("Hello",.v2,1,3)                        // red-orange text
        let picture = Favorites.dragPicture(FavoriteClip(clip:hello,origin:hello.id))
        XCTAssertEqual(picture.size,NSSize(width:140,height:80))
        let rep = try XCTUnwrap(picture.cgImage(forProposedRect:nil,context:nil,hints:nil).map(NSBitmapImageRep.init(cgImage:)))
        if let folder = ProcessInfo.processInfo.environment["ARA_PROBE"] {
            try rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:folder+"/favourite-drag.png"))
        }
        var text = 0, ground = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x:x,y:y)?.usingColorSpace(.sRGB) else { continue }
            if c.redComponent > 0.8, c.greenComponent < 0.5, c.blueComponent < 0.3 { text += 1 }
            if c.alphaComponent > 0.95, c.redComponent < 0.2, c.greenComponent < 0.2 { ground += 1 }
        }}
        XCTAssertGreaterThan(text,100,"the title, in its colour"); XCTAssertGreaterThan(ground,rep.pixelsWide*rep.pixelsHigh/2,"on solid dark ground")
    }
}
