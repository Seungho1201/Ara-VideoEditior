import AppKit
import XCTest
import FrameMedia
@testable import FrameStudio

/// The font menus show each family (and each style) in its own face.
final class FontMenuPreviewTests: XCTestCase {
    private func family(_ name: String) throws -> FontLibrary.Family {
        let found = FontLibrary.families().first { $0.name == name }
        return try XCTUnwrap(found,"\(name) is not on this Mac")
    }

    func testFamiliesPreviewInTheirOwnFaceUnlessTheNameWouldNotRead() throws {
        XCTAssertEqual(FontLibrary.previewFace(of:try family("Didot")),"Didot")
        XCTAssertEqual(FontLibrary.previewFace(of:try family("Helvetica Neue")),"HelveticaNeue")
        // Hangul names in a Hangul font.
        if let gothic = FontLibrary.families().first(where: { $0.name == "Apple SD Gothic Neo" }) {
            XCTAssertNotNil(FontLibrary.previewFace(of:gothic),gothic.displayName)
        }
        // Pictures instead of letters, or no Latin letters for a Latin name: the system font.
        for name in ["Webdings","Wingdings","Zapf Dingbats","Apple Color Emoji","Al Bayan"] where FontLibrary.families().contains(where: { $0.name == name }) {
            XCTAssertNil(FontLibrary.previewFace(of:try family(name)),name)
        }
    }

    @MainActor func testTheMenuIsBuiltAsItOpensWithEachItemInItsFace() throws {
        _ = NSApplication.shared
        let names = ["Didot","Webdings","Zapfino","Helvetica Neue"].filter { name in FontLibrary.families().contains { $0.name == name } }
        let families = try names.map(family)
        var chosen: String?
        let coordinator = FontPopUp.Coordinator()
        coordinator.entries = [.header("System")]+families.map { .family($0) }
        coordinator.selected = "Didot"; coordinator.choose = { chosen = $0 }
        let button = NSPopUpButton(frame:.zero,pullsDown:false)
        coordinator.button = button
        let menu = try XCTUnwrap(button.menu)
        coordinator.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.count,1+families.count)
        XCTAssertTrue(menu.items[0].isSectionHeader)
        func item(_ name: String) throws -> NSMenuItem { try XCTUnwrap(menu.items.first { $0.representedObject as? String == name }) }
        func font(_ item: NSMenuItem) -> NSFont? { item.attributedTitle?.attribute(.font,at:0,effectiveRange:nil) as? NSFont }
        XCTAssertEqual(font(try item("Didot"))?.familyName,"Didot")
        XCTAssertEqual(try item("Didot").state,.on)
        XCTAssertTrue(button.selectedItem === (try item("Didot")),"opens on the current family")
        if names.contains("Webdings") { XCTAssertNil(font(try item("Webdings")),"a symbol font's name stays readable") }
        if names.contains("Zapfino") {
            let zapfino = try XCTUnwrap(font(try item("Zapfino")))
            XCTAssertEqual(zapfino.familyName,"Zapfino")
            XCTAssertLessThan(zapfino.pointSize,13,"a very tall face is made smaller")
            XCTAssertGreaterThanOrEqual(zapfino.pointSize,10,"but stays readable")
        }
        // Choosing an item reports its family.
        let helvetica = try item("Helvetica Neue")
        coordinator.picked(helvetica)
        XCTAssertEqual(chosen,"Helvetica Neue")
        // Opening again with nothing changed keeps the items it made.
        let first = menu.items.map(ObjectIdentifier.init)
        coordinator.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(ObjectIdentifier.init),first)
    }
}
