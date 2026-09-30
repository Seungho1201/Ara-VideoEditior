import Foundation
import FrameCore

/// Where each track sits on the timeline, top to bottom, for the canvas and the track names
/// beside it. A video track's sound, the audio track numbered like it, sits right under it as part
/// of the same track: open, tall enough for a waveform; folded, a thin strip where the sound
/// holds audio of its own, or nothing at all (the video's sound goes with it). Audio tracks past the
/// video tracks have rows of their own at the bottom.
struct TrackLayout: Equatable {
    struct Row: Equatable {
        let lane: Lane
        /// The row's top and height on the canvas.
        let top: Double, height: Double
        /// Where clip boxes sit in the row.
        let boxTop: Double, boxHeight: Double
        /// A video track with its sound in the row below.
        let hasSound: Bool
        /// A video track's sound, under it.
        let isSound: Bool
        /// A sound folded (or folding) away.
        let folded: Bool
        /// How far a sound is folded as shown: 0 open, 1 folded; in between while it folds or opens.
        var fold: Double = 0
        var bottom: Double { top+height }
        var boxBottom: Double { boxTop+boxHeight }
    }
    /// A track on its own; a video track's picture over its sound; that sound open and folded. Clips
    /// fill their rows but for a 1 pt line between tracks: no margins above and below them.
    static let rowHeight: Double = 54, pictureHeight: Double = 53, soundHeight: Double = 41, foldedHeight: Double = 10
    let rows: [Row]
    /// Where the "+ Audio" band starts, under the last row.
    let bottom: Double
    private let index: [Lane:Int]

    /// `folded`: the numbers of the tracks whose sound is folded; `ownAudio`: of those, the ones
    /// holding audio of their own, which stay a strip. `folding`: how far the sounds on their way
    /// are folded (0 open, 1 folded). `top`: where the first row starts.
    init(videoTracks: Int, audioTracks: Int, folded: Set<Int>, ownAudio: Set<Int> = [], folding: [Int:Double] = [:], top: Double) {
        var rows: [Row] = [], y = top
        for number in stride(from:videoTracks,through:1,by:-1) {
            let picture = Lane(.video,number)
            guard number <= audioTracks else {
                rows.append(Row(lane:picture,top:y,height:Self.rowHeight,boxTop:y+1,boxHeight:Self.rowHeight-2,hasSound:false,isSound:false,folded:false))
                y += Self.rowHeight; continue
            }
            // The picture's clips reach its bottom edge, where their sound carries on below them.
            rows.append(Row(lane:picture,top:y,height:Self.pictureHeight,boxTop:y+1,boxHeight:Self.pictureHeight-1,hasSound:true,isSound:false,folded:false))
            y += Self.pictureHeight
            let shut = folded.contains(number), fold = folding[number] ?? (shut ? 1 : 0)
            let height = Self.soundHeight+((ownAudio.contains(number) ? Self.foldedHeight : 0)-Self.soundHeight)*fold
            rows.append(Row(lane:Lane(.audio,number),top:y,height:height,boxTop:y,boxHeight:max(0,height-1),hasSound:false,isSound:true,folded:shut,fold:fold))
            y += height
        }
        for number in stride(from:videoTracks+1,through:audioTracks,by:1) {
            rows.append(Row(lane:Lane(.audio,number),top:y,height:Self.rowHeight,boxTop:y+1,boxHeight:Self.rowHeight-2,hasSound:false,isSound:false,folded:false))
            y += Self.rowHeight
        }
        self.rows = rows; bottom = y
        index = Dictionary(uniqueKeysWithValues:rows.enumerated().map { ($0.element.lane,$0.offset) })
    }
    init(_ project: Project, folded: Set<Int>, top: Double) {
        self.init(videoTracks:project.videoTrackCount,audioTracks:project.audioTrackCount,folded:folded,ownAudio:Self.ownAudio(in:project),top:top)
    }
    /// The audio tracks (by number) holding audio of their own: clips no video brought with it.
    static func ownAudio(in project: Project) -> Set<Int> {
        Set(project.clips.lazy.filter { $0.kind == .audio && $0.linkID == nil }.map(\.lane.number))
    }
    func row(_ lane: Lane) -> Row? { index[lane].map { rows[$0] } }
    /// The track at this height, if any. A sound folded away has none.
    func lane(at y: Double) -> Lane? { rows.first { y >= $0.top && y < $0.bottom }?.lane }
    /// Whether a video track's sound shows under it, open or as a strip.
    func soundShows(under picture: Lane) -> Bool { row(picture)?.hasSound == true && (row(picture.paired)?.height ?? 0) > 0 }
    /// Whether a video track's sound is folded: its videos carry their own sound on their pictures.
    func soundFolded(under picture: Lane) -> Bool { soundFold(under:picture) >= 1 }
    /// How far a video track's sound is folded as shown (0 open, 1 folded).
    func soundFold(under picture: Lane) -> Double { row(picture)?.hasSound == true ? row(picture.paired)?.fold ?? 0 : 0 }
    /// Whether two tracks are one track's picture and sound.
    func together(_ a: Lane, _ b: Lane) -> Bool {
        a.number == b.number && a.isVideo != b.isVideo && (row(a)?.hasSound == true || row(b)?.hasSound == true)
    }
    static func == (a: TrackLayout, b: TrackLayout) -> Bool { a.rows == b.rows && a.bottom == b.bottom }
}
