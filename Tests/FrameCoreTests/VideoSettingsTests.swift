import XCTest
import FrameCore

final class VideoSettingsTests: XCTestCase {
    private func fixture(rate: FrameRate = .init(60)) throws -> Project {
        var project = Project(); project.frameRate = rate
        let media = MediaReference(name:"Source",path:"/source.mp4",kind:.video,duration:.init(seconds:20),hasAudio:true)
        project.media = [media]
        let id = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
        try Editing.trim(id,leading:false,to:rate.floor(.init(seconds:6.3)),in:&project)
        try Editing.split(id,at:rate.quantize(.init(seconds:2.17)),in:&project)
        let right = project.clips.first { $0.kind == .video && $0.id != id }!
        try Editing.setTransition(.crossDissolve,duration:rate.quantize(.init(seconds:0.71)),from:id,to:right.id,in:&project)
        return project
    }
    func testCanvasPresetsHaveExactEvenDimensionsAtBothResolutions() {
        let expected: [VideoAspectRatio:CGSize] = [.landscape:.init(width:1920,height:1080),.portrait:.init(width:1080,height:1920),.square:.init(width:1080,height:1080),.classic:.init(width:1440,height:1080),.social:.init(width:1080,height:1350)]
        for (ratio,size) in expected {
            XCTAssertEqual(ratio.size(),size)
            XCTAssertEqual(ratio.size(resolution:2160),CGSize(width:size.width*2,height:size.height*2))
            XCTAssertEqual(ratio.value,size.width/size.height)
        }
    }
    func testAllFrameRatePairsKeepSharedCutsLinksAndSourceInPoints() throws {
        for sourceRate in FrameRate.supported {
            let before = try fixture(rate:sourceRate)
            for rate in FrameRate.supported {
                var project = before
                try Editing.setVideoSettings(aspectRatio:.portrait,frameRate:rate,in:&project)
                XCTAssertNoThrow(try project.validated())
                XCTAssertEqual(project.frameRate,rate)
                XCTAssertEqual(project.clips.count,before.clips.count)
                for (old,clip) in zip(before.clips,project.clips) {
                    XCTAssertEqual(clip.sourceStart,old.sourceStart)
                    XCTAssertEqual(clip.speed,old.speed)
                    XCTAssertEqual(clip.style,old.style)
                    XCTAssertEqual(clip.start,rate.quantize(clip.start))
                    XCTAssertEqual(clip.end,rate.quantize(clip.end))
                    XCTAssertLessThan(abs(clip.end.ticks-old.end.ticks),rate.frame.ticks)
                    XCTAssertEqual(Set(project.group(for:clip.id).map(\.duration)),[clip.duration])
                    XCTAssertEqual(Set(project.group(for:clip.id).map(\.start)),[clip.start])
                }
                let videos = project.clips.filter { $0.kind == .video }.sorted { $0.start < $1.start }
                XCTAssertEqual(videos[0].end,videos[1].start)
                XCTAssertEqual(project.transitions.map(\.id),before.transitions.map(\.id))
                XCTAssertEqual(project.transitions[0].duration,rate.quantize(project.transitions[0].duration))
            }
        }
    }
    /// A whole clip's end goes to the nearest frame like every cut, here 0.2 of a 24 fps frame past
    /// its source (which then holds its last frame), and its audio goes with it.
    func testSourceLimitedEndGoesToTheNearestFrameWithoutLeavingAudioBehind() throws {
        var project = Project(); project.frameRate = .init(60)
        let media = MediaReference(name:"62 frames",path:"/short.mp4",kind:.video,duration:.init(ticks:620_000),hasAudio:true)
        project.media = [media]
        _ = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
        try Editing.setVideoSettings(aspectRatio:.square,frameRate:.init(24),in:&project)
        XCTAssertEqual(project.duration,.init(ticks:625_000))                       // 25 frames, not 24
        XCTAssertEqual(Set(project.clips.map(\.duration)),[.init(ticks:625_000)])
        XCTAssertTrue(project.clips.allSatisfy { $0.sourceStart+$0.sourceLength-media.duration < project.frameRate.frame })
    }
    /// Clips of these source lengths (seconds), each used whole and appended, as double-clicking
    /// media builds a timeline.
    private func appended(_ lengths: [Double], rate: FrameRate = .init(30)) throws -> Project {
        var project = Project(); project.frameRate = rate
        for (i,length) in lengths.enumerated() {
            let media = MediaReference(name:"clip\(i).mov",path:"/clip\(i).mov",kind:.video,duration:.init(seconds:length),width:1920,height:1080,frameRate:30,hasAudio:true)
            project.media.append(media)
            _ = try Editing.add(mediaID:media.id,lane:.v1,at:project.duration,to:&project)
        }
        return project
    }
    /// Every cut goes to the nearest frame of the new grid: clips that met still meet, audio stays
    /// with its video, and a whole clip may end less than a frame after its source.
    private func assertConverted(_ before: Project, to rate: FrameRate, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var project = before
        XCTAssertNoThrow(try Editing.setVideoSettings(aspectRatio:.landscape,frameRate:rate,in:&project),"\(name) → \(rate.label)",file:file,line:line)
        XCTAssertEqual(project.frameRate,rate,file:file,line:line)
        let old = before.clips.filter { $0.kind == .video }.sorted { $0.start < $1.start }, new = project.clips.filter { $0.kind == .video }.sorted { $0.start < $1.start }
        for (a,b) in zip(old,new) {
            XCTAssertLessThanOrEqual(abs(b.end.ticks-a.end.ticks),rate.frame.ticks/2,"\(name) → \(rate.label): a cut moved more than half a frame",file:file,line:line)
            XCTAssertEqual(Set(project.group(for:b.id).map(\.end)),[b.end],file:file,line:line)
            let media = try XCTUnwrap(project.media(for:b))
            XCTAssertLessThan((b.sourceStart+b.sourceLength-media.duration).ticks,rate.frame.ticks,file:file,line:line)
        }
        for (a,b) in zip(new,new.dropFirst()) { XCTAssertEqual(a.end,b.start,"\(name) → \(rate.label): clips no longer meet",file:file,line:line) }
    }
    func testWholeClipsEndToEndConvertToEveryRate() throws {
        let timelines: [(String,Project)] = [
            ("two 6 s clips",try appended([6,6])),
            ("7.3 s + 12.8 s",try appended([7.3,12.8])),
            ("five 29.97 fps clips of 150 frames",try appended(Array(repeating:5.005,count:5),rate:.init(30000,1001))),
            ("twelve 29.97 fps clips of 150 frames",try appended(Array(repeating:5.005,count:12),rate:.init(30000,1001))),
        ]
        for (name,project) in timelines {
            for rate in FrameRate.supported where rate != project.frameRate { try assertConverted(project,to:rate,name) }
        }
    }
    /// Seven whole 4 s shots with half-second dissolves between them and a title across them (the
    /// 28 s export test timeline): every rate keeps every cut, dissolve and linked sound.
    func testWholeShotsWithDissolvesConvertToEveryRate() throws {
        for length in [4.0,4.004] {
            var project = try appended(Array(repeating:length,count:7))
            let shots = project.clips.filter { $0.kind == .video }.sorted { $0.start < $1.start }.map(\.id)
            for (a,b) in zip(shots,shots.dropFirst()) { try Editing.setTransition(.crossDissolve,duration:.init(seconds:0.5),from:a,to:b,in:&project) }
            let title = try Editing.addText(at:.zero,to:&project)
            try Editing.trim(title,leading:false,to:project.duration,in:&project)
            for rate in FrameRate.supported where rate != project.frameRate {
                try assertConverted(project,to:rate,"seven \(length) s shots")
                var converted = project
                try Editing.setVideoSettings(aspectRatio:.landscape,frameRate:rate,in:&converted)
                XCTAssertEqual(converted.transitions.map(\.id),project.transitions.map(\.id),"\(rate.label): every dissolve kept")
                XCTAssertEqual(converted.clip(title)?.end,converted.duration)
            }
        }
    }
    /// Rate after rate, whole clips that already end a little past their sources stay valid:
    /// one that would end a frame or more past it ends on the last frame its source reaches.
    func testRepeatedRateChangesOfWholeClipsStayValid() throws {
        var seed: UInt64 = 0x5eed
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11)/Double(1 << 53) }
        let order: [FrameRate] = [.init(24),.init(30),.init(60000,1001),.init(25),.init(60),.init(24000,1001),.init(50),.init(30000,1001),.init(24),.init(60)]
        for _ in 0..<60 {
            var project = try appended((0..<Int(2+next()*9)).map { _ in 0.5+next()*9 })
            let start = project
            for rate in order {
                XCTAssertNoThrow(try Editing.setVideoSettings(aspectRatio:.landscape,frameRate:rate,in:&project))
                XCTAssertNoThrow(try project.validated())
                let videos = project.clips.filter { $0.kind == .video }.sorted { $0.start < $1.start }
                for (a,b) in zip(videos,videos.dropFirst()) { XCTAssertEqual(a.end,b.start) }
            }
            // A few frames at most from where the cuts began, after ten changes of rate.
            for (a,b) in zip(start.clips,project.clips) { XCTAssertLessThan(abs(b.end.seconds-a.end.seconds),0.1) }
        }
    }
    /// 7 frames at 30 fps are 6 at 24 (0.6 of a frame rounds up) and 7.5, so 8, back at 30: a
    /// whole frame past the source. The cut stops at the source's last frame instead, and the
    /// next clip starts there.
    func testReturningToTheFirstRateEndsOnTheSourcesLastFrame() throws {
        var project = try appended([7.0/30,2])
        try Editing.setVideoSettings(aspectRatio:.landscape,frameRate:.init(24),in:&project)
        XCTAssertEqual(project.clips.filter { $0.kind == .video }.map(\.end).min(),.init(ticks:25_000*6))
        try Editing.setVideoSettings(aspectRatio:.landscape,frameRate:.init(30),in:&project)
        let videos = project.clips.filter { $0.kind == .video }.sorted { $0.start < $1.start }
        XCTAssertEqual(videos[0].end,.init(ticks:20_000*7))
        XCTAssertEqual(videos[1].start,videos[0].end)
        XCTAssertNoThrow(try project.validated())
    }
    /// A preset speed, a new frame rate, then 1x from the menu: the clip gets back the source range
    /// it was given, whether the change kept its length (30 → 60: exactly) or rounded it (30 → 25:
    /// as many whole frames of the new rate as that holds, or the nearest frame where rounding the
    /// retimed clip's cut already took it there).
    func testOneXAfterAFrameRateChangeGivesTheRangeBack() throws {
        let changes: [(FrameRate,FrameRate)] = [(.init(30),.init(60)),(.init(25),.init(50)),(.init(30000,1001),.init(60000,1001)),
                                                (.init(30),.init(25)),(.init(30),.init(24)),(.init(30),.init(24000,1001))]
        for (from,to) in changes {
            for (frames,speed) in [(151,4.0),(153,5.0),(152,3.0),(150,4.0),(150,1.23),(155,4.0)] {
                var project = Project(); project.frameRate = from
                let media = MediaReference(name:"Source",path:"/source.mp4",kind:.video,duration:.init(seconds:30),hasAudio:true)
                project.media = [media]
                let id = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
                try Editing.trim(id,leading:false,to:MediaTime(ticks:from.frame.ticks*Int64(frames)),in:&project)
                let given = try XCTUnwrap(project.clip(id)).sourceLength
                try Editing.setSpeed(id,to:speed,in:&project)
                try Editing.setVideoSettings(aspectRatio:.landscape,frameRate:to,in:&project)
                try Editing.setSpeed(id,to:1,in:&project)
                let back = try XCTUnwrap(project.clip(id)).duration, name = "\(frames) frames at \(from.label) → \(speed)x → \(to.label) → 1x"
                if from.frame.ticks == to.frame.ticks*2 { XCTAssertEqual(back,given,name) }
                XCTAssertGreaterThanOrEqual(back,to.floor(given),name); XCTAssertLessThanOrEqual(back,to.quantize(given),name)
                XCTAssertEqual(Set(project.group(for:id).map(\.sourceStart)),[.zero])
            }
        }
    }
    func testSpeedChangedClipsStillFitTheirSources() throws {
        for speed in [0.25,0.75,1.5,2.0,4.0] {
            var project = try fixture()
            let id = project.clips.first { $0.kind == .video && $0.start > .zero }!.id
            try Editing.setSpeed(id,to:speed,in:&project)
            try Editing.setVideoSettings(aspectRatio:.classic,frameRate:.init(30000,1001),in:&project)
            XCTAssertNoThrow(try project.validated())
            XCTAssertEqual(project.clip(id)?.speed,speed)
        }
    }
    func testUnrepresentableShortClipFailsAtomically() throws {
        var project = Project(); project.frameRate = .init(60)
        project.clips = [Clip(name:"One frame",kind:.text,lane:.v1,start:.zero,duration:project.frameRate.frame)]
        let before = project
        XCTAssertThrowsError(try Editing.setVideoSettings(aspectRatio:.portrait,frameRate:.init(24),in:&project))
        XCTAssertEqual(project,before)
        XCTAssertThrowsError(try Editing.setVideoSettings(aspectRatio:.portrait,frameRate:.init(0),in:&project))
        XCTAssertEqual(project,before)
    }
    func testSettingsSaveReopenUndoAndRedoExactly() throws {
        var project = try fixture(), history = EditHistory()
        let before = project; history.record(before,name:"Timeline settings")
        try Editing.setVideoSettings(aspectRatio:.social,frameRate:.init(24000,1001),resolution:2160,in:&project)
        let after = project
        XCTAssertEqual(after.outputResolution,2160)
        XCTAssertEqual(try ProjectFile.decode(ProjectFile.encode(project)),after)
        project = try XCTUnwrap(history.undo(project)); XCTAssertEqual(project,before)
        project = try XCTUnwrap(history.redo(project)); XCTAssertEqual(project,after)
    }
    func testLegacyProjectsDefaultToFullHDAndInvalidQualityIsRejected() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:ProjectFile.encode(Project())) as? [String:Any])
        object.removeValue(forKey:"outputResolution")
        for version in [1,2] {
            object["version"] = version
            let loaded = try ProjectFile.decode(JSONSerialization.data(withJSONObject:object))
            XCTAssertEqual(loaded.outputResolution,1080)
        }
        object["outputResolution"] = 900
        XCTAssertThrowsError(try ProjectFile.decode(JSONSerialization.data(withJSONObject:object)))
        var project = try fixture(); let before = project
        XCTAssertThrowsError(try Editing.setVideoSettings(aspectRatio:.portrait,frameRate:.init(24),resolution:900,in:&project))
        XCTAssertEqual(project,before)
    }
    func testVersionOneMigratesToLandscapeAndVersionTwoRequiresValidAspect() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:ProjectFile.encode(fixture())) as? [String:Any])
        object["version"] = 1; object.removeValue(forKey:"aspectRatio")
        let migrated = try ProjectFile.decode(JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(migrated.version,2); XCTAssertEqual(migrated.aspectRatio,.landscape)
        object["version"] = 2
        XCTAssertThrowsError(try ProjectFile.decode(JSONSerialization.data(withJSONObject:object)))
        object["aspectRatio"] = "0:0"
        XCTAssertThrowsError(try ProjectFile.decode(JSONSerialization.data(withJSONObject:object)))
    }
    func testAspectOnlyChangeKeepsEveryCutAndTransitionExactly() throws {
        var project = try fixture(); let before = project
        try Editing.setVideoSettings(aspectRatio:.portrait,frameRate:project.frameRate,in:&project)
        XCTAssertEqual(project.clips,before.clips); XCTAssertEqual(project.transitions,before.transitions)
    }
    func testPortraitTransformAndTextScaleMatchBothOutputSizes() {
        let ratio = VideoAspectRatio.portrait
        for isText in [false,true] {
            var style = ClipStyle(); style.scale = 0.7; style.x = 0.1; style.y = -0.2; style.rotation = 12
            let small = VisualGeometry(sourceSize:.init(width:640,height:360),canvasSize:ratio.size(),style:style,isText:isText)
            let large = VisualGeometry(sourceSize:small.sourceSize,canvasSize:ratio.size(resolution:2160),style:style,isText:isText)
            for (a,b) in zip(small.corners,large.corners) {
                XCTAssertEqual(a.x*2,b.x,accuracy:0.001); XCTAssertEqual(a.y*2,b.y,accuracy:0.001)
            }
            XCTAssertTrue(small.contains(small.center))
        }
    }

    func testEveryOutputQualityHasEvenSidesAndKeepsTheShape() {
        XCTAssertEqual(OutputQuality.allCases.map(\.name),["HD","Full HD","2K","QHD","3K","4K"])
        for quality in OutputQuality.allCases {
            for ratio in VideoAspectRatio.allCases {
                let size = ratio.size(resolution:quality.rawValue), full = ratio.size()
                XCTAssertEqual(Int(size.width)%2,0,"\(quality.name) \(ratio.rawValue)"); XCTAssertEqual(Int(size.height)%2,0)
                XCTAssertEqual(min(size.width,size.height),CGFloat(quality.rawValue),"the short edge is the preset")
                XCTAssertEqual(size.width/size.height,full.width/full.height,accuracy:0.002,"\(quality.name) \(ratio.rawValue)")
            }
        }
        XCTAssertEqual(VideoAspectRatio.landscape.size(resolution:1440),CGSize(width:2560,height:1440))
        XCTAssertEqual(VideoAspectRatio.landscape.size(resolution:1152),CGSize(width:2048,height:1152))
        XCTAssertEqual(VideoAspectRatio.landscape.size(resolution:1620),CGSize(width:2880,height:1620))
        XCTAssertEqual(VideoAspectRatio.landscape.size(resolution:720),CGSize(width:1280,height:720))
        XCTAssertEqual(VideoAspectRatio.social.size(resolution:1620),CGSize(width:1620,height:2024))
        XCTAssertEqual(OutputQuality.bitRate(shortEdge:1080),12_000_000); XCTAssertEqual(OutputQuality.bitRate(shortEdge:2160),40_000_000)
        var project = Project()
        for quality in OutputQuality.allCases {
            XCTAssertNoThrow(try Editing.setVideoSettings(aspectRatio:.landscape,frameRate:.init(30),resolution:quality.rawValue,in:&project))
            XCTAssertEqual(project.outputResolution,quality.rawValue)
        }
    }
}
