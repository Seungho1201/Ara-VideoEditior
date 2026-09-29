import XCTest
@testable import FrameMedia

/// The cache behind held frames, titles and outlines: the most recently used values are kept up
/// to a budget of bytes, and past it a value is still found while something else holds it (the
/// preview's composition), so a rebuild finds what the preview shows without the cache keeping
/// everything ever drawn.
final class MediaRecentCacheTests: XCTestCase {
    private final class Picture { let name: String; init(_ name: String) { self.name = name } }

    func testTheMostRecentlyUsedAreKeptUpToTheBudget() {
        let cache = RecentCache<String,Picture>(budget:100)
        for name in ["a","b","c"] { cache.insert(Picture(name),bytes:40,for:name) }          // 120 bytes: "a" is let go
        XCTAssertNil(cache.value(for:"a"))
        XCTAssertEqual(cache.value(for:"b")?.name,"b")                                         // now the most recent
        cache.insert(Picture("d"),bytes:40,for:"d")                                            // lets go of "c", not "b"
        XCTAssertNil(cache.value(for:"c"))
        XCTAssertEqual(cache.value(for:"b")?.name,"b"); XCTAssertEqual(cache.value(for:"d")?.name,"d")
        XCTAssertEqual(cache.lookups.missed,2)
    }
    func testAValueSomethingElseHoldsIsFoundPastTheBudget() {
        let cache = RecentCache<Int,Picture>(budget:100)
        weak var first: Picture?
        do {
            let shown = (0..<10).map { Picture("\($0)") }                                      // held elsewhere
            for (i,picture) in shown.enumerated() { cache.insert(picture,bytes:40,for:i) }
            for (i,picture) in shown.enumerated() { XCTAssertTrue(cache.value(for:i) === picture,"\(i)") }
            first = shown[0]
        }
        // Once nothing else holds them, only what fits the budget stays.
        XCTAssertNil(first)
        XCTAssertEqual((0..<10).compactMap { cache.value(for:$0)?.name },["8","9"])
    }
    func testReplacingAValueCountsItsBytesOnce() {
        let cache = RecentCache<String,Picture>(budget:100)
        for _ in 0..<5 { cache.insert(Picture("same"),bytes:60,for:"same") }
        cache.insert(Picture("other"),bytes:40,for:"other")
        XCTAssertEqual(cache.value(for:"same")?.name,"same"); XCTAssertEqual(cache.value(for:"other")?.name,"other")
    }
}
