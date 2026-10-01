import SwiftUI
import AppKit
import Combine
import FrameCore

// MARK: - Colours

/// A title colour as ClipStyle keeps it: sRGB, each component 0…1.
struct TitleColor: Hashable, Sendable {
    var red: Double, green: Double, blue: Double
    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    /// "#RRGGBB" or "RRGGBB", or the short "#RGB" (each digit doubled), in either case; nil for
    /// anything else.
    init?(hex text: String) {
        var digits = Substring(text.trimmingCharacters(in:.whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 3 || digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        let full = digits.count == 3 ? String(digits.flatMap { [$0,$0] }) : String(digits)
        guard let value = UInt32(full,radix:16) else { return nil }
        self.init(red:Double(value >> 16 & 0xFF)/255,green:Double(value >> 8 & 0xFF)/255,blue:Double(value & 0xFF)/255)
    }
    /// What was typed in a hex field, read as the keys pressed: with the Korean input source on,
    /// a–f type ㅁ ㅠ ㅊ ㅇ ㄷ ㄹ, and those join into syllables (ㄹ and ㅠ make 류).
    init?(typed text: String) {
        let keys: [Unicode.Scalar:String] = ["\u{1106}":"a","\u{110E}":"c","\u{110B}":"d","\u{1103}":"e","\u{1104}":"e","\u{1105}":"f","\u{1172}":"b",
                                             "\u{11B7}":"a","\u{11BE}":"c","\u{11BC}":"d","\u{11AE}":"e","\u{11AF}":"f","\u{11B1}":"fa"]
        // Compatibility decomposition splits syllables and turns lone and full-width letters into these.
        self.init(hex:text.decomposedStringWithCompatibilityMapping.unicodeScalars.map { keys[$0] ?? String($0) }.joined())
    }
    /// The colour of an AppKit colour (the colour panel's, the eyedropper's), in sRGB.
    init?(_ color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        func unit(_ v: CGFloat) -> Double { min(1,max(0,Double(v))) }
        self.init(red:unit(c.redComponent),green:unit(c.greenComponent),blue:unit(c.blueComponent))
    }
    /// "#RRGGBB", each component rounded to 8 bits.
    var hex: String {
        func byte(_ v: Double) -> Int { Int((min(1,max(0,v))*255).rounded()) }
        return String(format:"#%02X%02X%02X",byte(red),byte(green),byte(blue))
    }
    /// Within half an 8-bit step in every component: the same colour.
    func isClose(to other: TitleColor) -> Bool {
        let step = 0.5/255
        return abs(red-other.red) <= step && abs(green-other.green) <= step && abs(blue-other.blue) <= step
    }
    /// The colour at a hue, saturation and brightness. The six primaries and secondaries come out
    /// exactly (0 or 1 in each component).
    init(_ c: HSB) {
        var sector = (c.hue-c.hue.rounded(.down))*6
        if abs(sector-sector.rounded()) < 1e-9 { sector = sector.rounded() }
        let f = sector-sector.rounded(.down), v = c.brightness, s = c.saturation
        let p = v*(1-s), q = v*(1-s*f), t = v*(1-s*(1-f))
        switch Int(sector) % 6 {
        case 0: self.init(red:v,green:t,blue:p)
        case 1: self.init(red:q,green:v,blue:p)
        case 2: self.init(red:p,green:v,blue:t)
        case 3: self.init(red:p,green:q,blue:v)
        case 4: self.init(red:t,green:p,blue:v)
        default: self.init(red:v,green:p,blue:q)
        }
    }
    /// The colour's hue, saturation and brightness. A grey has no hue, and black no saturation
    /// either: `kept`'s are used, so a drag through white or black keeps its hue.
    func hsb(keeping kept: HSB = HSB(hue:0,saturation:0,brightness:0)) -> HSB {
        let high = max(red,green,blue), delta = high-min(red,green,blue)
        guard high > 0 else { return HSB(hue:kept.hue,saturation:kept.saturation,brightness:0) }
        guard delta > 0 else { return HSB(hue:kept.hue,saturation:0,brightness:high) }
        var hue = high == red ? (green-blue)/delta : high == green ? (blue-red)/delta+2 : (red-green)/delta+4
        hue /= 6; if hue < 0 { hue += 1 }
        return HSB(hue:hue,saturation:delta/high,brightness:high)
    }
    /// The colours offered beside a title colour's swatch and in the palette, with their names
    /// (the string table's keys).
    static let presets: [(name: String, color: TitleColor)] = [
        ("White",TitleColor(red:1,green:1,blue:1)),("Black",TitleColor(red:0,green:0,blue:0)),
        ("Yellow",TitleColor(hex:"#FFD60A")!),("Orange",TitleColor(hex:"#FF9F0A")!),("Red",TitleColor(hex:"#FF453A")!),
        ("Green",TitleColor(hex:"#30D158")!),("Blue",TitleColor(hex:"#0A84FF")!),("Purple",TitleColor(hex:"#BF5AF2")!)]
    /// What VoiceOver calls the colour: a preset's name, or its hex value.
    var spokenName: String {
        Self.presets.first { $0.color.hex == hex }.map { Bundle.main.localizedString(forKey:$0.name,value:$0.name,table:nil) } ?? hex
    }
}

/// Hue, saturation and brightness, each 0…1 (a hue of 1 is red again).
struct HSB: Hashable, Sendable { var hue: Double, saturation: Double, brightness: Double }

extension Color {
    init(_ rgb: TitleColor) { self.init(.sRGB,red:rgb.red,green:rgb.green,blue:rgb.blue) }
}

/// Which title colour shows its presets beside its swatch, by its label: one at a time. A click on
/// a swatch shows them and another hides them, but not the second click of a double-click: one
/// within the Mac's double-click interval of the click that showed them leaves them shown.
struct ColorPresetRow: Equatable {
    private(set) var open: String?
    private var openedAt = -Double.infinity
    mutating func click(_ row: String, at time: TimeInterval, interval: TimeInterval) {
        if open != row { open = row; openedAt = time } else if time-openedAt > interval { open = nil }
    }
    @MainActor mutating func click(_ row: String, at time: TimeInterval) { click(row,at:time,interval:NSEvent.doubleClickInterval) }
    /// Hides the presets (only `row`'s, when given).
    mutating func close(_ row: String? = nil) { if row == nil || open == row { open = nil } }
}

/// The colours last put on titles with these controls, newest first and each once, for the
/// palette's Recent row. Kept as hex in the app's defaults, so they are there next time.
@MainActor final class RecentColors: ObservableObject {
    static let shared = RecentColors()
    static let key = "colors.recent", limit = 8
    private let defaults: UserDefaults
    @Published private(set) var colors: [TitleColor]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var seen = Set<String>()
        colors = Array((defaults.stringArray(forKey:Self.key) ?? []).compactMap(TitleColor.init(hex:)).filter { seen.insert($0.hex).inserted }.prefix(Self.limit))
    }
    /// `color` (to 8 bits) goes first; the same colour further down goes, and the oldest past eight.
    func add(_ color: TitleColor) {
        guard let color = TitleColor(hex:color.hex), colors.first != color else { return }
        colors = Array(([color]+colors.filter { $0 != color }).prefix(Self.limit))
        defaults.set(colors.map(\.hex),forKey:Self.key)
    }
}

/// One colour of a title: its clip, its three ClipStyle components, and its name, which is the
/// inspector's label and the undo step's.
struct ColorTarget {
    let clipID: UUID
    let red: WritableKeyPath<ClipStyle,Double>, green: WritableKeyPath<ClipStyle,Double>, blue: WritableKeyPath<ClipStyle,Double>
    let name: String
    func current(in project: Project) -> TitleColor? {
        project.clips.first { $0.id == clipID }.map { TitleColor(red:$0.style[keyPath:red],green:$0.style[keyPath:green],blue:$0.style[keyPath:blue]) }
    }
    /// Shows `color` on the title at once, redrawn in the preview without a rebuild, as part of the
    /// open run of live edits (one undo step when it ends).
    @MainActor func preview(_ color: TitleColor, in store: EditorStore, closesWhenIdle: Bool = false) {
        // Within half an 8-bit step it is the colour the title has: the colour panel sends its
        // colour back after a colour-space round trip, and that is not an edit.
        guard let now = current(in:store.project), !now.isClose(to:color) else { return }
        store.updateStyleLive(clipID,name:name,closesWhenIdle:closesWhenIdle) { $0[keyPath:red] = color.red; $0[keyPath:green] = color.green; $0[keyPath:blue] = color.blue }
    }
    /// Puts `color` on the title as one undo step of its own, after the text just typed. Nothing
    /// lands while an export reads the project, so nothing is recent either.
    @MainActor func pick(_ color: TitleColor, in store: EditorStore, recents: RecentColors) {
        guard !store.isExporting else { return }
        store.commitPendingEdits()
        preview(color,in:store)
        store.endLiveEdit()
        recents.add(color)
    }
}

// MARK: - The inspector's control

/// A title colour in the inspector: its label and swatch. A click on the swatch (a double-click
/// too) shows preset colours to its right, as many as fit, each put on the title with a click and
/// one undo step, so they can be tried in turn; another click hides them. The last circle, +,
/// opens the palette. Choosing another clip, folding the control's section away, or the control
/// being switched off, hides them.
struct TitleColorControl: View {
    @ObservedObject var store: EditorStore
    let target: ColorTarget
    let color: TitleColor
    /// The colour's name before the swatch; left out on a line that says what it is otherwise.
    var showsName = true
    /// Whether the room for the presets is kept while they are hidden. A line with more on it
    /// (the title's size) lets them have it only while they are shown.
    var roomWhenClosed = true
    @Environment(\.isEnabled) private var isEnabled
    /// The width beside the swatch, where the presets go.
    @State private var room: CGFloat = 0
    /// The palette while it is open.
    @State private var palette: ColorPaletteModel?
    /// A circle's place (18 points and the space after it), and the space before the first.
    static let dot: CGFloat = 24, lead: CGFloat = 4
    private static let more = -1
    private var isOpen: Bool { isEnabled && store.colorPresetRow.open == target.name }
    /// How many presets fit in `room` with + after them.
    static func presetsFitting(_ room: CGFloat) -> Int { min(TitleColor.presets.count,max(0,Int((room-lead)/dot)-1)) }
    var body: some View {
        let shown = Self.presetsFitting(room)
        HStack(spacing:0) {
            if showsName { Text(LocalizedStringKey(target.name)).lineLimit(1).fixedSize() }
            swatch.padding(.leading,showsName ? 6 : 0).zIndex(1)
            // The presets are laid over the room beside the swatch, so showing them moves nothing.
            Color.clear.frame(maxWidth:roomWhenClosed || isOpen ? .infinity : 0).frame(height:26)
                .onGeometryChange(for:CGFloat.self) { $0.size.width } action: { room = $0 }
                .overlay(alignment:.leading) {
                    HStack(spacing:0) {
                        ForEach(isOpen ? Array(0..<shown)+[Self.more] : [],id:\.self) { item in
                            let position = item == Self.more ? shown : item
                            Group {
                                if item == Self.more { moreButton } else { presetButton(TitleColor.presets[item]) }
                            }.transition(fan(position))
                        }
                    }.padding(.leading,Self.lead)
                }
        }
        // A colour that is off (no outline, no shadow) shows no presets, now or when it comes back on.
        .onChange(of:!isEnabled && store.colorPresetRow.open == target.name,initial:true) { _,off in if off { store.colorPresetRow.close(target.name) } }
        .onChange(of:isOpen) { _,open in if !open { palette = nil } }
    }
    private var swatch: some View {
        Button {
            withAnimation(.snappy(duration:0.25)) { store.colorPresetRow.click(target.name,at:ProcessInfo.processInfo.systemUptime) }
        } label: {
            // Circular capsules: the continuous kind's stroke shows flat bits at its ends.
            Capsule(style:.circular).fill(Color(color)).frame(width:36,height:20)
                .overlay(Capsule(style:.circular).strokeBorder(.white.opacity(0.22),lineWidth:1))
                .padding(3)
                .overlay(Capsule(style:.circular).strokeBorder(isOpen ? Theme.accent : .clear,lineWidth:1.5))
                .contentShape(Capsule(style:.circular))
        }
        .buttonStyle(DotPress()).contentShape(.focusEffect,Capsule(style:.circular))
        .opacity(isEnabled ? 1 : 0.4)
        .help(isOpen ? LocalizedStringKey("Click to hide the preset colours") : LocalizedStringKey("Click for preset colours · + opens the palette"))
        .accessibilityLabel(Text(verbatim:"\(Bundle.main.localizedString(forKey:target.name,value:target.name,table:nil)), \(color.spokenName)"))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
    private func presetButton(_ preset: (name: String, color: TitleColor)) -> some View {
        Button { target.pick(preset.color,in:store,recents:.shared) } label: { ColorDot(color:preset.color,isCurrent:preset.color.hex == color.hex) }
            .buttonStyle(DotPress()).contentShape(.focusEffect,Circle())
            .help(LocalizedStringKey(preset.name)).accessibilityLabel(Text(LocalizedStringKey(preset.name)))
            .accessibilityAddTraits(preset.color.hex == color.hex ? .isSelected : [])
    }
    private var moreButton: some View {
        Button {
            // The click on + that closed the palette does not open it again.
            guard palette == nil, ProcessInfo.processInfo.systemUptime-PalettePopover.closed > 0.3 else { return }
            palette = ColorPaletteModel(store:store,target:target)
        } label: {
            Image(systemName:"plus").font(.system(size:9,weight:.bold)).foregroundStyle(palette != nil ? Theme.accent : Theme.muted)
                .frame(width:18,height:18).background(Theme.raised,in:Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14),lineWidth:1))
                .padding(3)
                .overlay(Circle().strokeBorder(palette != nil ? Theme.accent : .clear,lineWidth:1.5))
                .contentShape(Circle())
        }
        .buttonStyle(DotPress()).contentShape(.focusEffect,Circle())
        .background(PalettePopover(model:$palette))
        .help("More colours").accessibilityLabel("More colours")
    }
    /// Circles come out from under the swatch, one after another, and go back under it.
    private func fan(_ position: Int) -> AnyTransition {
        // From the swatch's middle: past its trailing half, the gap and the circles before this one.
        let x = -(21+Self.lead+CGFloat(position)*Self.dot+Self.dot/2)     // 21: half the swatch
        let folded = AnyTransition.modifier(active:Fan(x:x,out:false),identity:Fan(x:x,out:true))
        return .asymmetric(insertion:folded.animation(.spring(response:0.34,dampingFraction:0.74).delay(Double(position)*0.022)),
                           removal:folded.animation(.spring(response:0.24,dampingFraction:0.92)))
    }
    private struct Fan: ViewModifier {
        let x: CGFloat, out: Bool
        func body(content: Content) -> some View { content.scaleEffect(out ? 1 : 0.3).offset(x:out ? 0 : x).opacity(out ? 1 : 0) }
    }
}

/// A round swatch, ringed when it is the colour the title has, a little larger under the pointer.
private struct ColorDot: View {
    let color: TitleColor
    var size: CGFloat = 18
    var isCurrent = false
    @State private var hovered = false
    var body: some View {
        Circle().fill(Color(color)).frame(width:size,height:size)
            .overlay(Circle().strokeBorder(.white.opacity(0.2),lineWidth:1))
            .padding(3)
            .overlay(Circle().strokeBorder(isCurrent ? Theme.accent : .clear,lineWidth:1.5))
            .scaleEffect(hovered ? 1.1 : 1).animation(.easeOut(duration:0.12),value:hovered)
            .contentShape(Circle()).onHover { hovered = $0 }
    }
}

/// Swatches and circles give a little under the click.
private struct DotPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.88 : 1).animation(.easeOut(duration:0.1),value:configuration.isPressed)
    }
}

// MARK: - The palette

/// The palette's side of one title colour: the hue it shows, kept through greys (where the colour
/// itself has none), its drags (one undo step each), and the Mac's colour panel while it is open.
@MainActor final class ColorPaletteModel: ObservableObject {
    let store: EditorStore
    let target: ColorTarget
    let recents: RecentColors
    /// The colour as the square and the hue bar show it.
    @Published private(set) var hsb: HSB
    /// The colour a drag has put on the title so far; nil between drags.
    private var dragged: TitleColor?
    let panel = SystemColorPanel()
    private var following: AnyCancellable?
    private(set) var isClosed = false
    init(store: EditorStore, target: ColorTarget, recents: RecentColors = .shared) {
        self.store = store; self.target = target; self.recents = recents
        hsb = (target.current(in:store.project) ?? TitleColor(red:1,green:1,blue:1)).hsb()
        // Changes made elsewhere (undo, a swatch, the colour panel) show here, the hue kept for greys.
        following = store.$project.map { [target] in target.current(in:$0) }.removeDuplicates().sink { [weak self] color in
            MainActor.assumeIsolated {
                guard let self, let color, !color.isClose(to:self.shown) else { return }
                self.hsb = color.hsb(keeping:self.hsb)
            }
        }
    }
    var shown: TitleColor { TitleColor(hsb) }
    /// A step of a drag in the square or along the hue bar, shown on the title at once. The drag
    /// is one undo step, closed by `endDrag`; the text just typed lands first, as its own.
    func drag(to new: HSB) {
        guard !isClosed else { return }
        if dragged == nil { store.commitPendingEdits() }
        hsb = new; dragged = shown
        target.preview(shown,in:store)
    }
    func endDrag() {
        guard let color = dragged else { return }
        dragged = nil; store.endLiveEdit(); recents.add(color)
    }
    /// A colour chosen at once (a swatch, the hex field, the eyedropper): one undo step.
    func pick(_ color: TitleColor) {
        guard !isClosed else { return }
        endDrag()
        hsb = color.hsb(keeping:hsb)
        target.pick(color,in:store,recents:recents)
    }
    /// The hex field's text put on the title; false, changing nothing, when it is no colour.
    @discardableResult func commit(hex text: String) -> Bool {
        guard let color = TitleColor(typed:text) else { return false }
        pick(color); return true
    }
    /// A colour picked anywhere on the screen.
    func sample() {
        Task { [weak self] in
            guard let picked = await NSColorSampler().sample(), let color = TitleColor(picked) else { return }
            self?.pick(color)
        }
    }
    /// The Mac's colour panel, editing this colour until the palette closes.
    func showSystemPanel() {
        guard !isClosed else { return }
        endDrag()
        panel.show(shown) { [weak self] in self?.panelChanged($0) }
    }
    /// A colour from the Mac's colour panel: a live edit that closes after a pause, like the other
    /// live steps, as the panel sends no end to a drag.
    func panelChanged(_ color: TitleColor) {
        guard !isClosed else { return }
        target.preview(color,in:store,closesWhenIdle:true)
    }
    /// The palette closed: a drag still open ends, and the colour panel stops editing the title.
    func close() {
        guard !isClosed else { return }
        endDrag(); isClosed = true
        if let last = panel.detach() { recents.add(last) }
        store.endLiveEdit()
    }
}

/// The palette opened with +: saturation and brightness, hue, the hex value and the eyedropper,
/// the preset and recent colours, and the Mac's colour panel for anything else.
struct ColorPalette: View {
    @ObservedObject var model: ColorPaletteModel
    @ObservedObject var recents: RecentColors
    @State private var hex = ""
    @FocusState private var hexFocused: Bool
    static let width: CGFloat = 248
    var body: some View {
        let shown = model.shown
        VStack(alignment:.leading,spacing:12) {
            Text(LocalizedStringKey(model.target.name)).font(.system(size:12,weight:.semibold))
            SaturationBrightnessSquare(model:model).frame(height:148)
            HueBar(model:model).frame(height:18)
            HStack(spacing:10) {
                Circle().fill(Color(shown)).frame(width:30,height:30)
                    .overlay(Circle().strokeBorder(.white.opacity(0.2),lineWidth:1))
                    .accessibilityElement().accessibilityLabel("Current colour").accessibilityValue(Text(verbatim:shown.spokenName))
                TextField("",text:$hex)
                    .textFieldStyle(.plain).font(.system(size:11,design:.monospaced))
                    .focused($hexFocused).onSubmit(commitHex)
                    .padding(.horizontal,8).frame(width:92,height:26)
                    .background(Theme.background,in:RoundedRectangle(cornerRadius:6))
                    .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(hexFocused ? Theme.accent.opacity(0.8) : .white.opacity(0.1),lineWidth:1))
                    .help("Hex colour, such as #FFD60A or FD0 · Return to apply")
                    .accessibilityLabel("Hex colour")
                Spacer(minLength:0)
                Button { model.sample() } label: {
                    Image(systemName:"eyedropper").font(.system(size:12,weight:.medium)).frame(width:28,height:28)
                        .background(Theme.raised,in:RoundedRectangle(cornerRadius:6))
                        .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(.white.opacity(0.1),lineWidth:1))
                }
                .buttonStyle(DotPress())
                .help("Pick a colour from the screen").accessibilityLabel("Pick a colour from the screen")
            }
            swatches("BASIC",TitleColor.presets.map(\.color),current:shown)
            swatches("RECENT",recents.colors,current:shown)
            Divider().opacity(0.6)
            Button { model.showSystemPanel() } label: {
                Label("System Colours…",systemImage:"paintpalette").font(.system(size:11,weight:.medium))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .help("Change this colour in the Mac's colour panel while the palette is open")
        }
        .padding(14).frame(width:Self.width)
        .tint(Theme.accent)
        .onAppear { hex = shown.hex }
        // The field follows the colour, even with the focus (a popover gives it the focus), until
        // something is typed in it.
        .onChange(of:shown.hex) { old,now in if !hexFocused || hex == old { hex = now } }
        .onChange(of:hexFocused) { _,focused in if !focused { commitHex() } }
    }
    /// Applies the field's colour. What is no colour beeps and is put back.
    private func commitHex() {
        let shown = model.shown.hex
        if hex.trimmingCharacters(in:.whitespaces).uppercased() != shown, !model.commit(hex:hex) { NSSound.beep() }
        hex = model.shown.hex
    }
    /// A captioned row of eight places, filled from the left.
    private func swatches(_ title: String, _ colors: [TitleColor], current: TitleColor) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(LocalizedStringKey(title)).font(.system(size:9,weight:.bold)).tracking(1.4).foregroundStyle(Theme.muted)
            HStack(spacing:0) {
                ForEach(0..<TitleColor.presets.count,id:\.self) { index in
                    if index < colors.count {
                        let color = colors[index]
                        Button { model.pick(color) } label: { ColorDot(color:color,size:20,isCurrent:color.hex == current.hex) }
                            .buttonStyle(DotPress()).contentShape(.focusEffect,Circle())
                            .help(Text(verbatim:color.spokenName)).accessibilityLabel(Text(verbatim:color.spokenName))
                            .accessibilityAddTraits(color.hex == current.hex ? .isSelected : [])
                    } else {
                        Circle().strokeBorder(.white.opacity(0.1),style:StrokeStyle(lineWidth:1,dash:[2,2])).frame(width:20,height:20).padding(3)
                            .accessibilityHidden(true)
                    }
                    if index < TitleColor.presets.count-1 { Spacer(minLength:0) }
                }
            }.padding(.horizontal,-3)
        }
    }
}

/// Saturation across, brightness up: a drag here is one undo step.
private struct SaturationBrightnessSquare: View {
    @ObservedObject var model: ColorPaletteModel
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size, hsb = model.hsb
            ZStack {
                LinearGradient(colors:[.white,Color(TitleColor(HSB(hue:hsb.hue,saturation:1,brightness:1)))],startPoint:.leading,endPoint:.trailing)
                LinearGradient(colors:[.clear,.black],startPoint:.top,endPoint:.bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius:8))
            .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(.white.opacity(0.1),lineWidth:1))
            .overlay(alignment:.topLeading) {
                Circle().fill(Color(model.shown)).frame(width:16,height:16)
                    .overlay(Circle().strokeBorder(.white,lineWidth:2))
                    .shadow(color:.black.opacity(0.45),radius:2,y:1)
                    .offset(x:hsb.saturation*size.width-8,y:(1-hsb.brightness)*size.height-8)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged { value in
                func unit(_ v: Double) -> Double { min(1,max(0,v)) }
                model.drag(to:HSB(hue:model.hsb.hue,saturation:unit(value.location.x/max(1,size.width)),brightness:unit(1-value.location.y/max(1,size.height))))
            }.onEnded { _ in model.endDrag() })
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Saturation and brightness")
        .accessibilityValue(Text("Saturation \(Int((model.hsb.saturation*100).rounded()))%, brightness \(Int((model.hsb.brightness*100).rounded()))%"))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            model.drag(to:HSB(hue:model.hsb.hue,saturation:model.hsb.saturation,brightness:min(1,max(0,model.hsb.brightness+step)))); model.endDrag()
        }
    }
}

/// The hue, red round to red. Moving it keeps the saturation and brightness, and a grey keeps
/// the hue for when it gets some colour.
private struct HueBar: View {
    @ObservedObject var model: ColorPaletteModel
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            Capsule(style:.circular)
                .fill(LinearGradient(colors:stride(from:0.0,through:1,by:1.0/12).map { Color(TitleColor(HSB(hue:$0,saturation:1,brightness:1))) },startPoint:.leading,endPoint:.trailing))
                .frame(height:12).overlay(Capsule(style:.circular).strokeBorder(.white.opacity(0.1),lineWidth:1))
                .frame(maxHeight:.infinity)
                .overlay(alignment:.leading) {
                    Circle().fill(Color(TitleColor(HSB(hue:model.hsb.hue,saturation:1,brightness:1)))).frame(width:height,height:height)
                        .overlay(Circle().strokeBorder(.white,lineWidth:2.5))
                        .shadow(color:.black.opacity(0.45),radius:2,y:1)
                        .offset(x:model.hsb.hue*width-height/2)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged { value in
                    let hsb = model.hsb
                    model.drag(to:HSB(hue:min(1,max(0,value.location.x/max(1,width))),saturation:hsb.saturation,brightness:hsb.brightness))
                }.onEnded { _ in model.endDrag() })
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Hue")
        .accessibilityValue(Text(verbatim:"\(Int((model.hsb.hue*360).rounded()))°"))
        .accessibilityAdjustableAction { direction in
            let hsb = model.hsb, step = direction == .increment ? 1.0/36 : -1.0/36
            model.drag(to:HSB(hue:(hsb.hue+step+1).truncatingRemainder(dividingBy:1),saturation:hsb.saturation,brightness:hsb.brightness)); model.endDrag()
        }
    }
}

// MARK: - AppKit

/// The palette in a popover from this view while `model` is set. It stays up while another window
/// is used (the Mac's colour panel), and closes on a click in the editor, Esc, or when this view
/// goes; closing it closes the palette's edits.
struct PalettePopover: NSViewRepresentable {
    @Binding var model: ColorPaletteModel?
    /// When a palette last began to close: the click on + that closed it must not open it again.
    static var closed = -Double.infinity
    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var shown: ColorPaletteModel?
        var dismiss: () -> Void = {}
        func popoverWillClose(_ notification: Notification) { PalettePopover.closed = ProcessInfo.processInfo.systemUptime }
        func popoverDidClose(_ notification: Notification) { finish() }
        func finish() {
            guard let model = shown else { return }
            shown = nil; popover = nil
            model.close(); dismiss()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.dismiss = { [$model] in if $model.wrappedValue != nil { $model.wrappedValue = nil } }
        if let model, coordinator.shown !== model, !model.isClosed {
            coordinator.shown = model
            // Shown once this update is done, from where the view is by then.
            DispatchQueue.main.async {
                guard coordinator.shown === model, coordinator.popover == nil else { return }
                guard view.window != nil else { coordinator.finish(); return }       // nowhere to show it from
                let popover = NSPopover()
                popover.behavior = .semitransient; popover.animates = true
                popover.appearance = NSAppearance(named:.darkAqua)
                let content = NSHostingController(rootView:ColorPalette(model:model,recents:model.recents).preferredColorScheme(.dark))
                content.sizingOptions = .preferredContentSize
                popover.contentViewController = content
                popover.delegate = coordinator
                coordinator.popover = popover
                popover.show(relativeTo:view.bounds,of:view,preferredEdge:.minY)
            }
        } else if model == nil, let popover = coordinator.popover {
            DispatchQueue.main.async { popover.close() }
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.dismiss = {}
        let popover = coordinator.popover
        coordinator.finish()
        popover?.close()
    }
}

/// The Mac's colour panel editing a palette's colour: its changes arrive by target and action,
/// continuously, until `detach` (the palette closing, which choosing another clip does too).
@MainActor final class SystemColorPanel: NSObject {
    /// The one the panel sends to now.
    private static weak var attached: SystemColorPanel?
    private var receive: ((TitleColor) -> Void)?
    /// The last colour it sent, for the recent colours.
    private var last: TitleColor?
    func show(_ color: TitleColor, receive: @escaping (TitleColor) -> Void) {
        let panel = NSColorPanel.shared
        if Self.attached !== self { Self.attached?.detach() }
        // Its colour is set with no target, so that sends nothing back.
        panel.setTarget(nil); panel.setAction(nil)
        panel.appearance = NSAppearance(named:.darkAqua); panel.showsAlpha = false; panel.isContinuous = true
        panel.color = NSColor(srgbRed:color.red,green:color.green,blue:color.blue,alpha:1)
        attach(receive)
        panel.setTarget(self); panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }
    func attach(_ receive: @escaping (TitleColor) -> Void) { self.receive = receive; Self.attached = self }
    @objc private func changed(_ sender: NSColorPanel) { take(sender.color) }
    /// A colour from the panel, in sRGB as titles keep it.
    func take(_ color: NSColor) {
        guard let receive, let rgb = TitleColor(color) else { return }
        last = rgb; receive(rgb)
    }
    /// The panel stops editing the title, and is closed if it was open for it. Returns the last
    /// colour it sent.
    @discardableResult func detach() -> TitleColor? {
        receive = nil
        if Self.attached === self {
            Self.attached = nil
            if NSColorPanel.sharedColorPanelExists {
                let panel = NSColorPanel.shared
                panel.setTarget(nil); panel.setAction(nil); panel.orderOut(nil)
            }
        }
        defer { last = nil }
        return last
    }
}
