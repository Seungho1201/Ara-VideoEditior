import XCTest
@testable import FrameCore

/// Edit errors are shown in the app's language: a literal message is looked up in the app's
/// strings table (English here, where the test runner has none) with its values filled in, and
/// text made elsewhere is shown as it is.
final class EditErrorTests: XCTestCase {
    func testMessagesFillInTheirValues() {
        XCTAssertEqual(EditError("Clips overlap on \(Lane.v1.rawValue). Use another track.").message,"Clips overlap on V1. Use another track.")
        XCTAssertEqual(EditError("This project version is not supported (\(3)).").message,"This project version is not supported (3).")
        XCTAssertEqual(EditError("Clips overlap on \(Lane.v1.rawValue). Use another track.").errorDescription,"Clips overlap on V1. Use another track.")
    }
    /// Already in the user's language (as the app's own checks make it) or put together from
    /// parts that are: never looked up or formatted again.
    func testTextMadeElsewhereIsKeptAsItIs() {
        let localized = String(localized:"Enter a project name.")
        XCTAssertEqual(EditError(localized).message,localized)
        let typed = "100% of “%@” as typed"
        XCTAssertEqual(EditError(typed).message,typed)
        XCTAssertEqual(EditError(typed.dropFirst(5)).message,"of “%@” as typed")
        XCTAssertEqual(EditError(verbatim:typed).message,typed)
    }
}
