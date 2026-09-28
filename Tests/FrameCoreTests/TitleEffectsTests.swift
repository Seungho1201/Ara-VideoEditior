import XCTest
@testable import FrameCore

final class TitleEffectsTests: XCTestCase {
    private func titleProject(_ change: (inout ClipStyle) -> Void = { _ in }) throws -> Project {
        var p = Project()
        var title = Clip(name:"Title",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3))
        change(&title.style)
        p.clips = [title]
        return try p.validated()
    }

    func testTitlesStartWithoutEffects() {
        let style = ClipStyle()
        XCTAssertFalse(style.hasOutline); XCTAssertFalse(style.hasShadow)
        XCTAssertEqual(style.outlineWidth,0); XCTAssertEqual(style.shadowOpacity,0)
        // What a shadow looks like once it is switched on: down and to the right, softened.
        XCTAssertEqual(style.shadowDistance,6); XCTAssertEqual(style.shadowAngle,45); XCTAssertEqual(style.shadowBlur,8)
        XCTAssertEqual([style.outlineRed,style.outlineGreen,style.outlineBlue,style.shadowRed,style.shadowGreen,style.shadowBlue],[0,0,0,0,0,0])
    }

    func testEffectsSurviveSaveAndOlderDocumentsOpenWithoutThem() throws {
        let p = try titleProject {
            $0.outlineWidth = 4.5; $0.outlineRed = 1; $0.outlineGreen = 0.25
            $0.shadowOpacity = 0.7; $0.shadowDistance = 12; $0.shadowAngle = -30; $0.shadowBlur = 3; $0.shadowBlue = 0.5
        }
        let reopened = try ProjectFile.decode(ProjectFile.encode(p))
        XCTAssertEqual(reopened,p)
        XCTAssertEqual(reopened.clips[0].style.outlineWidth,4.5); XCTAssertEqual(reopened.clips[0].style.shadowAngle,-30)
        // A document saved before outlines and shadows existed has none of these keys.
        var json = try JSONSerialization.jsonObject(with:ProjectFile.encode(p)) as! [String:Any]
        var clips = json["clips"] as! [[String:Any]], style = clips[0]["style"] as! [String:Any]
        for key in ["outlineWidth","outlineRed","outlineGreen","outlineBlue","shadowOpacity","shadowDistance",
                    "shadowAngle","shadowBlur","shadowRed","shadowGreen","shadowBlue"] {
            XCTAssertNotNil(style.removeValue(forKey:key),key)
        }
        clips[0]["style"] = style; json["clips"] = clips
        let older = try ProjectFile.decode(JSONSerialization.data(withJSONObject:json)).clips[0].style
        var expected = ClipStyle(); expected.text = older.text
        XCTAssertEqual(older,expected)
    }

    func testEffectValuesAreValidated() throws {
        XCTAssertNoThrow(try titleProject { $0.outlineWidth = 20; $0.shadowOpacity = 1; $0.shadowDistance = 40; $0.shadowAngle = -180; $0.shadowBlur = 40 })
        let invalid: [(String,(inout ClipStyle) -> Void)] = [
            ("negative outline",{ $0.outlineWidth = -1 }), ("outline too wide",{ $0.outlineWidth = 20.5 }),
            ("outline NaN",{ $0.outlineWidth = .nan }), ("outline colour",{ $0.outlineGreen = 1.5 }),
            ("shadow opacity",{ $0.shadowOpacity = 1.2 }), ("shadow distance",{ $0.shadowDistance = -2 }),
            ("shadow too far",{ $0.shadowDistance = 41 }), ("shadow angle",{ $0.shadowAngle = 181 }),
            ("shadow blur",{ $0.shadowBlur = .infinity }), ("shadow colour",{ $0.shadowRed = -0.1 }),
        ]
        for (name,change) in invalid { XCTAssertThrowsError(try titleProject(change),name) }
    }
}
