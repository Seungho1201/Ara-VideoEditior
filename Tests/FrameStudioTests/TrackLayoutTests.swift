import AppKit
import SwiftUI
import XCTest
import FrameCore
@testable import FrameStudio

/// Each video track with its sound under it: the rows' order and sizes (clips filling them, no
/// margins), a sound folded away, or to a strip while it holds audio of its own (kept across
/// launches) whose clips can still be picked and moved.
@MainActor final class TrackLayoutTests: XCTestCase {
    func testEachVideoTrackHasItsSoundUnderIt() throws {
        let layout = TrackLayout(videoTracks:2,audioTracks:3,folded:[1],top:54)
        let rows = layout.rows
        XCTAssertEqual(layout.rows.map(\.lane.rawValue),["V2","A2","V1","A1","A3"])
        XCTAssertEqual(layout.rows.first?.top,54); XCTAssertEqual(layout.bottom,layout.rows.last?.bottom)
        for (above,below) in zip(layout.rows,layout.rows.dropFirst()) { XCTAssertEqual(above.bottom,below.top,"\(above.lane) meets \(below.lane)") }
        let v1 = try XCTUnwrap(layout.row(.v1)), a1 = try XCTUnwrap(layout.row(.a1)), a2 = try XCTUnwrap(layout.row(.a2))
        let a3 = try XCTUnwrap(layout.row(Lane(.audio,3)))
        XCTAssertTrue(v1.hasSound); XCTAssertTrue(a1.isSound && a1.folded); XCTAssertTrue(a2.isSound && !a2.folded)
        XCTAssertEqual(v1.boxBottom,a1.boxTop,"a picture's clips carry on into its sound's")
        XCTAssertEqual(rows.count,5)
        // No margins: clips fill their rows but for the 1 pt line between tracks.
        XCTAssertEqual(v1.boxTop,v1.top+1); XCTAssertEqual(a2.boxBottom,a2.bottom-1)
        XCTAssertEqual(a3.boxTop,a3.top+1); XCTAssertEqual(a3.boxBottom,a3.bottom-1)
        XCTAssertEqual(a1.height,0,"folded, with only its video's sound: gone, no gap under the picture")
        XCTAssertEqual(a2.height,TrackLayout.soundHeight)
        XCTAssertFalse(layout.soundShows(under:.v1)); XCTAssertTrue(layout.soundShows(under:.v2))
        // Holding audio of its own, a folded sound stays a strip.
        let strip = TrackLayout(videoTracks:2,audioTracks:3,folded:[1],ownAudio:[1],top:54)
        XCTAssertEqual(strip.row(.a1)?.height,TrackLayout.foldedHeight); XCTAssertTrue(strip.soundShows(under:.v1))
        XCTAssertFalse(a3.isSound,"A3 has no video track: a row of its own at the bottom"); XCTAssertEqual(a3.height,TrackLayout.rowHeight)
        XCTAssertTrue(layout.together(.v1,.a1)); XCTAssertFalse(layout.together(.v1,.a2))
        XCTAssertEqual(layout.lane(at:a1.top),Lane(.audio,3),"nothing to point at in a sound folded away: the next row starts there")
        XCTAssertEqual(layout.lane(at:a1.top-0.5),.v1); XCTAssertNil(layout.lane(at:layout.bottom))
        XCTAssertEqual(strip.lane(at:strip.row(.a1)!.top),.a1)
        // More video tracks than audio: V3 has no sound under it.
        let tall = TrackLayout(videoTracks:3,audioTracks:2,folded:[],top:0)
        XCTAssertEqual(tall.rows.map(\.lane.rawValue),["V3","V2","A2","V1","A1"])
        XCTAssertFalse(try XCTUnwrap(tall.row(Lane(.video,3))).hasSound)
        XCTAssertFalse(tall.together(Lane(.video,3),Lane(.audio,3)))
    }

    /// Folding V1's sound shortens the timeline and is kept. Holding a song, it stays a strip under
    /// the picture where the song can still be picked and moved; without one it goes away.
    func testAFoldedSoundKeepsItsClipsWithinReach() throws {
        var ids: [String:UUID] = [:]
        let video = timelineTestVideo()
        let song = MediaReference(name:"Song",path:"/nonexistent/ara-tests/Song.m4a",kind:.audio,duration:.init(seconds:20),hasAudio:true)
        let rig = TimelineRig { project in
            project.media = [video,song]
            ids["video"] = try Editing.add(mediaID:video.id,lane:.v1,at:.zero,to:&project)
            try Editing.trim(ids["video"]!,leading:false,to:.init(seconds:4),in:&project)
            ids["song"] = try Editing.add(mediaID:song.id,lane:.a1,at:.init(seconds:6),to:&project)
            try Editing.trim(ids["song"]!,leading:false,to:.init(seconds:10),in:&project)
        }
        defer { rig.close() }
        rig.store.snapping = false
        let open = rig.canvas.contentHeight
        rig.store.toggleSound(1)
        XCTAssertEqual(rig.store.foldedSound,[1]); XCTAssertEqual(UserDefaults.standard.array(forKey:"timeline.foldedSound") as? [Int],[1])
        XCTAssertEqual(rig.canvas.contentHeight,open-(TrackLayout.soundHeight-TrackLayout.foldedHeight))
        let strip = try XCTUnwrap(rig.canvas.trackLayout.row(.a1))
        XCTAssertTrue(strip.folded)
        // Picked with a click on the strip, and dragged a second later.
        rig.down(8,strip.top+4); rig.up(8,strip.top+4)
        XCTAssertEqual(rig.store.selectedClipID,ids["song"])
        rig.drag(from:8,through:[8.5,9],y:strip.top+4)
        XCTAssertEqual(rig.clip(ids["song"]!).start,.init(seconds:7)); XCTAssertEqual(rig.clip(ids["song"]!).lane,.a1)
        // The video's sound is on its picture now, not in the strip: pressed under the video, the strip has nothing.
        rig.down(2,strip.top+4); rig.up(2,strip.top+4)
        XCTAssertNil(rig.store.selectedClipID)
        rig.store.toggleSound(1)
        XCTAssertEqual(rig.store.foldedSound,[]); XCTAssertEqual(rig.canvas.contentHeight,open)
        // Without the song, V1's folded sound goes away altogether: no gap under the picture.
        XCTAssertTrue(rig.store.edit("Remove song") { $0.clips.removeAll { $0.id == ids["song"] } })
        rig.store.toggleSound(1)
        XCTAssertEqual(rig.canvas.trackLayout.row(.a1)?.height,0); XCTAssertFalse(rig.canvas.trackLayout.soundShows(under:.v1))
        XCTAssertEqual(rig.canvas.contentHeight,open-TrackLayout.soundHeight)
        rig.store.toggleSound(1)
        XCTAssertEqual(rig.canvas.contentHeight,open)
    }

    /// Folded, a video's sound is no clip in the strip but a waveform along its picture's foot, as
    /// LumaFusion draws one; open, the foot is plain and the waveform is in the sound under it.
    func testAFoldedVideoCarriesItsWaveform() throws {
        var id = UUID()
        let video = timelineTestVideo()
        let rig = TimelineRig { project in
            project.media = [video]
            id = try Editing.add(mediaID:video.id,lane:.v1,at:.zero,to:&project)
            try Editing.trim(id,leading:false,to:.init(seconds:4),in:&project)
        }
        defer { rig.close() }
        rig.store.waveforms[video.id] = (0..<2000).map { Float(($0*37)%101)/100 }
        /// Pixels along the picture's last 12 points, inside the clip, that pass `test`.
        func count(_ test: @escaping ((red: Int, green: Int, blue: Int)) -> Bool) throws -> Int {
            let row = try XCTUnwrap(rig.canvas.trackLayout.row(.v1)), image = rig.paint()
            return (Int(row.boxBottom-12)..<Int(row.boxBottom-2)).reduce(0) { total, y in
                total+(10..<230).filter { test(TimelineRig.color(image,Double($0),Double(y))) }.count
            }
        }
        func lit() throws -> Int { try count { $0.blue > 150 } }                     // the waveform's bright blue
        XCTAssertEqual(try lit(),0,"open: the picture's foot is plain")
        rig.store.toggleSound(1)
        XCTAssertGreaterThan(try lit(),100,"folded: its sound along the foot")
        // Its bar is clear folded: a red picture shows through between the waveform's bars.
        rig.store.thumbnails[video.id] = NSImage(size:NSSize(width:16,height:9),flipped:false) { NSColor.red.setFill(); $0.fill(); return true }
        XCTAssertGreaterThan(try count { $0.red > 120 && $0.green < 90 },300,"the picture under the folded sound")
        XCTAssertEqual(rig.canvas.trackLayout.row(.a1)?.height,0)
        // Nothing of the sound is left to pick apart: a press at the picture's foot picks the video.
        let row = try XCTUnwrap(rig.canvas.trackLayout.row(.v1))
        rig.down(2,row.boxBottom-3); rig.up(2,row.boxBottom-3)
        XCTAssertEqual(rig.store.selectedClipID,id)
    }

    /// A sound folds and opens over a moment, as the track names beside it do: part-way there in
    /// time it is part-way folded, and turned back on its way it sets off from where it is.
    func testASoundFoldsAndOpensOverAMoment() throws {
        let video = timelineTestVideo()
        let rig = TimelineRig { project in
            project.media = [video]
            let id = try Editing.add(mediaID:video.id,lane:.v1,at:.zero,to:&project)
            try Editing.trim(id,leading:false,to:.init(seconds:4),in:&project)
        }
        defer { rig.close() }
        var now = 100.0
        rig.canvas.clock = { now }
        func height() throws -> Double { try XCTUnwrap(rig.canvas.trackLayout.row(.a1)).height }
        func toggle() { rig.store.toggleSound(1); rig.canvas.animateFolds(to:rig.store.foldedSound) }
        rig.canvas.animateFolds(to:rig.store.foldedSound)             // what the timeline first shows: no move
        let open = try height()
        toggle()
        XCTAssertEqual(try height(),open,"it sets off from open")
        now += TimelineCanvas.foldDuration/2; rig.canvas.stepFolds()
        let half = try height()
        XCTAssertEqual(half,open/2,accuracy:0.01,"half way in time, half way folded")
        XCTAssertEqual(rig.canvas.trackLayout.soundFold(under:.v1),0.5,accuracy:0.001)
        XCTAssertFalse(rig.canvas.trackLayout.soundFolded(under:.v1))
        // Turned back half way: it opens from where it is.
        toggle()
        XCTAssertEqual(try height(),half,accuracy:0.01)
        now += TimelineCanvas.foldDuration/4; rig.canvas.stepFolds()
        XCTAssertGreaterThan(try height(),half); XCTAssertLessThan(try height(),open)
        now += TimelineCanvas.foldDuration; rig.canvas.stepFolds()
        XCTAssertEqual(try height(),open)
        // Folded to the end: gone, the video carrying its sound.
        toggle()
        now += TimelineCanvas.foldDuration+0.01; rig.canvas.stepFolds()
        XCTAssertEqual(try height(),0); XCTAssertTrue(rig.canvas.trackLayout.soundFolded(under:.v1))
        // The sound is a bar of its own: over the picture's foot folded, under the picture open, part-way
        // down in between; the picture stays as it is.
        let picture = NSRect(x:0,y:100,width:120,height:52)
        let shut = rig.canvas.soundBar(of:picture,fold:1), opened = rig.canvas.soundBar(of:picture,fold:0), between = rig.canvas.soundBar(of:picture,fold:0.5)
        XCTAssertEqual(shut.maxY,picture.maxY); XCTAssertGreaterThan(shut.minY,picture.minY+picture.height/2)
        XCTAssertEqual(opened.minY,picture.maxY); XCTAssertEqual(opened.height,TrackLayout.soundHeight-1)
        XCTAssertTrue(between.minY > shut.minY && between.minY < opened.minY && between.maxY > shut.maxY && between.maxY < opened.maxY)
        XCTAssertEqual(between.minX,picture.minX); XCTAssertEqual(between.width,picture.width)
        // SwiftUI's ease in and out: slow at both ends, half way at the middle.
        XCTAssertEqual(TimelineCanvas.easeInOut(0),0,accuracy:1e-6); XCTAssertEqual(TimelineCanvas.easeInOut(1),1,accuracy:1e-6)
        XCTAssertEqual(TimelineCanvas.easeInOut(0.5),0.5,accuracy:1e-6)
        XCTAssertLessThan(TimelineCanvas.easeInOut(0.1),0.05); XCTAssertGreaterThan(TimelineCanvas.easeInOut(0.9),0.95)
    }

    /// The track names column holds a name, its sound's switch and ✕ side by side at their widest
    /// (V3–V8, empty and so removable), in English and in Korean: nothing is pushed out of it.
    func testTheNamesFitTheirColumn() throws {
        for korean in [false,true] {
            let measure = {
                let rig = TimelineRig { project in
                    for n in 3...8 { try project.ensureLane(Lane(.video,n)); try project.ensureLane(Lane(.audio,n)) }
                }
                let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:400),styleMask:.borderless,backing:.buffered,defer:false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView:TimelineView(store:rig.store).frame(width:900,height:400))
                host.frame = NSRect(x:0,y:0,width:900,height:400)
                window.contentView = host
                defer { window.contentView = nil; window.close(); rig.close() }
                for _ in 0..<10 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
                // The "+ Video" button spans the column's content: wider content pushes it out both sides.
                let button = try XCTUnwrap(HelpTips.anchors.compactMap(\.view).first { $0.window === window && $0.text == String(localized:"Add a video track") })
                let span = host.convert(button.bounds,from:button)
                XCTAssertGreaterThanOrEqual(span.minX,-0.5,korean ? "Korean" : "English")
                XCTAssertLessThanOrEqual(span.maxX,TimelineView.namesWidth+0.5,"\(korean ? "Korean" : "English"): \(span.width) wide")
            }
            if korean { try inKorean(measure) } else { try measure() }
        }
    }
    /// Runs `body` with Bundle.main answering from a bundle that holds only the app's Korean table.
    private func inKorean(_ body: () throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-korean-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at:folder) }
        let lproj = folder.appendingPathComponent("Contents/Resources/ko.lproj")
        try FileManager.default.createDirectory(at:lproj,withIntermediateDirectories:true)
        let strings = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ko.lproj/Localizable.strings")
        try FileManager.default.copyItem(at:strings,to:lproj.appendingPathComponent("Localizable.strings"))
        let info: NSDictionary = ["CFBundleIdentifier":"ara.tests.korean","CFBundleDevelopmentRegion":"ko","CFBundleLocalizations":["ko"]]
        try info.write(to:folder.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url:folder))
        let method = try XCTUnwrap(class_getClassMethod(Bundle.self,#selector(getter:Bundle.main)))
        let original = method_getImplementation(method)
        let replacement: @convention(block) (AnyObject) -> Bundle = { _ in bundle }
        method_setImplementation(method,imp_implementationWithBlock(replacement))
        defer { method_setImplementation(method,original) }
        try body()
    }
}
