import AppKit
import SwiftUI
import XCTest
import FrameCore
@testable import FrameStudio

@MainActor private final class InspectorTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// The inspector: its Rotation and Scale sliders keep the alignment point still, a title's text
/// field holds what the title keeps, an effect that reads 0 is off, and its header and the side
/// panel's tabs keep their lines at the panel's narrowest.
@MainActor final class InspectorPanelTests: XCTestCase {
    private let caret = NSRange(location:NSNotFound,length:0)
    private func spin(_ milliseconds: Int) async throws { try await Task.sleep(for:.milliseconds(milliseconds)) }
    private func settle(_ store: EditorStore) async throws {
        for _ in 0..<1000 where store.isBuilding || store.player.currentItem == nil { try await spin(10) }
    }
    private func title(_ text: String, lane: Lane = .v1, _ change: (inout ClipStyle) -> Void = { _ in }) -> Clip {
        var clip = Clip(name:"T",kind:.text,lane:lane,start:.zero,duration:.init(seconds:5))
        clip.style.text = text; change(&clip.style); return clip
    }
    private func style(_ store: EditorStore, _ id: UUID) -> ClipStyle { store.project.clips.first { $0.id == id }?.style ?? ClipStyle() }
    /// Where a clip's alignment point is in the frame (1080 units), with this style and source size.
    private func anchor(_ store: EditorStore, _ id: UUID, _ style: ClipStyle? = nil, size: CGSize? = nil) throws -> CGPoint {
        let clip = try XCTUnwrap(store.project.clips.first { $0.id == id })
        let source = try XCTUnwrap(size ?? store.previewSourceSize(for:clip))
        return VisualGeometry(sourceSize:source,canvasSize:store.project.aspectRatio.size(),style:style ?? clip.style,isText:clip.kind == .text).anchor
    }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x-b.x,a.y-b.y) }
    /// What the slider's binding does with each value of a drag, closed as its release closes it.
    private func drag(_ key: WritableKeyPath<ClipStyle,Double>, _ values: [Double], range: ClosedRange<Double>, _ id: UUID, in store: EditorStore) {
        for value in values { InspectorPanel.slide(key,to:value,range:range,of:id,name:"Adjust clip",closesWhenIdle:false,in:store) }
        store.endLiveEdit()
    }
    private func host<Root: View>(_ root: Root, width: CGFloat = 300, height: CGFloat = 1400) -> (NSWindow, NSHostingView<Root>) {
        let window = InspectorTestWindow(contentRect:NSRect(x:0,y:0,width:width,height:height),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView:root)
        view.frame = NSRect(x:0,y:0,width:width,height:height)
        window.contentView = view
        return (window,view)
    }
    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let hit = view as? T { found.append(hit) }
        for sub in view.subviews { found += all(type,in:sub) }
        return found
    }
    /// The view as the window draws it, in an sRGB bitmap whose rows run down as the view's do.
    private func painted(_ view: NSView) throws -> CGContext {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:rep)
        let image = try XCTUnwrap(rep.cgImage)
        let context = try XCTUnwrap(CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,
                                              space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        return context
    }
    /// Pixels drawn in the orange of the inspector's notes (nothing else in it is orange).
    private func orange(_ view: NSView) throws -> Int {
        let context = try painted(view)
        var count = 0
        for y in 0..<context.height { for x in 0..<context.width {
            let c = TimelineRig.color(context,Double(x),Double(y))
            if c.red > 190, (90...185).contains(c.green), c.blue < 90 { count += 1 }
        }}
        return count
    }

    // MARK: sliders and the alignment point

    /// The finding's case: a title with its point on the top-left corner, turned 0→45° and scaled
    /// 100→160% with the sliders. The point stays put, as it does under the handle and a pinch.
    func testRotationAndScaleSlidersTurnAboutTheAlignmentPoint() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        let a = title("Turned about its corner") { $0.anchorX = -0.5; $0.anchorY = -0.5 }
        store.edit("Fixture") { $0.clips = [a] }
        try await settle(store)
        XCTAssertNotNil(store.previewSourceSize(for:a),"the preview has the title's picture")
        let pivot = try anchor(store,a.id)
        drag(\.rotation,Array(stride(from:5.0,through:45,by:5)),range:-180...180,a.id,in:store)
        XCTAssertEqual(style(store,a.id).rotation,45)
        XCTAssertLessThan(distance(try anchor(store,a.id),pivot),0.5,"turning moved the point")
        XCTAssertEqual(store.undoName,"Adjust clip"); store.undo()
        XCTAssertEqual(style(store,a.id),a.style,"one drag, one undo step")
        drag(\.scale,Array(stride(from:1.1,through:1.6,by:0.1)),range:0.05...4,a.id,in:store)
        XCTAssertEqual(style(store,a.id).scale,1.6,accuracy:1e-9)
        XCTAssertLessThan(distance(try anchor(store,a.id),pivot),0.5,"scaling moved the point")
        // Position moves the clip, point and all, and nothing else.
        let before = style(store,a.id)
        drag(\.x,[0.1,0.25],range:-1...1,a.id,in:store)
        var expected = before; expected.x = 0.25
        XCTAssertEqual(style(store,a.id),expected)
        // With the point in the middle, turning leaves the clip where it is.
        let b = title("Turned about its middle")
        store.edit("Fixture") { $0.clips = [b] }
        try await settle(store)
        drag(\.rotation,[30,60],range:-180...180,b.id,in:store)
        XCTAssertEqual(style(store,b.id).x,0); XCTAssertEqual(style(store,b.id).y,0)
    }

    /// Before the preview has a picture of a title (not built yet, or stopped by a missing source)
    /// the sliders still keep its point: the title is measured as the preview measures it. A video
    /// is measured by its source's size.
    func testSlidersKeepThePointWithoutAPictureInThePreview() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        let media = timelineTestVideo()                  // its file does not exist: nothing is built
        let video = Clip(mediaID:media.id,name:"Source",kind:.video,lane:.v1,start:.zero,duration:.init(seconds:5))
        var picture = video; picture.style.anchorX = 0.5; picture.style.anchorY = -0.5
        let words = title("No picture yet",lane:.v2) { $0.anchorX = 0.5; $0.anchorY = 0.5 }
        store.edit("Fixture") { $0.media = [media]; $0.videoTrackCount = 2; $0.clips = [picture,words] }
        store.message = nil
        XCTAssertNil(store.player.currentItem)
        XCTAssertNil(store.previewSourceSize(for:words),"no picture of the title to measure")
        let corner = try anchor(store,picture.id)
        drag(\.scale,[0.8,0.5],range:0.05...4,picture.id,in:store)
        drag(\.rotation,[-20,-90],range:-180...180,picture.id,in:store)
        XCTAssertLessThan(distance(try anchor(store,picture.id),corner),0.5)
        drag(\.rotation,[10,35],range:-180...180,words.id,in:store)
        drag(\.scale,[1.4,2],range:0.05...4,words.id,in:store)
        let turned = style(store,words.id)
        XCTAssertEqual(turned.rotation,35); XCTAssertEqual(turned.scale,2)
        // Measured in the preview once it can be built, the title's point has not moved.
        store.edit("Without the video") { $0.clips.removeAll { $0.id == video.id } }
        try await settle(store)
        XCTAssertLessThan(distance(try anchor(store,words.id),try anchor(store,words.id,words.style)),0.5)
    }

    // MARK: a title's text

    func testFittingKeepsTheTextAroundWhatWasTyped() {
        let limit = InspectorPanel.textLimit
        let full = String(repeating:"a",count:limit)
        XCTAssertEqual(InspectorPanel.fitted("short",after:""),"short")
        XCTAssertTrue(InspectorPanel.fitted(String(repeating:"가",count:limit+500),after:"") == String(repeating:"가",count:limit),"a long paste is cut")
        XCTAssertTrue(InspectorPanel.fitted("aaaaXaaaa"+full.dropFirst(8),after:full) == full,"a key in a full title changes nothing")
        let middle = "ab"+String(repeating:"x",count:limit)+"cd"
        XCTAssertTrue(InspectorPanel.fitted(middle,after:"abcd") == "ab"+String(repeating:"x",count:limit-4)+"cd","a paste in the middle keeps the end")
        XCTAssertEqual(InspectorPanel.fitted(String(repeating:"y",count:limit+10),after:"old text").count,limit)
        // The caret goes after what was kept of the typing, counted as the text view counts (UTF-16).
        XCTAssertEqual(InspectorPanel.fitting(middle,after:"abcd").caret,limit-2)
        XCTAssertEqual(InspectorPanel.fitting("aaaaXaaaa"+full.dropFirst(8),after:full).caret,4)
        XCTAssertEqual(InspectorPanel.fitting("👍"+String(repeating:"z",count:limit),after:"👍").caret,2+limit-1)
    }

    /// A paste cut to fit, or a key refused in a full title, leaves the caret where the user was
    /// typing (writing the fitted text back would put it at the end, out of sight), so the next
    /// Backspace takes the character before it.
    func testTheCaretStaysWhereTheUserWasTyping() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        store.fontFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-inspector-fonts-\(UUID().uuidString)")
        let a = title(String((0..<1990).map { Character(String($0 % 10)) }))
        store.edit("Fixture") { $0.clips = [a] }
        store.selectedClipID = a.id
        try await settle(store)
        let (window,view) = host(InspectorPanel(store:store),height:700)
        defer { window.contentView = nil; window.close() }
        try await spin(120)
        let field = try XCTUnwrap(all(NSTextView.self,in:view).first { $0.isEditable },"the title's text field")
        XCTAssertTrue(window.makeFirstResponder(field)); try await spin(60)
        field.setSelectedRange(NSRange(location:100,length:0))
        field.insertText(String(repeating:"X",count:20),replacementRange:caret)
        try await spin(400)
        XCTAssertEqual(field.string.count,InspectorPanel.textLimit)
        XCTAssertEqual(field.selectedRange(),NSRange(location:110,length:0),"after the ten that fit")
        field.setSelectedRange(NSRange(location:50,length:0))
        field.insertText("Y",replacementRange:caret)
        try await spin(400)
        XCTAssertEqual(field.selectedRange(),NSRange(location:50,length:0),"where the key was pressed")
        var expected = field.string
        expected.remove(at:expected.index(expected.startIndex,offsetBy:49))
        field.deleteBackward(nil)
        try await spin(400)
        XCTAssertEqual(field.string,expected); XCTAssertEqual(style(store,a.id).text,expected)
        store.pause()
    }

    /// Pasting more than the 2000 characters a title keeps: the field keeps the same 2000 as the
    /// title, and a note says why. Typing into the full field changes nothing.
    func testTheTitleFieldHoldsNoMoreThanTheTitleKeeps() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        store.fontFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-inspector-fonts-\(UUID().uuidString)")
        let a = title("Base")
        store.edit("Fixture") { $0.clips = [a] }
        store.selectedClipID = a.id
        try await settle(store)
        let (window,view) = host(InspectorPanel(store:store),height:700)
        defer { window.contentView = nil; window.close() }
        try await spin(120)
        let field = try XCTUnwrap(all(NSTextView.self,in:view).first { $0.isEditable },"the title's text field")
        XCTAssertTrue(window.makeFirstResponder(field)); try await spin(60)
        XCTAssertEqual(try orange(view),0,"no note below the limit")
        field.selectAll(nil)
        field.insertText(String(repeating:"가",count:2500),replacementRange:caret)
        try await spin(400)
        let limit = InspectorPanel.textLimit
        XCTAssertEqual(field.string.count,limit,"the field shows what the title keeps")
        XCTAssertEqual(style(store,a.id).text.count,limit)
        XCTAssertGreaterThan(try orange(view),40,"the note is shown")
        // A key in the middle of the full title adds nothing and takes nothing off its end.
        let full = field.string
        field.setSelectedRange(NSRange(location:10,length:0))
        field.insertText("X",replacementRange:caret)
        try await spin(400)
        XCTAssertTrue(field.string == full && style(store,a.id).text == full,"a key in the full title changed it")
        // One character less: the note goes.
        field.setSelectedRange(NSRange(location:(full as NSString).length,length:0))
        field.deleteBackward(nil)
        try await spin(400)
        XCTAssertEqual(style(store,a.id).text.count,limit-1)
        XCTAssertEqual(try orange(view),0,"the note goes below the limit")
    }

    // MARK: effects

    /// Outline width and shadow opacity switch their effects on. A value their label reads as 0 is
    /// 0: the effect is off, its colour wells are off, and nothing is drawn.
    func testAnEffectThatReadsZeroIsOff() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        store.fontFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-inspector-fonts-\(UUID().uuidString)")
        let a = title("Effects") { $0.outlineWidth = 4; $0.shadowOpacity = 0.5 }
        store.edit("Fixture") { $0.clips = [a] }
        store.selectedClipID = a.id
        func slide(_ key: WritableKeyPath<ClipStyle,Double>, _ value: Double, _ range: ClosedRange<Double>, multiplier: Double = 1, switches: Bool = true) {
            InspectorPanel.slide(key,to:value,range:range,multiplier:multiplier,switches:switches,of:a.id,name:"Effect",closesWhenIdle:false,in:store)
            store.endLiveEdit()
        }
        slide(\.outlineWidth,0.4,0...20)
        XCTAssertEqual(style(store,a.id).outlineWidth,0); XCTAssertFalse(style(store,a.id).hasOutline)
        slide(\.outlineWidth,0.5,0...20)
        XCTAssertEqual(style(store,a.id).outlineWidth,0.5); XCTAssertEqual(InspectorPanel.reading(0.5),"1","read as it is drawn: on")
        slide(\.shadowOpacity,0.004,0...1,multiplier:100)
        XCTAssertEqual(style(store,a.id).shadowOpacity,0); XCTAssertFalse(style(store,a.id).hasShadow)
        slide(\.shadowOpacity,0.005,0...1,multiplier:100)
        XCTAssertEqual(style(store,a.id).shadowOpacity,0.005); XCTAssertEqual(InspectorPanel.reading(0.005,multiplier:100),"1")
        XCTAssertEqual(InspectorPanel.reading(-0.2),"0","never “-0”")
        // One saved below a step before (an earlier Ara's slider left it there) is on and says so.
        XCTAssertEqual(InspectorPanel.reading(0.3,switches:true),"0.3")
        XCTAssertEqual(InspectorPanel.reading(0.0004,multiplier:100,switches:true),"0.1")
        XCTAssertEqual(InspectorPanel.reading(0,switches:true),"0")
        // A slider that switches nothing keeps small values.
        slide(\.shadowDistance,0.4,0...40,switches:false)
        XCTAssertEqual(style(store,a.id).shadowDistance,0.4)
        // Read as 0 in the panel: the outline's colour well is off with it.
        slide(\.outlineWidth,0.3,0...20)
        let (window,view) = host(InspectorPanel(store:store))
        defer { window.contentView = nil; window.close() }
        try await spin(150); view.layoutSubtreeIfNeeded()
        let wells = all(NSColorWell.self,in:view).sorted { $0.convert($0.bounds,to:nil).maxY > $1.convert($1.bounds,to:nil).maxY }
        XCTAssertEqual(wells.count,3,"text, outline and shadow colours")
        XCTAssertEqual(wells.map(\.isEnabled),[true,false,true])
    }

    // MARK: header and tabs

    /// At the side panel's narrowest (250 points, 218 inside the inspector's margins) the clip's
    /// track line and the alignment-point buttons keep the lines they have in a wide panel, and
    /// the tab titles stay on one line.
    func testTheHeaderAndTabsKeepTheirLinesAtThePanelsNarrowest() {
        _ = NSApplication.shared
        let store = EditorStore()
        let media = timelineTestVideo(), link = UUID()
        let video = Clip(mediaID:media.id,name:"base.mp4",kind:.video,lane:.v1,start:.zero,duration:.init(seconds:5),linkID:link)
        let audio = Clip(mediaID:media.id,name:"base.mp4",kind:.audio,lane:.a1,start:.zero,duration:.init(seconds:5),linkID:link)
        store.edit("Fixture") { $0.media = [media]; $0.clips = [video,audio] }
        store.selectedClipID = video.id
        func height<Root: View>(_ root: Root, _ width: CGFloat) -> CGFloat {
            NSHostingController(rootView:root).sizeThatFits(in:CGSize(width:width,height:10_000)).height
        }
        for placing in [false,true] {
            store.anchorEditID = placing ? video.id : nil
            let header = ClipHeader(store:store,clip:video)
            XCTAssertEqual(height(header,218),height(header,1000),placing ? "placing" : "idle")
        }
        store.anchorEditID = nil
        for tab in EditorStore.SidePanel.allCases {
            store.sidePanel = tab
            XCTAssertEqual(height(SidePanelTabs(store:store),250),height(SidePanelTabs(store:store),1000),"\(tab)")
        }
    }

    /// With nothing to reset, the Reset button is dimmed once, as disabled, and stays readable.
    func testTheResetButtonStaysLegibleWithNothingToReset() throws {
        _ = NSApplication.shared
        let store = EditorStore()
        let media = timelineTestVideo()
        let video = Clip(mediaID:media.id,name:"base.mp4",kind:.video,lane:.v1,start:.zero,duration:.init(seconds:5))
        store.edit("Fixture") { $0.media = [media]; $0.clips = [video] }
        store.selectedClipID = video.id; store.anchorEditID = video.id
        let (window,view) = host(ClipHeader(store:store,clip:video).padding(16).frame(width:250,alignment:.leading).background(Theme.panel).preferredColorScheme(.dark),
                                 width:250,height:110)
        defer { window.contentView = nil; window.close() }
        RunLoop.main.run(until:Date().addingTimeInterval(0.15))
        let context = try painted(view), scale = Double(context.width)/250
        func accent(_ x: Int, _ y: Int) -> Bool { let c = TimelineRig.color(context,Double(x),Double(y)); return c.blue > 215 && (115...190).contains(c.red) }
        func luminance(_ x: Int, _ y: Int) -> Double {
            let c = TimelineRig.color(context,Double(x),Double(y))
            func linear(_ v: Int) -> Double { let v = Double(v)/255; return v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
            return 0.2126*linear(c.red)+0.7152*linear(c.green)+0.0722*linear(c.blue)
        }
        // The buttons' row, found by Done's accent fill; Reset is to the right of Done.
        let rows = (0..<context.height).filter { accent(Int(18*scale),$0) }
        let top = try XCTUnwrap(rows.first,"the Done button"), bottom = try XCTUnwrap(rows.last), middle = (top+bottom)/2
        let doneEnd = try XCTUnwrap((0..<Int(150*scale)).last { accent($0,middle) })
        var brightest = 0.0, counts: [Int:Int] = [:], shades: [Int:Double] = [:]
        for y in (top+3)..<(bottom-3) { for x in (doneEnd+Int(10*scale))..<Int(240*scale) {
            let l = luminance(x,y), key = Int(l*10_000)
            brightest = max(brightest,l); counts[key,default:0] += 1; shades[key] = l
        }}
        let background = try XCTUnwrap(counts.max { $0.value < $1.value }.flatMap { shades[$0.key] })
        let contrast = (brightest+0.05)/(background+0.05)
        XCTAssertGreaterThan(contrast,3,"the disabled Reset label against its button")
    }
}
