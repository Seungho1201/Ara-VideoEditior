import XCTest
@testable import FrameCore

final class TitleFontTests: XCTestCase {
    private func titleProject(font: String? = nil) throws -> Project {
        var p = Project()
        var title = Clip(name:"Title",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3))
        if let font { title.style.fontName = font }
        p.clips = [title]
        return try p.validated()
    }

    func testTitlesKeepTheirFontThroughSaveAndOlderDocumentsUseTheDefault() throws {
        let p = try titleProject(font:"GmarketSansBold")
        let reopened = try ProjectFile.decode(ProjectFile.encode(p))
        XCTAssertEqual(reopened.clips.first?.style.fontName,"GmarketSansBold")
        XCTAssertEqual(reopened,p)
        // A document saved before fonts could be chosen has no fontName in its styles.
        var json = try JSONSerialization.jsonObject(with:ProjectFile.encode(p)) as! [String:Any]
        var clips = json["clips"] as! [[String:Any]], style = clips[0]["style"] as! [String:Any]
        style.removeValue(forKey:"fontName"); clips[0]["style"] = style; json["clips"] = clips
        let older = try ProjectFile.decode(JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(older.clips.first?.style.fontName,ClipStyle.defaultFontName)
        XCTAssertEqual(ClipStyle().fontName,"HelveticaNeue-Bold")
        // Every other style field is still required, as before.
        style = clips[0]["style"] as! [String:Any]; style.removeValue(forKey:"fontSize"); clips[0]["style"] = style; json["clips"] = clips
        XCTAssertThrowsError(try ProjectFile.decode(JSONSerialization.data(withJSONObject:json)))
    }

    func testFontNamesAreValidated() throws {
        XCTAssertNoThrow(try titleProject(font:"NotOnThisMac-Bold"))          // missing is allowed: drawn in the default
        XCTAssertThrowsError(try titleProject(font:""))
        XCTAssertThrowsError(try titleProject(font:"Two\nLines"))
        XCTAssertThrowsError(try titleProject(font:String(repeating:"a",count:256)))
    }

    func testResetAppearanceReturnsToTheDefaultFont() {
        var style = ClipStyle(); style.fontName = "GmarketSansBold"; style.text = "Keep me"
        let text = style.text; style = ClipStyle(); style.text = text      // what Reset appearance does
        XCTAssertEqual(style.fontName,ClipStyle.defaultFontName)
    }
}
