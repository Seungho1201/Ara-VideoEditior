import AppKit
import SwiftUI
import Vision
import XCTest
import FrameCore
@testable import FrameStudio

@MainActor private final class InspectorTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// The inspector's folding sections (SHADOW, TRANSFORM, COLOUR) unfolded, as a panel first shows them, for tests
/// that reach into them; returns what puts the user's choice back.
func inspectorSectionsUnfolded() -> () -> Void {
    let keys = InspectorPanelTests.foldKeys, defaults = UserDefaults.standard
    let saved = keys.map { defaults.object(forKey:$0) }
    for key in keys { defaults.removeObject(forKey:key) }
    return { for (key,value) in zip(keys,saved) { if let value { defaults.set(value,forKey:key) } else { defaults.removeObject(forKey:key) } } }
}

/// The inspector: its Rotation and Scale sliders keep the alignment point still, a title's text
/// field holds what the title keeps, an effect that reads 0 is off, SHADOW, TRANSFORM and COLOUR
/// fold away, TIMING comes last, and its header and the side panel's tabs keep their lines at the panel's narrowest.
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
        for value in values { InspectorContent.slide(key,to:value,range:range,of:id,name:"Adjust clip",closesWhenIdle:false,in:store) }
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
        let limit = InspectorContent.textLimit
        let full = String(repeating:"a",count:limit)
        XCTAssertEqual(InspectorContent.fitted("short",after:""),"short")
        XCTAssertTrue(InspectorContent.fitted(String(repeating:"가",count:limit+500),after:"") == String(repeating:"가",count:limit),"a long paste is cut")
        XCTAssertTrue(InspectorContent.fitted("aaaaXaaaa"+full.dropFirst(8),after:full) == full,"a key in a full title changes nothing")
        let middle = "ab"+String(repeating:"x",count:limit)+"cd"
        XCTAssertTrue(InspectorContent.fitted(middle,after:"abcd") == "ab"+String(repeating:"x",count:limit-4)+"cd","a paste in the middle keeps the end")
        XCTAssertEqual(InspectorContent.fitted(String(repeating:"y",count:limit+10),after:"old text").count,limit)
        // The caret goes after what was kept of the typing, counted as the text view counts (UTF-16).
        XCTAssertEqual(InspectorContent.fitting(middle,after:"abcd").caret,limit-2)
        XCTAssertEqual(InspectorContent.fitting("aaaaXaaaa"+full.dropFirst(8),after:full).caret,4)
        XCTAssertEqual(InspectorContent.fitting("👍"+String(repeating:"z",count:limit),after:"👍").caret,2+limit-1)
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
        XCTAssertEqual(field.string.count,InspectorContent.textLimit)
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
        let limit = InspectorContent.textLimit
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
    /// 0: the effect is off, its colour is off, and nothing is drawn.
    func testAnEffectThatReadsZeroIsOff() async throws {
        _ = NSApplication.shared
        let restore = inspectorSectionsUnfolded(); defer { restore() }
        let store = EditorStore()
        store.fontFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-inspector-fonts-\(UUID().uuidString)")
        let a = title("Effects") { $0.outlineWidth = 4; $0.shadowOpacity = 0.5 }
        store.edit("Fixture") { $0.clips = [a] }
        store.selectedClipID = a.id
        func slide(_ key: WritableKeyPath<ClipStyle,Double>, _ value: Double, _ range: ClosedRange<Double>, multiplier: Double = 1, switches: Bool = true) {
            InspectorContent.slide(key,to:value,range:range,multiplier:multiplier,switches:switches,of:a.id,name:"Effect",closesWhenIdle:false,in:store)
            store.endLiveEdit()
        }
        slide(\.outlineWidth,0.4,0...20)
        XCTAssertEqual(style(store,a.id).outlineWidth,0); XCTAssertFalse(style(store,a.id).hasOutline)
        slide(\.outlineWidth,0.5,0...20)
        XCTAssertEqual(style(store,a.id).outlineWidth,0.5); XCTAssertEqual(InspectorContent.reading(0.5),"1","read as it is drawn: on")
        slide(\.shadowOpacity,0.004,0...1,multiplier:100)
        XCTAssertEqual(style(store,a.id).shadowOpacity,0); XCTAssertFalse(style(store,a.id).hasShadow)
        slide(\.shadowOpacity,0.005,0...1,multiplier:100)
        XCTAssertEqual(style(store,a.id).shadowOpacity,0.005); XCTAssertEqual(InspectorContent.reading(0.005,multiplier:100),"1")
        XCTAssertEqual(InspectorContent.reading(-0.2),"0","never “-0”")
        // One saved below a step before (an earlier Ara's slider left it there) is on and says so.
        XCTAssertEqual(InspectorContent.reading(0.3,switches:true),"0.3")
        XCTAssertEqual(InspectorContent.reading(0.0004,multiplier:100,switches:true),"0.1")
        XCTAssertEqual(InspectorContent.reading(0,switches:true),"0")
        // A slider that switches nothing keeps small values.
        slide(\.shadowDistance,0.4,0...40,switches:false)
        XCTAssertEqual(style(store,a.id).shadowDistance,0.4)
        // Read as 0 in the panel: the outline's colour is off with it, and shows no presets.
        slide(\.outlineWidth,0.3,0...20)
        let (window,view) = host(InspectorPanel(store:store))
        defer { window.contentView = nil; window.close() }
        try await spin(150); view.layoutSubtreeIfNeeded()
        var shown: [Bool] = []
        for colour in ["Text colour","Outline colour","Shadow colour"] {
            store.colorPresetRow.click(colour,at:0,interval:0)
            for _ in 0..<12 where store.colorPresetRow.open == colour { view.layoutSubtreeIfNeeded(); try await spin(25) }
            shown.append(store.colorPresetRow.open == colour)
        }
        XCTAssertEqual(shown,[true,false,true])
    }

    // MARK: folding sections

    nonisolated static let foldKeys = ["inspector.shadowOpen","inspector.transformOpen","inspector.colourOpen"]
    /// The lines of text drawn in `view`, top to bottom, each with the top of its box in points.
    /// Read in overlapping bands: in one tall, mostly empty picture the recognizer drops lines.
    private func lines(_ view: NSView) throws -> [(text: String, top: CGFloat)] {
        let image = try XCTUnwrap(try painted(view).makeImage())
        let scale = CGFloat(image.height)/view.bounds.height, band = 800, step = 600
        var found: [(text: String, top: CGFloat)] = []
        for start in stride(from:0,to:max(1,image.height-band+step),by:step) {
            let height = min(band,image.height-start)
            let part = try XCTUnwrap(image.cropping(to:CGRect(x:0,y:start,width:image.width,height:height)))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage:part).perform([request])
            for line in request.results ?? [] {
                guard let text = line.topCandidates(1).first?.string else { continue }
                let top = (CGFloat(start)+(1-line.boundingBox.maxY)*CGFloat(height))/scale
                if !found.contains(where: { $0.text == text && abs($0.top-top) < 6 }) { found.append((text,top)) }
            }
        }
        return found.sorted { $0.top < $1.top }
    }
    /// Where the line starting with `text` is. Rows' labels, not the spaced capitals of the section
    /// titles, which the text recognizer can miss.
    private func top(_ text: String, in lines: [(text: String, top: CGFloat)], file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat {
        try XCTUnwrap(lines.first { $0.text.hasPrefix(text) }?.top,"“\(text)” in \(lines.map(\.text))",file:file,line:line)
    }

    /// A title's inspector reads TEXT, OUTLINE, SHADOW, TRANSFORM, COLOUR, then TIMING and the
    /// Reset button last. Folded, SHADOW says Off and TRANSFORM and COLOUR say Default or Edited;
    /// OUTLINE has no fold and keeps its controls.
    func testTimingComesLastAndFoldedSectionsSayWhatTheyHold() async throws {
        _ = NSApplication.shared
        let restore = inspectorSectionsUnfolded(); defer { restore() }
        let store = EditorStore()
        store.fontFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-inspector-fonts-\(UUID().uuidString)")
        let a = title("Effects") { $0.outlineWidth = 4; $0.saturation = 1.4 }
        store.edit("Fixture") { $0.clips = [a] }
        store.selectedClipID = a.id
        let (window,view) = host(InspectorPanel(store:store).preferredColorScheme(.dark),width:300,height:1800)
        window.appearance = NSAppearance(named:.darkAqua)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<12 { view.layoutSubtreeIfNeeded(); try await spin(25) }
        var shown = try lines(view)
        // A row from each section: TEXT's look, OUTLINE, SHADOW, TRANSFORM, COLOUR, TIMING, then Reset.
        let order = try ["Style","OUTLINE","Shadow colour","Position X","Brightness","Start","Reset appearance"].map { try top($0,in:shown) }
        XCTAssertEqual(order,order.sorted(),"\(shown.map(\.text))")

        for key in Self.foldKeys { UserDefaults.standard.set(false,forKey:key) }
        for _ in 0..<12 { view.layoutSubtreeIfNeeded(); try await spin(25) }
        shown = try lines(view)
        for gone in ["Position X","Brightness","Distance","Shadow colour"] { XCTAssertNil(shown.first { $0.text.hasPrefix(gone) },"\(gone) folded away") }
        XCTAssertGreaterThan(try top("4",in:shown),try top("OUTLINE",in:shown),"OUTLINE does not fold: its width still shows")
        // Each folded title's line says what it holds; TIMING's rows and Reset still come last.
        let folded = try ["OUTLINE","Off","Default","Edited","Start","Reset appearance"].map { try top($0,in:shown) }
        XCTAssertEqual(folded,folded.sorted(),"\(shown.map(\.text))")
    }

    /// Beside Adjust Alignment Point: where the alignment point is, in whole pixels of the frame
    /// from its top-left corner (the middle until the point is moved), and typed to move the clip
    /// there. While a number is typed the frame keys stand down, so the arrows move the caret.
    func testTheAlignmentPointIsShownAndTypedInPixels() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        store.fontFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-inspector-fonts-\(UUID().uuidString)")
        let a = title("Hello")
        store.edit("Fixture") { $0.clips = [a] }
        store.selectedClipID = a.id
        try await settle(store)
        let (window,view) = host(InspectorPanel(store:store))
        defer { window.contentView = nil; window.close(); store.pause() }
        try await spin(150)
        func fields() -> [NSTextField] { all(NSTextField.self,in:view).filter(\.isEditable) }
        let x = try XCTUnwrap(fields().first { $0.stringValue == "960" },"\(fields().map(\.stringValue))")
        XCTAssertNotNil(fields().first { $0.stringValue == "540" },"the middle of a 1920 × 1080 frame")
        XCTAssertTrue(window.makeFirstResponder(x)); try await spin(60)
        XCTAssertTrue(store.isEditingText,"the frame keys stand down while a number is typed")
        let editor = try XCTUnwrap(x.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText("1000",replacementRange:caret); editor.insertNewline(nil)
        try await spin(150)
        XCTAssertEqual(store.anchorPixel(of:store.project.clips[0]).x,1000); XCTAssertEqual(store.anchorPixel(of:store.project.clips[0]).y,540,"Y left alone")
        XCTAssertEqual(style(store,a.id).x,40.0/1920,accuracy:1e-9,"the clip moved, its middle with it")
        XCTAssertEqual(store.undoName,"Adjust clip")
        window.makeFirstResponder(nil); try await spin(60)
        XCTAssertFalse(store.isEditingText)
        store.undo(); try await spin(100)
        XCTAssertEqual(style(store,a.id).x,0,"one undo step")
        // With the point moved to the clip's right edge, the numbers are the point's, not the middle's.
        store.updateStyleLive(a.id,name:"Alignment point",closesWhenIdle:false) { $0.anchorX = 0.5 }; store.endLiveEdit()
        try await spin(200)
        let point = store.anchorPixel(of:store.project.clips[0])
        XCTAssertGreaterThan(point.x,980,"right of the middle"); XCTAssertEqual(point.y,540)
        XCTAssertNotNil(fields().first { $0.stringValue == "\(point.x)" },"\(fields().map(\.stringValue))")
        store.placeAnchor(of:a.id,x:100,y:200)
        XCTAssertTrue(store.anchorPixel(of:store.project.clips[0]) == (100,200),"the point lands where typed")
        XCTAssertEqual(style(store,a.id).anchorX,0.5,"the point stays where it is in the clip")
    }

    /// A title's colour, size slider and size share a line; the size is typed too (one undo step).
    /// While the colour's presets are shown the slider and the size make way for them.
    func testTheColourSliderAndSizeShareALine() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        store.fontFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-inspector-fonts-\(UUID().uuidString)")
        let a = title("Size") { $0.fontSize = 72 }
        store.edit("Fixture") { $0.clips = [a] }
        store.selectedClipID = a.id
        try await settle(store)
        let (window,view) = host(InspectorPanel(store:store))
        defer { window.contentView = nil; window.close(); store.pause() }
        try await spin(150)
        func fields() -> [NSTextField] { all(NSTextField.self,in:view).filter(\.isEditable) }
        let size = try XCTUnwrap(fields().first { $0.stringValue == "72" },"\(fields().map(\.stringValue))")
        XCTAssertTrue(window.makeFirstResponder(size)); try await spin(60)
        XCTAssertTrue(store.isEditingText,"the frame keys stand down while the size is typed")
        let editor = try XCTUnwrap(size.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText("120",replacementRange:caret); editor.insertNewline(nil)
        try await spin(150)
        XCTAssertEqual(style(store,a.id).fontSize,120); XCTAssertEqual(store.undoName,"Font size")
        editor.selectAll(nil); editor.insertText("999",replacementRange:caret); editor.insertNewline(nil)
        try await spin(150)
        XCTAssertEqual(style(store,a.id).fontSize,300,"kept within the slider's reach")
        window.makeFirstResponder(nil); try await spin(60)
        // The colour's presets take the line: the size steps aside, and comes back.
        store.colorPresetRow.click("Text colour",at:0,interval:0.5)
        for _ in 0..<10 { view.layoutSubtreeIfNeeded(); try await spin(25) }
        XCTAssertNil(fields().first { $0.stringValue == "300" },"out of the presets' way")
        store.colorPresetRow.close("Text colour")
        for _ in 0..<10 { view.layoutSubtreeIfNeeded(); try await spin(25) }
        XCTAssertNotNil(fields().first { $0.stringValue == "300" })
        store.undo(); store.undo()
        XCTAssertEqual(style(store,a.id).fontSize,72,"each typed size was one step")
    }

    /// The outline's colour, width slider and width share a line as the text's colour and size do.
    /// A width typed that reads 0 switches the outline off; its presets have the line while shown.
    func testTheOutlineColourAndWidthShareALine() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        store.fontFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-inspector-fonts-\(UUID().uuidString)")
        let a = title("Outline") { $0.fontSize = 72; $0.outlineWidth = 4 }
        store.edit("Fixture") { $0.clips = [a] }
        store.selectedClipID = a.id
        try await settle(store)
        let (window,view) = host(InspectorPanel(store:store))
        defer { window.contentView = nil; window.close(); store.pause() }
        try await spin(150)
        func fields() -> [NSTextField] { all(NSTextField.self,in:view).filter(\.isEditable) }
        func type(_ text: String, into field: NSTextField) async throws {
            XCTAssertTrue(window.makeFirstResponder(field)); try await spin(40)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.selectAll(nil); editor.insertText(text,replacementRange:caret); editor.insertNewline(nil)
            try await spin(150)
        }
        let width = try XCTUnwrap(fields().first { $0.stringValue == "4" },"\(fields().map(\.stringValue))")
        try await type("0.3",into:width)
        XCTAssertEqual(style(store,a.id).outlineWidth,0,"reads 0: off"); XCTAssertEqual(store.undoName,"Outline")
        try await type("2.5",into:width)
        XCTAssertEqual(style(store,a.id).outlineWidth,2.5); XCTAssertEqual(width.stringValue,"2.5")
        window.makeFirstResponder(nil); try await spin(60)
        store.colorPresetRow.click("Outline colour",at:0,interval:0.5)
        for _ in 0..<10 { view.layoutSubtreeIfNeeded(); try await spin(25) }
        XCTAssertNil(fields().first { $0.stringValue == "2.5" },"out of the presets' way")
        XCTAssertNotNil(fields().first { $0.stringValue == "72" },"the text's size stays: only the outline's line is taken")
    }

    /// AUDIO is the volume's slider and its percentage typed, as the title's amounts are; there is
    /// no mute switch. A clip muted by an earlier Ara reads 0 %, and a volume typed unmutes it and
    /// reaches the linked sound.
    func testTheVolumeIsASliderAndAPercentage() async throws {
        _ = NSApplication.shared
        let store = EditorStore()
        let media = timelineTestVideo(), link = UUID()
        var video = Clip(mediaID:media.id,name:"base.mp4",kind:.video,lane:.v1,start:.zero,duration:.init(seconds:5),linkID:link)
        var sound = Clip(mediaID:media.id,name:"base.mp4",kind:.audio,lane:.a1,start:.zero,duration:.init(seconds:5),linkID:link)
        video.style.muted = true; sound.style.muted = true
        store.edit("Fixture") { $0.media = [media]; $0.clips = [video,sound] }
        store.selectedClipID = video.id
        let (window,view) = host(InspectorPanel(store:store))
        defer { window.contentView = nil; window.close(); store.pause() }
        try await spin(150)
        XCTAssertTrue(all(NSSwitch.self,in:view).isEmpty && all(NSButton.self,in:view).allSatisfy { ($0.cell as? NSButtonCell)?.title != "Mute" },"no mute switch")
        let fields = all(NSTextField.self,in:view).filter(\.isEditable)
        let volume = try XCTUnwrap(fields.first { $0.stringValue == "0" },"muted reads 0 %: \(fields.map(\.stringValue))")
        XCTAssertTrue(window.makeFirstResponder(volume)); try await spin(40)
        let editor = try XCTUnwrap(volume.currentEditor() as? NSTextView)
        XCTAssertTrue(style(store,video.id).muted,"taking the keyboard changes nothing"); XCTAssertEqual(style(store,video.id).volume,1)
        editor.selectAll(nil); editor.insertText("150",replacementRange:caret); editor.insertNewline(nil)
        try await spin(150)
        XCTAssertEqual(style(store,video.id).volume,1.5); XCTAssertFalse(style(store,video.id).muted,"unmuted")
        XCTAssertEqual(style(store,sound.id).volume,1.5,"the linked sound too"); XCTAssertFalse(style(store,sound.id).muted)
        editor.selectAll(nil); editor.insertText("500",replacementRange:caret); editor.insertNewline(nil)
        try await spin(150)
        XCTAssertEqual(style(store,video.id).volume,2,"at most 200 %")
        window.makeFirstResponder(nil)
    }

    /// STYLE holds a video's volume and opacity as slider-and-number lines, with the playback speed
    /// as one more line under them; the opacity moved there from TRANSFORM, whose folded summary no
    /// longer counts it. A title has the opacity line under its colour and size.
    func testStyleHoldsTheVolumeAndTheOpacity() async throws {
        _ = NSApplication.shared
        let restore = inspectorSectionsUnfolded(); defer { restore() }
        let store = EditorStore()
        store.fontFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-inspector-fonts-\(UUID().uuidString)")
        let media = timelineTestVideo(), link = UUID()
        let video = Clip(mediaID:media.id,name:"base.mp4",kind:.video,lane:.v1,start:.zero,duration:.init(seconds:5),linkID:link)
        let sound = Clip(mediaID:media.id,name:"base.mp4",kind:.audio,lane:.a1,start:.zero,duration:.init(seconds:5),linkID:link)
        let words = title("Words",lane:.v2)
        XCTAssertTrue(store.edit("Fixture") { $0.media = [media]; $0.videoTrackCount = 2; $0.clips = [video,sound,words] },store.message ?? "")
        store.selectedClipID = video.id
        let (window,view) = host(InspectorPanel(store:store))
        defer { window.contentView = nil; window.close(); store.pause() }
        try await spin(150)
        func fields() -> [NSTextField] { all(NSTextField.self,in:view).filter(\.isEditable) }
        XCTAssertEqual(fields().filter { $0.stringValue == "100" }.count,2,"volume and opacity at 100 %: \(fields().map(\.stringValue))")
        let opacity = try XCTUnwrap(fields().filter { $0.stringValue == "100" }.last)
        XCTAssertTrue(window.makeFirstResponder(opacity)); try await spin(40)
        let editor = try XCTUnwrap(opacity.currentEditor() as? NSTextView)
        editor.selectAll(nil); editor.insertText("40",replacementRange:caret); editor.insertNewline(nil)
        try await spin(150)
        XCTAssertEqual(style(store,video.id).opacity,0.4,accuracy:1e-9); XCTAssertEqual(style(store,video.id).volume,1,"the volume left alone")
        XCTAssertEqual(store.undoName,"Adjust clip")
        XCTAssertTrue(InspectorContent.isDefaultTransform(style(store,video.id)),"opacity is no longer TRANSFORM's")
        // The speed, a line under them: its number typed without the x, which sits beside it.
        let speed = try XCTUnwrap(fields().first { $0.stringValue == "1.00" },"\(fields().map(\.stringValue))")
        XCTAssertTrue(window.makeFirstResponder(speed)); try await spin(40)
        XCTAssertTrue(store.isEditingText,"the frame keys stand down while the speed is typed")
        let typing = try XCTUnwrap(speed.currentEditor() as? NSTextView)
        typing.selectAll(nil); typing.insertText("2",replacementRange:caret); typing.insertNewline(nil)
        try await spin(150)
        XCTAssertEqual(store.project.clips.first { $0.id == video.id }?.speed,2)
        window.makeFirstResponder(nil)
        // A title: its colour and size, then its opacity.
        store.selectedClipID = words.id; try await spin(150)
        XCTAssertNotNil(fields().first { $0.stringValue == "100" },"the title's opacity")
    }

    /// SHADOW, TRANSFORM and COLOUR fold under their titles: their controls go, the panel gets
    /// shorter, and each stays as it was left (kept in the defaults). Folding a colour away hides
    /// its presets.
    func testSectionsFoldUnderTheirTitles() async throws {
        _ = NSApplication.shared
        let restore = inspectorSectionsUnfolded(); defer { restore() }
        let defaults = UserDefaults.standard
        let store = EditorStore()
        store.fontFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-inspector-fonts-\(UUID().uuidString)")
        let a = title("Effects") { $0.outlineWidth = 4; $0.shadowOpacity = 0.5 }
        store.edit("Fixture") { $0.clips = [a] }
        store.selectedClipID = a.id
        let (window,view) = host(InspectorPanel(store:store))
        defer { window.contentView = nil; window.close() }
        func settled(_ view: NSView) async throws -> CGFloat {
            for _ in 0..<12 { view.layoutSubtreeIfNeeded(); try await spin(25) }
            return try XCTUnwrap(all(NSScrollView.self,in:view).first?.documentView).frame.height
        }
        let open = try await settled(view)
        store.colorPresetRow.click("Shadow colour",at:0,interval:0)
        XCTAssertEqual(store.colorPresetRow.open,"Shadow colour")
        // Folded as a click on the title folds it: through the defaults its switch is kept in.
        defaults.set(false,forKey:"inspector.shadowOpen")
        let noShadow = try await settled(view)
        XCTAssertLessThan(noShadow,open-150,"four sliders and the colour are gone")
        XCTAssertNil(store.colorPresetRow.open,"the folded colour's presets are hidden")
        defaults.set(false,forKey:"inspector.transformOpen")
        let noTransform = try await settled(view)
        XCTAssertLessThan(noTransform,noShadow-150,"five sliders are gone")
        defaults.set(false,forKey:"inspector.colourOpen")
        let folded = try await settled(view)
        XCTAssertLessThan(folded,noTransform-90,"three sliders are gone")
        // A panel made again (another launch) keeps them folded.
        let (again,second) = host(InspectorPanel(store:store))
        defer { again.contentView = nil; again.close() }
        let reopened = try await settled(second)
        XCTAssertEqual(reopened,folded,accuracy:1)
        for key in Self.foldKeys { defaults.set(true,forKey:key) }
        let unfolded = try await settled(view)
        XCTAssertEqual(unfolded,open,accuracy:1)
        XCTAssertNil(store.colorPresetRow.open,"unfolding shows the colour as it was left: closed")
    }

    /// A folded section is its title line alone; its content is laid out only while unfolded.
    func testAFoldedSectionIsItsTitleLine() {
        _ = NSApplication.shared
        func height(_ open: Bool, summary: FoldingSummary) -> CGFloat {
            let section = FoldingSection(title:"SHADOW",isOpen:.constant(open),summary:summary) { Color.red.frame(height:120) }
            return NSHostingController(rootView:section.frame(width:218)).sizeThatFits(in:CGSize(width:218,height:10_000)).height
        }
        let summaries: [FoldingSummary] = [.amount("60%",TitleColor(red:1,green:0,blue:0)),.off,.unchanged,.changed]
        XCTAssertGreaterThan(height(true,summary:summaries[0]),120)
        for summary in summaries { XCTAssertLessThan(height(false,summary:summary),20,"\(summary)") }
    }

    // MARK: header and tabs

    /// At the side panel's narrowest (250 points, 218 inside the inspector's margins) the clip's
    /// name line and the alignment-point buttons and coordinates keep the lines they have in a wide
    /// panel, and the tab titles stay on one line.
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
            let header = ClipHeader(store:store,clip:video), alignment = AlignmentControls(store:store,clip:video)
            XCTAssertEqual(height(header,218),height(header,1000),placing ? "placing" : "idle")
            XCTAssertEqual(height(alignment,218),height(alignment,1000),placing ? "placing" : "idle")
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
        let (window,view) = host(AlignmentControls(store:store,clip:video).padding(16).frame(width:250,alignment:.leading).background(Theme.panel).preferredColorScheme(.dark),
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
        // The buttons' row, found by Done's accent fill; Reset is the 28-point button right of Done.
        let rows = (0..<context.height).filter { accent(Int(18*scale),$0) }
        let top = try XCTUnwrap(rows.first,"the Done button"), bottom = try XCTUnwrap(rows.last), middle = (top+bottom)/2
        let doneEnd = try XCTUnwrap((0..<Int(150*scale)).last { accent($0,middle) })
        var brightest = 0.0, counts: [Int:Int] = [:], shades: [Int:Double] = [:]
        for y in (top+3)..<(bottom-3) { for x in (doneEnd+Int(9*scale))..<(doneEnd+Int(31*scale)) {
            let l = luminance(x,y), key = Int(l*10_000)
            brightest = max(brightest,l); counts[key,default:0] += 1; shades[key] = l
        }}
        let background = try XCTUnwrap(counts.max { $0.value < $1.value }.flatMap { shades[$0.key] })
        let contrast = (brightest+0.05)/(background+0.05)
        XCTAssertGreaterThan(contrast,3,"the disabled Reset label against its button")
    }
}
