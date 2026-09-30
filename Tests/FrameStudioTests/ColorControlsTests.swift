import AppKit
import ObjectiveC
import SwiftUI
import XCTest
import FrameCore
import FrameMedia
@testable import FrameStudio

@MainActor private final class ColorTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// A title's colours: hex and HSB arithmetic, presets beside the swatch (one undo step each, no
/// rebuild), the palette's drags (one step each, the hue kept through greys), the recent colours,
/// the double-click rule, and the row as it is drawn. With ARA_COLOR_RENDERS naming a folder, the
/// inspector and the palette are also written there as PNGs, in English and Korean.
@MainActor final class ColorControlsTests: XCTestCase {
    private func spin(_ milliseconds: Int) async throws { try await Task.sleep(for:.milliseconds(milliseconds)) }
    private func settle(_ store: EditorStore) async throws {
        for _ in 0..<1000 where store.isBuilding || store.player.currentItem == nil { try await spin(10) }
    }
    private func title(_ text: String, lane: Lane = .v1, _ change: (inout ClipStyle) -> Void = { _ in }) -> Clip {
        var clip = Clip(name:"T",kind:.text,lane:lane,start:.zero,duration:.init(seconds:5))
        clip.style.text = text; change(&clip.style); return clip
    }
    private func text(_ id: UUID) -> ColorTarget { ColorTarget(clipID:id,red:\.red,green:\.green,blue:\.blue,name:"Text colour") }
    private func outline(_ id: UUID) -> ColorTarget { ColorTarget(clipID:id,red:\.outlineRed,green:\.outlineGreen,blue:\.outlineBlue,name:"Outline colour") }
    /// Recent colours kept in a defaults suite of their own, removed when the test ends.
    private func recents() throws -> RecentColors {
        let suite = "ara.tests.colors.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        addTeardownBlock { UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite) }
        return RecentColors(defaults:defaults)
    }
    private func assertEqual(_ a: TitleColor?, _ b: TitleColor, accuracy: Double = 1e-9, _ message: String = "", line: UInt = #line) {
        guard let a else { XCTFail("no colour · \(message)",line:line); return }
        XCTAssertEqual(a.red,b.red,accuracy:accuracy,message,line:line); XCTAssertEqual(a.green,b.green,accuracy:accuracy,message,line:line)
        XCTAssertEqual(a.blue,b.blue,accuracy:accuracy,message,line:line)
    }
    private func preset(_ name: String) throws -> TitleColor { try XCTUnwrap(TitleColor.presets.first { $0.name == name }).color }

    // MARK: arithmetic

    func testHexIsReadAndWrittenBothWays() {
        XCTAssertEqual(TitleColor(hex:"#FFD60A"),TitleColor(red:1,green:214.0/255,blue:10.0/255))
        XCTAssertEqual(TitleColor(hex:"ffd60a"),TitleColor(hex:"#FFD60A"),"without # and in lower case")
        XCTAssertEqual(TitleColor(hex:"  #0a84ff "),TitleColor(hex:"0A84FF"),"spaces around")
        XCTAssertEqual(TitleColor(hex:"#FD0"),TitleColor(hex:"#FFDD00"),"three digits, each doubled")
        XCTAssertEqual(TitleColor(hex:"f0a"),TitleColor(hex:"#FF00AA"))
        for bad in ["","#","#12","#1234","#12345","#1234567","GGGGGG","#FFD60Z","0xFFD60A","#FF D6 0A","##FFD60A","#ＦＦＤ６０Ａ","ffd60a;"] {
            XCTAssertNil(TitleColor(hex:bad),bad)
        }
        // Written as #RRGGBB, rounded to 8 bits; read back, the same.
        XCTAssertEqual(TitleColor(red:1,green:0.5,blue:0).hex,"#FF8000")
        XCTAssertEqual(TitleColor(red:0.2/255,green:254.6/255,blue:1.2).hex,"#00FFFF","rounded and kept in range")
        for preset in TitleColor.presets { XCTAssertEqual(TitleColor(hex:preset.color.hex),preset.color,preset.name) }
        for value in stride(from:0,through:0xFFFFFF,by:0x10307) {
            let hex = String(format:"#%06X",value)
            XCTAssertEqual(TitleColor(hex:hex)?.hex,hex)
        }
        let odd = TitleColor(red:0.123,green:0.456,blue:0.789)
        XCTAssertTrue(try XCTUnwrap(TitleColor(hex:odd.hex)).isClose(to:odd),"within half a step")
        // Typed with the Korean input source on, a–f come as jamo, alone or joined into syllables.
        XCTAssertEqual(TitleColor(typed:"ㄹㄹㅇ60ㅁ"),TitleColor(hex:"#FFD60A"))
        XCTAssertEqual(TitleColor(typed:"#0ㅁ84ㄹㄹ"),TitleColor(hex:"#0A84FF"))
        XCTAssertEqual(TitleColor(typed:"류0융"),TitleColor(hex:"FB0DBD"),"ㄹ+ㅠ is 류, ㅇ+ㅠ+ㅇ is 융")
        XCTAssertEqual(TitleColor(typed:"ㅊㄸ3"),TitleColor(hex:"CE3"))
        XCTAssertEqual(TitleColor(typed:"＃ＦＤ０"),TitleColor(hex:"#FD0"),"full-width")
        XCTAssertNil(TitleColor(typed:"ㅎㅎㅎ"))
        XCTAssertNil(TitleColor(typed:"가나다"))
    }

    func testHueSaturationAndBrightness() {
        // The primaries and secondaries come out exactly, both ways.
        let exact: [(HSB,TitleColor)] = [
            (HSB(hue:0,saturation:1,brightness:1),TitleColor(red:1,green:0,blue:0)),(HSB(hue:1.0/6,saturation:1,brightness:1),TitleColor(red:1,green:1,blue:0)),
            (HSB(hue:1.0/3,saturation:1,brightness:1),TitleColor(red:0,green:1,blue:0)),(HSB(hue:0.5,saturation:1,brightness:1),TitleColor(red:0,green:1,blue:1)),
            (HSB(hue:2.0/3,saturation:1,brightness:1),TitleColor(red:0,green:0,blue:1)),(HSB(hue:5.0/6,saturation:1,brightness:1),TitleColor(red:1,green:0,blue:1)),
            (HSB(hue:1,saturation:1,brightness:1),TitleColor(red:1,green:0,blue:0))]
        for (hsb,rgb) in exact {
            XCTAssertEqual(TitleColor(hsb),rgb,"\(hsb)")
            let back = rgb.hsb()
            XCTAssertEqual(back.hue,hsb.hue == 1 ? 0 : hsb.hue,accuracy:1e-12); XCTAssertEqual(back.saturation,1); XCTAssertEqual(back.brightness,1)
        }
        XCTAssertEqual(TitleColor(HSB(hue:0.3,saturation:0,brightness:1)),TitleColor(red:1,green:1,blue:1),"no saturation: white")
        XCTAssertEqual(TitleColor(HSB(hue:0.3,saturation:0.8,brightness:0)),TitleColor(red:0,green:0,blue:0),"no brightness: black")
        // A grey has no hue and black no saturation: those it is given are kept.
        let kept = HSB(hue:0.7,saturation:0.6,brightness:0.9)
        XCTAssertEqual(TitleColor(red:0.5,green:0.5,blue:0.5).hsb(keeping:kept),HSB(hue:0.7,saturation:0,brightness:0.5))
        XCTAssertEqual(TitleColor(red:1,green:1,blue:1).hsb(keeping:kept),HSB(hue:0.7,saturation:0,brightness:1))
        XCTAssertEqual(TitleColor(red:0,green:0,blue:0).hsb(keeping:kept),HSB(hue:0.7,saturation:0.6,brightness:0))
        XCTAssertEqual(TitleColor(red:1,green:0,blue:0).hsb(keeping:kept),HSB(hue:0,saturation:1,brightness:1),"a colour has its own")
        // Anything else goes there and back.
        for (r,g,b) in [(0.2,0.4,0.6),(0.9,0.1,0.3),(0.05,0.8,0.02),(0.6,0.6,0.61),(1,0.84,0.04)] {
            let color = TitleColor(red:r,green:g,blue:b)
            assertEqual(TitleColor(color.hsb()),color,accuracy:1e-12,"\(color.hex)")
        }
    }

    // MARK: edits

    /// A preset clicked is put on the title at once, redrawn in the preview without a rebuild, as
    /// one undo step named after the colour's label. Presets tried in turn are a step each, and
    /// text still waiting to be committed lands first, as its own.
    func testAPresetIsOneUndoStepWithoutARebuild() async throws {
        _ = NSApplication.shared
        let store = EditorStore(), recent = try recents()
        let a = title("Colours") { $0.outlineWidth = 4 }
        store.edit("Fixture") { $0.clips = [a] }
        try await settle(store)
        let original = store.project
        func shown() -> ClipStyle? {
            (store.player.currentItem?.videoComposition?.instructions.first as? FrameInstruction)?.layers.first { $0.clip.id == a.id }?.clip.style
        }
        let yellow = try preset("Yellow"), blue = try preset("Blue")
        text(a.id).pick(yellow,in:store,recents:recent)
        XCTAssertFalse(store.isBuilding,"drawn in place, not rebuilt")
        assertEqual(text(a.id).current(in:store.project),yellow)
        XCTAssertEqual(try XCTUnwrap(shown()).green,yellow.green,accuracy:1e-9,"the preview draws it at once")
        XCTAssertEqual(store.history.undoName,"Text colour","closed as a step already")
        outline(a.id).pick(blue,in:store,recents:recent)
        XCTAssertFalse(store.isBuilding)
        XCTAssertEqual(store.undoName,"Outline colour")
        store.undo(); assertEqual(outline(a.id).current(in:store.project),TitleColor(red:0,green:0,blue:0))
        assertEqual(text(a.id).current(in:store.project),yellow)
        store.undo(); XCTAssertEqual(store.project,original,"one step each")
        // The colour it has already: no step.
        try await settle(store)
        text(a.id).pick(try preset("White"),in:store,recents:recent)
        XCTAssertEqual(store.project,original); XCTAssertEqual(store.history.undoName,"Fixture")
        // Typed text still waiting lands first, as its own step.
        store.flushPendingEdits = { [weak store] in store?.updateStyleLive(a.id,name:"Edit text",closesWhenIdle:false) { $0.text = "Typed" } }
        text(a.id).pick(yellow,in:store,recents:recent)
        store.flushPendingEdits = nil
        XCTAssertEqual(store.undoName,"Text colour"); store.undo()
        XCTAssertEqual(store.project.clips[0].style.text,"Typed"); XCTAssertEqual(store.undoName,"Edit text")
        XCTAssertEqual(recent.colors,[yellow,try preset("White"),blue],"each colour put on is recent")
        // While an export reads the project, nothing lands and nothing is recent.
        let before = store.project
        store.isExporting = true; defer { store.isExporting = false }
        text(a.id).pick(blue,in:store,recents:recent)
        XCTAssertEqual(store.project,before); XCTAssertEqual(recent.colors.first,yellow)
    }

    /// A drag in the palette's square or along its hue bar is one undo step, shown at once. The hue
    /// stays through white and black, and the palette follows changes made elsewhere.
    func testAPaletteDragIsOneUndoStepAndKeepsItsHue() async throws {
        _ = NSApplication.shared
        let store = EditorStore(), recent = try recents()
        let a = title("Palette")
        store.edit("Fixture") { $0.clips = [a] }
        try await settle(store)
        let original = store.project
        let model = ColorPaletteModel(store:store,target:text(a.id),recents:recent)
        XCTAssertEqual(model.hsb.brightness,1); XCTAssertEqual(model.hsb.saturation,0,"white")
        // Along the hue bar on white: the colour stays white, the hue moves.
        for hue in [0.1,0.3,0.55] { model.drag(to:HSB(hue:hue,saturation:0,brightness:1)) }
        model.endDrag()
        XCTAssertEqual(model.hsb.hue,0.55); XCTAssertEqual(store.project,original,"white is white at any hue")
        XCTAssertEqual(store.history.undoName,"Fixture","no step")
        // Across the square: many steps, one undo step, never rebuilt.
        for (s,b) in [(0.2,0.9),(0.5,0.8),(0.8,0.7),(0.9,0.6)] {
            model.drag(to:HSB(hue:model.hsb.hue,saturation:s,brightness:b))
            XCTAssertFalse(store.isBuilding,"shown in place, not rebuilt")
        }
        assertEqual(text(a.id).current(in:store.project),TitleColor(HSB(hue:0.55,saturation:0.9,brightness:0.6)))
        model.endDrag()
        XCTAssertEqual(store.undoName,"Text colour")
        let dragged = store.project
        // Down to black and back up: the hue and saturation are still there.
        for b in [0.3,0.0] { model.drag(to:HSB(hue:model.hsb.hue,saturation:model.hsb.saturation,brightness:b)) }
        model.endDrag()
        assertEqual(text(a.id).current(in:store.project),TitleColor(red:0,green:0,blue:0))
        XCTAssertEqual(model.hsb,HSB(hue:0.55,saturation:0.9,brightness:0))
        model.drag(to:HSB(hue:model.hsb.hue,saturation:model.hsb.saturation,brightness:0.6)); model.endDrag()
        XCTAssertEqual(store.project,dragged,"back to the same colour")
        store.undo(); store.undo()
        XCTAssertEqual(store.project,dragged,"a step per drag"); XCTAssertEqual(model.hsb.hue,0.55,accuracy:1e-9)
        store.undo()
        XCTAssertEqual(store.project,original)
        // An undo to white shows white, keeping the hue it had.
        XCTAssertEqual(model.hsb.saturation,0); XCTAssertEqual(model.hsb.hue,0.55,accuracy:1e-9)
        // The hex field: a colour is one step; what is not a colour changes nothing.
        XCTAssertFalse(model.commit(hex:"#12")); XCTAssertEqual(store.project,original)
        XCTAssertTrue(model.commit(hex:"ff9f0a"))
        assertEqual(text(a.id).current(in:store.project),try preset("Orange")); XCTAssertEqual(store.undoName,"Text colour")
        XCTAssertEqual(model.hsb,try preset("Orange").hsb())
        // A drag the palette's closing ends is a step too.
        try await settle(store)
        let orange = store.project
        model.drag(to:HSB(hue:0.9,saturation:1,brightness:1))
        model.close()
        XCTAssertTrue(store.history.canUndo); store.undo(); XCTAssertEqual(store.project,orange)
        model.drag(to:HSB(hue:0.2,saturation:1,brightness:1)); model.pick(try preset("Blue"))
        XCTAssertEqual(store.project,orange,"a closed palette edits nothing")
        XCTAssertEqual(recent.colors.first,TitleColor(hex:TitleColor(HSB(hue:0.9,saturation:1,brightness:1)).hex),"the drag's colour is recent")
    }

    /// The Mac's colour panel sends its colour by target and action: taken in sRGB as a live edit
    /// named after the colour, that closes when the palette does. Then it sends nothing more.
    func testTheSystemColourPanelEditsUntilThePaletteCloses() async throws {
        _ = NSApplication.shared
        let store = EditorStore(), recent = try recents()
        let a = title("Panel")
        store.edit("Fixture") { $0.clips = [a] }
        try await settle(store)
        let original = store.project
        let model = ColorPaletteModel(store:store,target:text(a.id),recents:recent)
        model.panel.attach { model.panelChanged($0) }          // what show() does, without the panel
        model.panel.take(NSColor(srgbRed:0.2,green:0.4,blue:0.6,alpha:1))
        model.panel.take(NSColor(srgbRed:0.25,green:0.45,blue:0.65,alpha:1))
        assertEqual(text(a.id).current(in:store.project),TitleColor(red:0.25,green:0.45,blue:0.65),accuracy:1e-6)
        XCTAssertEqual(store.undoName,"Text colour"); XCTAssertFalse(store.isBuilding)
        assertEqual(model.shown,TitleColor(red:0.25,green:0.45,blue:0.65),accuracy:1e-6,"the palette follows the panel")
        // A Display P3 colour beyond sRGB is kept in range.
        model.panel.take(NSColor(displayP3Red:0,green:1,blue:0,alpha:1))
        let green = try XCTUnwrap(text(a.id).current(in:store.project))
        XCTAssertTrue([green.red,green.green,green.blue].allSatisfy { (0...1).contains($0) }); XCTAssertEqual(green.green,1,accuracy:1e-6)
        model.close()
        store.undo(); XCTAssertEqual(store.project,original,"one step")
        model.panel.take(NSColor(srgbRed:1,green:0,blue:0,alpha:1))
        XCTAssertEqual(store.project,original,"detached")
        XCTAssertEqual(recent.colors,[TitleColor(hex:green.hex)!],"its last colour is recent")
    }

    func testRecentColoursAreKeptNewestFirstEachOnce() throws {
        let suite = "ara.tests.recent-colours.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let recent = RecentColors(defaults:defaults)
        XCTAssertEqual(recent.colors,[])
        let colors = (0..<10).map { TitleColor(red:Double($0)/10,green:0.5,blue:1-Double($0)/10) }
        for color in colors { recent.add(color) }
        XCTAssertEqual(recent.colors.count,RecentColors.limit)
        XCTAssertEqual(recent.colors.map(\.hex),colors.reversed().prefix(8).map(\.hex),"newest first, the oldest gone")
        recent.add(colors[5])
        XCTAssertEqual(recent.colors.first?.hex,colors[5].hex); XCTAssertEqual(recent.colors.count,8)
        XCTAssertEqual(recent.colors.filter { $0.hex == colors[5].hex }.count,1,"once")
        recent.add(TitleColor(red:colors[5].red+0.2/255,green:colors[5].green,blue:colors[5].blue))
        XCTAssertEqual(recent.colors.count,8,"the same to 8 bits is the same colour")
        // Kept as hex, and read back so.
        XCTAssertEqual(defaults.stringArray(forKey:RecentColors.key),recent.colors.map(\.hex))
        XCTAssertEqual(RecentColors(defaults:defaults).colors,recent.colors)
        // What an older or damaged list holds is read as far as it makes sense.
        defaults.set(["#FFD60A","nonsense","#ffd60a","0A84FF","#FFF","#000","#111","#222","#333","#444","#555"],forKey:RecentColors.key)
        XCTAssertEqual(RecentColors(defaults:defaults).colors.map(\.hex),["#FFD60A","#0A84FF","#FFFFFF","#000000","#111111","#222222","#333333","#444444"])
    }

    /// The presets' names, the palette's words and what VoiceOver reads come from the string table.
    func testTheColourWordsAreInKorean() async throws {
        let korean = try XCTUnwrap(NSDictionary(contentsOf:table) as? [String:String])
        for key in TitleColor.presets.map(\.name)+["Text colour","Outline colour","Shadow colour","More colours","BASIC","RECENT","System Colours…",
                                                   "Click for preset colours · + opens the palette","Click to hide the preset colours",
                                                   "Saturation and brightness","Saturation %lld%%, brightness %lld%%","Hue","Current colour","Hex colour",
                                                   "Hex colour, such as #FFD60A or FD0 · Return to apply","Pick a colour from the screen",
                                                   "Change this colour in the Mac's colour panel while the palette is open"] {
            XCTAssertNotNil(korean[key],"no Korean for “\(key)”")
        }
        XCTAssertEqual(TitleColor(red:1,green:1,blue:1).spokenName,"White")
        XCTAssertEqual(TitleColor(hex:"#123456")?.spokenName,"#123456","a colour with no name is read as its hex value")
        try await inKorean {
            XCTAssertEqual(TitleColor.presets.map(\.color.spokenName),["흰색","검은색","노란색","주황색","빨간색","초록색","파란색","보라색"])
            XCTAssertEqual(TitleColor(hex:"#123456")?.spokenName,"#123456")
        }
    }

    // MARK: the row

    /// A click shows the presets and another hides them, but the second click of a double-click
    /// never hides them. One colour's presets at a time.
    func testASecondClickWithinTheDoubleClickIntervalKeepsThePresetsShown() {
        var row = ColorPresetRow()
        row.click("Text colour",at:10,interval:0.5); XCTAssertEqual(row.open,"Text colour")
        row.click("Text colour",at:10.3,interval:0.5); XCTAssertEqual(row.open,"Text colour","the second click of a double-click")
        row.click("Text colour",at:11,interval:0.5); XCTAssertNil(row.open,"a click later hides them")
        row.click("Text colour",at:20,interval:0.5); row.click("Text colour",at:25,interval:0.5); XCTAssertNil(row.open)
        row.click("Text colour",at:25.2,interval:0.5); XCTAssertEqual(row.open,"Text colour","a double-click on shown presets ends with them shown")
        row.click("Outline colour",at:25.3,interval:0.5); XCTAssertEqual(row.open,"Outline colour","another colour's instead")
        row.close("Text colour"); XCTAssertEqual(row.open,"Outline colour")
        row.close(); XCTAssertNil(row.open)
        // By the Mac's double-click interval.
        let interval = NSEvent.doubleClickInterval
        row.click("Shadow colour",at:100); row.click("Shadow colour",at:100+interval*0.9)
        XCTAssertEqual(row.open,"Shadow colour")
        row.click("Shadow colour",at:100+interval*1.1); XCTAssertNil(row.open)
        // As many presets as fit, and + always.
        let lead = TitleColorControl.lead, dot = TitleColorControl.dot
        XCTAssertEqual(TitleColorControl.presetsFitting(0),0)
        XCTAssertEqual(TitleColorControl.presetsFitting(lead+dot),0,"room for + alone")
        XCTAssertEqual(TitleColorControl.presetsFitting(lead+dot*4-1),2)
        XCTAssertEqual(TitleColorControl.presetsFitting(lead+dot*4),3)
        XCTAssertEqual(TitleColorControl.presetsFitting(lead+dot*9),8)
        XCTAssertEqual(TitleColorControl.presetsFitting(1000),8)
    }

    /// Shown presets go when their colour is switched off (the outline or shadow set to 0) and when
    /// another clip is chosen; a colour that is off never shows them.
    func testThePresetsGoWhenTheColourIsOffOrAnotherClipIsChosen() async throws {
        _ = NSApplication.shared
        let restore = inspectorSectionsUnfolded(); defer { restore() }
        let store = EditorStore()
        store.fontFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-color-fonts-\(UUID().uuidString)")
        let a = title("First") { $0.outlineWidth = 4; $0.shadowOpacity = 0.5 }, b = title("Second",lane:.v2)
        store.edit("Fixture") { $0.videoTrackCount = 2; $0.clips = [a,b] }
        store.selectedClipID = a.id
        let (window,view) = host(InspectorPanel(store:store),width:328)
        defer { window.contentView = nil; window.close() }
        func layout() async throws { for _ in 0..<6 { view.layoutSubtreeIfNeeded(); try await spin(25) } }
        /// Whether `colour`'s presets are still shown once the panel has caught up (a second at most).
        func shown(_ colour: String) async throws -> Bool {
            for _ in 0..<40 where store.colorPresetRow.open == colour { view.layoutSubtreeIfNeeded(); try await spin(25) }
            return store.colorPresetRow.open == colour
        }
        func off(_ key: WritableKeyPath<ClipStyle,Double>) {
            InspectorPanel.slide(key,to:0,range:0...20,switches:true,of:a.id,name:"Effect",closesWhenIdle:false,in:store); store.endLiveEdit()
        }
        try await layout()
        store.colorPresetRow.click("Outline colour",at:0,interval:0.5); try await layout()
        XCTAssertEqual(store.colorPresetRow.open,"Outline colour","shown while the outline is on")
        off(\.outlineWidth)
        var still = try await shown("Outline colour")
        XCTAssertFalse(still,"the outline switched off")
        store.colorPresetRow.click("Outline colour",at:1,interval:0.5)
        still = try await shown("Outline colour")
        XCTAssertFalse(still,"none for a colour that is off")
        store.colorPresetRow.click("Shadow colour",at:2,interval:0.5); try await layout()
        XCTAssertEqual(store.colorPresetRow.open,"Shadow colour")
        off(\.shadowOpacity)
        still = try await shown("Shadow colour")
        XCTAssertFalse(still,"the shadow switched off")
        store.colorPresetRow.click("Text colour",at:3,interval:0.5)
        store.selectedClipID = a.id
        XCTAssertEqual(store.colorPresetRow.open,"Text colour","the same clip again")
        store.selectedClipID = b.id
        XCTAssertNil(store.colorPresetRow.open,"another clip")
        store.colorPresetRow.click("Text colour",at:4,interval:0.5); store.selectedClipID = nil
        XCTAssertNil(store.colorPresetRow.open,"no clip")
    }

    /// Drawn: the presets sit to the right of the swatch in one row, level with it and evenly
    /// spaced, in their order; a narrower inspector shows fewer, dropped from the end.
    func testThePresetsAreDrawnBesideTheSwatchAsManyAsFit() async throws {
        _ = NSApplication.shared
        var counts: [CGFloat:Int] = [:]
        for width in [328.0,250.0] {
            for open in [false,true] {
                // A cyan text colour, found nowhere else in the panel, marks the swatch.
                let store = inspectorFixture { $0.red = 0; $0.green = 1; $0.blue = 1 }
                if open { store.colorPresetRow.click("Text colour",at:0,interval:0.5) }
                let image = try await renderInspector(store,width:width)
                let found = chromatic(image)
                guard open else { XCTAssertEqual(found.count,0,"hidden at \(width)"); continue }
                counts[width] = found.count
                // In the presets' order, dropping from the end.
                let names = TitleColor.presets.map(\.name).filter { found[$0] != nil }
                XCTAssertEqual(names,Array(["Yellow","Orange","Red","Green","Blue","Purple"].prefix(names.count)),"\(width)")
                let centres = names.map { found[$0]!.centre }
                let swatch = try XCTUnwrap(area(image,{ $0 <= 8 && $1 >= 247 && $2 >= 247 }),"the swatch")
                for centre in centres { XCTAssertEqual(centre.y,swatch.centre.y,accuracy:1,"level with the swatch at \(width)") }
                XCTAssertGreaterThan(centres.first?.x ?? 0,swatch.maxX+2*24,"right of the swatch, after white and black")
                for (left,right) in zip(centres,centres.dropFirst()) { XCTAssertEqual(right.x-left.x,24,accuracy:1,"even spacing at \(width)") }
                for name in names { XCTAssertEqual(found[name]!.maxX-found[name]!.minX,16,accuracy:1,"\(name): 18 points across, 16 inside its edge") }
            }
        }
        XCTAssertGreaterThanOrEqual(counts[328] ?? 0,4)
        XCTAssertGreaterThanOrEqual(counts[250] ?? 0,1)
        XCTAssertLessThan(counts[250] ?? 0,counts[328] ?? 0,"fewer in a narrow inspector")
    }

    /// The review renders: the title section in Korean at both widths, the row for the longest
    /// label, and the palette on its own, in English and Korean. Only with ARA_COLOR_RENDERS set.
    func testRendersForReview() async throws {
        guard folder != nil else { throw XCTSkip("set ARA_COLOR_RENDERS to a folder to write the renders") }
        _ = NSApplication.shared
        func inspectors(_ language: String) async throws {
            for width in [328.0,250.0] {
                for open in ["closed","Text colour","Outline colour"] {
                    let store = inspectorFixture()
                    if open != "closed" { store.colorPresetRow.click(open,at:0,interval:0.5) }
                    let name = open == "closed" ? "closed" : open == "Text colour" ? "open" : "outline-open"
                    try save(try await renderInspector(store,width:width),"inspector-\(language)-\(Int(width))-\(name)")
                }
                // SHADOW, TRANSFORM and COLOUR folded: SHADOW says its amount and colour, the others Default.
                try save(try await renderInspector(inspectorFixture(),width:width,folded:true),"inspector-\(language)-\(Int(width))-folded")
            }
            try save(try await renderPalette(),"palette-\(language)")
        }
        try await inspectors("en")
        try await inKorean { try await inspectors("ko") }
    }

    // MARK: drawing

    private var folder: URL? { ProcessInfo.processInfo.environment["ARA_COLOR_RENDERS"].map { URL(fileURLWithPath:$0,isDirectory:true) } }
    private func host<Root: View>(_ root: Root, width: CGFloat, height: CGFloat = 900) -> (NSWindow, NSHostingView<Root>) {
        let window = ColorTestWindow(contentRect:NSRect(x:0,y:0,width:width,height:height),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named:.darkAqua)
        let view = NSHostingView(rootView:root)
        view.frame = NSRect(x:0,y:0,width:width,height:height)
        window.contentView = view
        return (window,view)
    }
    /// A title with an outline and a shadow, selected: its three colours are on.
    private func inspectorFixture(_ change: (inout ClipStyle) -> Void = { _ in }) -> EditorStore {
        let store = EditorStore()
        store.fontFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-color-fonts-\(UUID().uuidString)")
        let a = title(String(localized:"Your story starts here")) { $0.outlineWidth = 4; $0.shadowOpacity = 0.6; $0.shadowDistance = 6; change(&$0) }
        store.edit("Fixture") { $0.clips = [a] }
        store.selectedClipID = a.id
        return store
    }
    /// The inspector's top, from the clip's name to the shadow, as the window's layers draw it.
    private func renderInspector(_ store: EditorStore, width: CGFloat, folded: Bool = false) async throws -> CGImage {
        let restore = inspectorSectionsUnfolded(); defer { restore() }
        if folded { for key in InspectorPanelTests.foldKeys { UserDefaults.standard.set(false,forKey:key) } }
        let (window,view) = host(InspectorPanel(store:store).preferredColorScheme(.dark),width:width,height:780)
        defer { window.contentView = nil; window.close() }
        // Shown presets come out one after another once the room beside the swatch is measured.
        for _ in 0..<30 { view.layoutSubtreeIfNeeded(); try await spin(30) }
        return try draw(view)
    }
    private func renderPalette() async throws -> CGImage {
        let store = EditorStore(), recent = try recents()
        let a = title("Palette") { $0.red = 1; $0.green = 214.0/255; $0.blue = 10.0/255 }
        store.edit("Fixture") { $0.clips = [a] }
        for hex in ["#30D158","#FF453A","#FFFFFF","#FFD60A"] { recent.add(TitleColor(hex:hex)!) }
        let model = ColorPaletteModel(store:store,target:text(a.id),recents:recent)
        let palette = ColorPalette(model:model,recents:recent).background(Color(red:0.15,green:0.16,blue:0.19)).preferredColorScheme(.dark)
        let height = NSHostingView(rootView:palette).fittingSize.height
        let (window,view) = host(palette,width:ColorPalette.width,height:ceil(height))
        defer { window.contentView = nil; window.close(); model.close() }
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); try await spin(30) }
        return try draw(view)
    }
    /// The window's root layer drawn at twice the size, rows running down as the view's do.
    private func draw(_ view: NSView) throws -> CGImage {
        var top = try XCTUnwrap(view.layer)
        while let up = top.superlayer { top = up }
        let scale = 2.0, size = view.bounds.size
        let context = try XCTUnwrap(CGContext(data:nil,width:Int(size.width*scale),height:Int(size.height*scale),bitsPerComponent:8,bytesPerRow:0,
                                              space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x:scale,y:scale)
        top.render(in:context)
        return try XCTUnwrap(context.makeImage())
    }
    private func save(_ image: CGImage, _ name: String) throws {
        guard let folder else { return }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]))
        try data.write(to:folder.appendingPathComponent("\(name).png"))
    }
    /// The image's pixels, top row first, as 8-bit sRGB.
    private func pixels(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int) {
        var bytes = [UInt8](repeating:0,count:image.width*image.height*4)
        let context = CGContext(data:&bytes,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        return (bytes,image.width,image.height)
    }
    /// Where the pixels matching `test` are, in points: their middle and their left and right
    /// edges; nil for none.
    private func area(_ image: CGImage, _ test: (Int,Int,Int) -> Bool) -> (centre: CGPoint, minX: CGFloat, maxX: CGFloat)? {
        let (bytes,width,height) = pixels(image)
        var sx = 0, sy = 0, n = 0, minX = Int.max, maxX = 0
        for y in 0..<height { for x in 0..<width {
            let i = (y*width+x)*4
            if test(Int(bytes[i]),Int(bytes[i+1]),Int(bytes[i+2])) { sx += x; sy += y; n += 1; minX = min(minX,x); maxX = max(maxX,x) }
        }}
        guard n > 40 else { return nil }
        return (CGPoint(x:(Double(sx)/Double(n)+0.5)/2,y:(Double(sy)/Double(n)+0.5)/2),CGFloat(minX)/2,CGFloat(maxX+1)/2)
    }
    /// The coloured presets found in the image, by name.
    private func chromatic(_ image: CGImage) -> [String:(centre: CGPoint, minX: CGFloat, maxX: CGFloat)] {
        var found: [String:(centre: CGPoint, minX: CGFloat, maxX: CGFloat)] = [:]
        for (name,color) in TitleColor.presets where name != "White" && name != "Black" {
            let r = Int(color.red*255), g = Int(color.green*255), b = Int(color.blue*255)
            if let hit = area(image,{ abs($0-r) <= 16 && abs($1-g) <= 16 && abs($2-b) <= 16 }) { found[name] = hit }
        }
        return found
    }
    private var table: URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ko.lproj/Localizable.strings")
    }
    /// Runs `body` with Bundle.main answering from a bundle that holds only the app's Korean table,
    /// as Ara.app does in Korean.
    private func inKorean(_ body: () async throws -> Void) async throws {
        let bundleFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-korean-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at:bundleFolder) }
        let lproj = bundleFolder.appendingPathComponent("Contents/Resources/ko.lproj")
        try FileManager.default.createDirectory(at:lproj,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:table,to:lproj.appendingPathComponent("Localizable.strings"))
        let info: NSDictionary = ["CFBundleIdentifier":"ara.tests.korean","CFBundleDevelopmentRegion":"ko","CFBundleLocalizations":["ko"]]
        try info.write(to:bundleFolder.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url:bundleFolder))
        let method = try XCTUnwrap(class_getClassMethod(Bundle.self,#selector(getter:Bundle.main)))
        let original = method_getImplementation(method)
        let korean: @convention(block) (AnyObject) -> Bundle = { _ in bundle }
        method_setImplementation(method,imp_implementationWithBlock(korean))
        defer { method_setImplementation(method,original) }
        try await body()
    }
}
