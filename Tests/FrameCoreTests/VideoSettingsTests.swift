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
    func testSourceLimitedEndRoundsDownWithoutLeavingAudioBehind() throws {
        var project = Project(); project.frameRate = .init(60)
        let media = MediaReference(name:"62 frames",path:"/short.mp4",kind:.video,duration:.init(ticks:620_000),hasAudio:true)
        project.media = [media]
        _ = try Editing.add(mediaID:media.id,lane:.v1,at:.zero,to:&project)
        try Editing.setVideoSettings(aspectRatio:.square,frameRate:.init(24),in:&project)
        XCTAssertEqual(project.duration,.init(seconds:1))
        XCTAssertEqual(Set(project.clips.map(\.duration)),[.init(seconds:1)])
        XCTAssertTrue(project.clips.allSatisfy { $0.sourceStart+$0.sourceLength <= media.duration })
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
