import SwiftUI
import AppKit

/// The colours of the preview's transform chrome, chosen in Settings ▸ Preview: the outline of the
/// clip being transformed with its handles, that outline while a stretch sits on the picture's own
/// proportions, the guides a clip snaps to, and its alignment point.
/// Kept in the app's defaults; a colour set back to its default is forgotten.
@MainActor final class PreviewChromeColors: ObservableObject {
    enum Part: String, CaseIterable, Identifiable {
        case outline, proportion, guide, point
        var id: String { rawValue }
        /// Its name, as the colour controls show it (a key of the string table).
        var name: String {
            switch self {
            case .outline: "Outline and handles"
            case .proportion: "Original proportions snap"
            case .guide: "Snap guides"
            case .point: "Alignment point"
            }
        }
        /// The colour it has unless another is chosen: the app's blue, and the green, yellow and red
        /// of the dark appearance's system colours.
        var standard: TitleColor {
            switch self {
            case .outline: TitleColor(red:154.0/255,green:203.0/255,blue:1)
            case .proportion: TitleColor(red:48.0/255,green:209.0/255,blue:88.0/255)
            case .guide: TitleColor(red:1,green:214.0/255,blue:10.0/255)
            case .point: TitleColor(red:1,green:69.0/255,blue:58.0/255)
            }
        }
        var key: String { "preview.color.\(rawValue)" }
    }
    static let shared = PreviewChromeColors()
    private let defaults: UserDefaults
    @Published private var chosen: [Part:TitleColor]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        chosen = Dictionary(uniqueKeysWithValues:Part.allCases.compactMap { part in
            defaults.string(forKey:part.key).flatMap(TitleColor.init(hex:)).map { (part,$0) }
        })
    }
    func color(_ part: Part) -> TitleColor { chosen[part] ?? part.standard }
    /// What the preview draws with: the chosen colour, or the very colour it has always drawn
    /// (the system's green, yellow and red, which follow the appearance) when none is chosen.
    func nsColor(_ part: Part) -> NSColor {
        guard let c = chosen[part] else {
            switch part {
            case .outline: return Theme.accentNS
            case .proportion: return .systemGreen
            case .guide: return .systemYellow
            case .point: return .systemRed
            }
        }
        return NSColor(srgbRed:c.red,green:c.green,blue:c.blue,alpha:1)
    }
    func isStandard(_ part: Part) -> Bool { chosen[part] == nil }
    var allStandard: Bool { chosen.isEmpty }
    func set(_ part: Part, _ color: TitleColor) {
        guard color.hex != part.standard.hex else { reset(part); return }
        guard chosen[part]?.hex != color.hex else { return }
        chosen[part] = color; defaults.set(color.hex,forKey:part.key)
    }
    func reset(_ part: Part) {
        if chosen[part] != nil { chosen[part] = nil }
        defaults.removeObject(forKey:part.key)
    }
    func resetAll() { Part.allCases.forEach(reset) }
}

/// A picture of the preview's transform chrome in the chosen colours: a clip's outline with its
/// handles and rotation knob, a guide its left edge has snapped to (the frame's middle), and its
/// alignment point, drawn as the preview draws them; beside it, a clip stretched back to its own
/// proportions, its outline in that colour.
struct ChromeColorPreview: View {
    @ObservedObject var colors: PreviewChromeColors
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin:.zero,size:size)),with:.linearGradient(
                Gradient(colors:[Color(red:0.20,green:0.33,blue:0.48),Color(red:0.34,green:0.46,blue:0.34)]),
                startPoint:.zero,endPoint:CGPoint(x:size.width,y:size.height)))
            let picture = Color(red:0.13,green:0.14,blue:0.17), shade = Color.black.opacity(0.6), rim = Color.black.opacity(0.65)
            let clip = CGRect(x:size.width*0.5,y:size.height*0.3,width:size.width*0.36,height:size.height*0.46)
            let even = CGRect(x:size.width*0.1,y:size.height*0.3,width:size.width*0.28,height:size.height*0.46)
            let outline = Color(colors.color(.outline)), guide = Color(colors.color(.guide)), point = Color(colors.color(.point))
            /// An outline with its corner handles, and the rounder stretch handles in the edges' middles.
            func frame(_ box: CGRect, _ color: Color) {
                context.fill(Path(box),with:.color(picture))
                context.stroke(Path(box),with:.color(shade),lineWidth:3.5)
                context.stroke(Path(box),with:.color(color),lineWidth:1.5)
                for corner in [CGPoint(x:box.minX,y:box.minY),CGPoint(x:box.maxX,y:box.minY),CGPoint(x:box.maxX,y:box.maxY),CGPoint(x:box.minX,y:box.maxY)] {
                    let handle = Path(roundedRect:CGRect(x:corner.x-5,y:corner.y-5,width:10,height:10),cornerRadius:2)
                    context.fill(handle,with:.color(color)); context.stroke(handle,with:.color(rim),lineWidth:1)
                }
                for middle in [CGPoint(x:box.midX,y:box.minY),CGPoint(x:box.maxX,y:box.midY),CGPoint(x:box.midX,y:box.maxY),CGPoint(x:box.minX,y:box.midY)] {
                    let handle = Path(ellipseIn:CGRect(x:middle.x-4.5,y:middle.y-4.5,width:9,height:9))
                    context.fill(handle,with:.color(color)); context.stroke(handle,with:.color(rim),lineWidth:1)
                }
            }
            frame(even,Color(colors.color(.proportion)))
            var line = Path(); line.move(to:CGPoint(x:clip.minX,y:0)); line.addLine(to:CGPoint(x:clip.minX,y:size.height))
            context.stroke(line,with:.color(guide),lineWidth:1)
            frame(clip,outline)
            // The rotation knob on its stem above the top edge.
            let top = CGPoint(x:clip.midX,y:clip.minY), knob = CGPoint(x:clip.midX,y:clip.minY-22)
            var stem = Path(); stem.move(to:top); stem.addLine(to:knob)
            context.stroke(stem,with:.color(shade),lineWidth:3.5); context.stroke(stem,with:.color(outline),lineWidth:1.5)
            let disc = Path(ellipseIn:CGRect(x:knob.x-8,y:knob.y-8,width:16,height:16))
            context.fill(disc,with:.color(outline)); context.stroke(disc,with:.color(rim),lineWidth:1)
            // The alignment point, toned down as the preview tones it.
            let centre = CGPoint(x:clip.midX,y:clip.midY)
            var cross = Path()
            cross.move(to:CGPoint(x:centre.x-9,y:centre.y)); cross.addLine(to:CGPoint(x:centre.x+9,y:centre.y))
            cross.move(to:CGPoint(x:centre.x,y:centre.y-9)); cross.addLine(to:CGPoint(x:centre.x,y:centre.y+9))
            cross.addEllipse(in:CGRect(x:centre.x-5,y:centre.y-5,width:10,height:10))
            context.drawLayer { layer in
                layer.opacity = PreviewTransformOverlay.centreOpacity
                layer.stroke(cross,with:.color(shade),lineWidth:3.5); layer.stroke(cross,with:.color(point),lineWidth:1.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius:6))
        .accessibilityElement().accessibilityLabel(Text("The preview's outline, guides and alignment point in the colours chosen"))
    }
}
