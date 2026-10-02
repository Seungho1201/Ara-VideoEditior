import AppKit
import SwiftUI
import XCTest
import FrameCore
@testable import FrameStudio

/// Settings ▸ Preview: the colours of the transform chrome are kept, a colour set back to its
/// default is forgotten, and the preview draws with what is chosen as soon as it is chosen.
@MainActor final class PreviewChromeColorsTests: XCTestCase {
    func testColoursAreKeptAndPutBack() {
        let suite = "ara.tests.chrome-colours.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let colors = PreviewChromeColors(defaults:defaults)
        XCTAssertTrue(colors.allStandard)
        XCTAssertEqual(colors.color(.outline).hex,"#9ACBFF"); XCTAssertEqual(colors.color(.guide).hex,"#FFD60A"); XCTAssertEqual(colors.color(.point).hex,"#FF453A")
        XCTAssertEqual(colors.color(.proportion).hex,"#30D158","green for a stretch back on its own proportions")
        colors.set(.guide,TitleColor(hex:"#30D158")!)
        XCTAssertFalse(colors.isStandard(.guide)); XCTAssertTrue(colors.isStandard(.outline))
        XCTAssertEqual(PreviewChromeColors(defaults:defaults).color(.guide).hex,"#30D158","kept for the next launch")
        colors.set(.guide,PreviewChromeColors.Part.guide.standard)
        XCTAssertTrue(colors.isStandard(.guide)); XCTAssertNil(defaults.string(forKey:"preview.color.guide"),"the default is forgotten, not kept")
        colors.set(.outline,TitleColor(hex:"#FF00FF")!); colors.set(.point,TitleColor(hex:"#00FFFF")!)
        colors.reset(.outline)
        XCTAssertTrue(colors.isStandard(.outline)); XCTAssertFalse(colors.allStandard)
        colors.resetAll()
        XCTAssertTrue(colors.allStandard); XCTAssertTrue(PreviewChromeColors(defaults:defaults).allStandard)
    }

    func testThePreviewDrawsWithTheChosenColours() async throws {
        _ = NSApplication.shared
        let shared = PreviewChromeColors.shared
        let saved = PreviewChromeColors.Part.allCases.map { UserDefaults.standard.object(forKey:$0.key) }
        defer {
            shared.resetAll()
            for (part,value) in zip(PreviewChromeColors.Part.allCases,saved) where value != nil { UserDefaults.standard.set(value,forKey:part.key) }
        }
        shared.resetAll()
        XCTAssertTrue(PreviewTransformOverlay.guideColor === NSColor.systemYellow,"unchosen, the very colours it has always drawn with")
        XCTAssertTrue(PreviewTransformOverlay.centreColor === NSColor.systemRed)
        XCTAssertTrue(PreviewTransformOverlay.proportionColor === NSColor.systemGreen)
        let store = EditorStore()
        var title = Clip(name:"T",kind:.text,lane:.v1,start:.zero,duration:.init(seconds:3)); title.style.text = "Colours"; title.style.scale = 0.6
        XCTAssertTrue(store.edit("Fixture") { $0.clips = [title] })
        for _ in 0..<500 where store.isBuilding || store.player.currentItem == nil { try await Task.sleep(for:.milliseconds(10)) }
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:225),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let preview = PreviewEditorView(store:store); preview.frame = window.contentLayoutRect
        window.contentView = preview; preview.layoutSubtreeIfNeeded()
        defer { preview.chrome.removeFromSuperview(); window.contentView = nil; window.close(); store.pause() }
        store.selectedClipID = title.id; store.previewTransformID = title.id; preview.overlay.refresh()
        /// Pixels of the chrome drawn in magenta (the window's colour space shifts it a little).
        func magenta() throws -> Int {
            let chrome = preview.chrome
            let rep = try XCTUnwrap(chrome.bitmapImageRepForCachingDisplay(in:chrome.bounds)); chrome.cacheDisplay(in:chrome.bounds,to:rep)
            var count = 0
            for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x:x,y:y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                if c.redComponent > 0.75, c.blueComponent > 0.75, c.greenComponent < 0.45 { count += 1 }
            }}
            return count
        }
        XCTAssertEqual(try magenta(),0)
        shared.set(.guide,TitleColor(hex:"#30D158")!); shared.set(.outline,TitleColor(hex:"#FF00FF")!); shared.set(.point,TitleColor(hex:"#00FFFF")!)
        XCTAssertEqual(TitleColor(PreviewTransformOverlay.guideColor)?.hex,"#30D158")
        XCTAssertEqual(TitleColor(PreviewTransformOverlay.outlineColor)?.hex,"#FF00FF")
        XCTAssertEqual(TitleColor(PreviewTransformOverlay.centreColor)?.hex,"#00FFFF")
        XCTAssertGreaterThan(try magenta(),200,"the outline and handles in the chosen colour")
    }

    /// In Settings each colour is chosen as a title's is: a preset or the palette sets it on the
    /// chrome at once, without touching the project or its undo, and the palette follows a colour
    /// set elsewhere.
    func testTheChromeColoursAreChosenAsATitlesAre() async throws {
        _ = NSApplication.shared
        let shared = PreviewChromeColors.shared
        let saved = PreviewChromeColors.Part.allCases.map { UserDefaults.standard.object(forKey:$0.key) }
        let recentsSuite = "ara.tests.chrome-recents.\(UUID().uuidString)"
        defer {
            shared.resetAll()
            for (part,value) in zip(PreviewChromeColors.Part.allCases,saved) where value != nil { UserDefaults.standard.set(value,forKey:part.key) }
            UserDefaults(suiteName:recentsSuite)?.removePersistentDomain(forName:recentsSuite)
        }
        shared.resetAll()
        let store = EditorStore(), before = store.project
        defer { store.pause() }
        let recents = RecentColors(defaults:UserDefaults(suiteName:recentsSuite)!)
        let target = ColorTarget(chrome:.guide,name:PreviewChromeColors.Part.guide.name)
        let green = try XCTUnwrap(TitleColor.presets.first { $0.name == "Green" }).color
        target.pick(green,in:store,recents:recents)
        XCTAssertEqual(shared.color(.guide).hex,green.hex); XCTAssertEqual(recents.colors.first?.hex,green.hex)
        XCTAssertEqual(store.project,before); XCTAssertFalse(store.canUndo,"a setting, not an edit")
        let model = ColorPaletteModel(store:store,target:target,recents:recents)
        defer { model.close() }
        XCTAssertEqual(model.shown.hex,green.hex,"the palette opens on it")
        model.commit(hex:"#123456")
        XCTAssertEqual(shared.color(.guide).hex,"#123456")
        shared.set(.guide,TitleColor(hex:"#FF8800")!)
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(model.shown.hex,"#FF8800","the palette follows a colour set elsewhere (↺, another window)")
    }
}
