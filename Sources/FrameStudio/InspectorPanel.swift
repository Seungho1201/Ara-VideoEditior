import SwiftUI
import AppKit
import FrameCore

struct InspectorPanel: View {
    @ObservedObject var store: EditorStore
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack { panelTitle("INSPECTOR"); Spacer(); Image(systemName:"slider.horizontal.3").foregroundStyle(Theme.muted) }.padding(16)
            Divider()
            if let clip = store.selectedClip {
                ScrollView {
                    VStack(alignment:.leading,spacing:18) {
                        VStack(alignment:.leading,spacing:6) {
                            Text(clip.name).font(.system(size:13,weight:.semibold)).lineLimit(2)
                            HStack { Text("\(clip.lane.rawValue) · \(clip.kind.rawValue.capitalized)"); if clip.linkID != nil { Image(systemName:"link"); Text("Linked A/V") } }.font(.system(size:10)).foregroundStyle(Theme.accent)
                        }
                        section("TIMING") {
                            info("Start",store.project.frameRate.timecode(clip.start))
                            info("Source in",store.project.frameRate.timecode(clip.sourceStart))
                            info("Duration",store.project.frameRate.timecode(clip.duration))
                            HStack { Button("Trim start here") { store.trim(clip.id,leading:true,to:store.playhead) }; Button("Trim end here") { store.trim(clip.id,leading:false,to:store.playhead) } }.controlSize(.mini)
                        }
                        if clip.kind == .video || clip.kind == .audio {
                            section("SPEED") {
                                HStack {
                                    Text("Playback").foregroundStyle(Theme.muted); Spacer()
                                    Text(String(format:"%.2fx",clip.speed)).font(.system(size:10,design:.monospaced))
                                }
                                Slider(value:Binding(get:{store.selectedClip?.speed ?? 1},
                                                     set:{ v in store.setSpeedInteractively(min(Clip.speedRange.upperBound,max(Clip.speedRange.lowerBound,(v*20).rounded()/20))) }),
                                       in:Clip.speedRange,
                                       onEditingChanged:{ active in if active { store.beginInteraction() } else { store.endInteraction() } })
                                    .controlSize(.mini).accessibilityLabel("Playback speed")
                                HStack(spacing:5) {
                                    ForEach([0.25,0.5,1.0,2.0,4.0],id:\.self) { preset in
                                        Button(preset == 1 ? "1x" : String(format:"%gx",preset)) { store.setSpeed(preset) }
                                            .controlSize(.mini).disabled(abs(clip.speed-preset) < 0.001)
                                    }
                                }
                                Text(clip.speed == 1 ? "Source length \(store.project.frameRate.timecode(clip.sourceLength))"
                                                     : "Uses \(store.project.frameRate.timecode(clip.sourceLength)) of source · audio pitch preserved")
                                    .font(.system(size:9)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                            }
                        }
                        if clip.kind != .audio {
                            section("TRANSFORM") {
                                control("Position X",\.x,range:-1...1,multiplier:100,suffix:"%")
                                control("Position Y",\.y,range:-1...1,multiplier:100,suffix:"%")
                                control("Scale",\.scale,range:0.05...4,multiplier:100,suffix:"%")
                                control("Rotation",\.rotation,range:-180...180,suffix:"°")
                                control("Opacity",\.opacity,range:0...1,multiplier:100,suffix:"%")
                            }
                            section("COLOUR · SDR") {
                                control("Brightness",\.brightness,range:-1...1,multiplier:100)
                                control("Contrast",\.contrast,range:0...3,multiplier:100,suffix:"%")
                                control("Saturation",\.saturation,range:0...3,multiplier:100,suffix:"%")
                            }
                        }
                        if clip.kind == .audio || clip.linkID != nil {
                            section("AUDIO") {
                                control("Volume",\.volume,range:0...2,multiplier:100,suffix:"%")
                                Toggle("Mute",isOn:Binding(get:{store.selectedClip?.style.muted ?? false},set:{v in store.updateStyle { $0.muted = v } })).toggleStyle(.switch).controlSize(.mini)
                            }
                        }
                        if clip.kind == .text {
                            section("TEXT") {
                                TextEditor(text:Binding(get:{store.selectedClip?.style.text ?? ""},set:{v in store.updateStyle { $0.text = String(v.prefix(2000)) } })).font(.system(size:12)).frame(height:75).scrollContentBackground(.hidden).padding(5).background(Theme.background,in:RoundedRectangle(cornerRadius:4)).accessibilityLabel("Title text")
                                control("Font size",\.fontSize,range:8...300,suffix:" pt")
                                ColorPicker("Text colour",selection:Binding(get:{Color(red:clip.style.red,green:clip.style.green,blue:clip.style.blue)},set:{color in
                                    if let c = NSColor(color).usingColorSpace(.sRGB) { store.updateStyle { $0.red = c.redComponent; $0.green = c.greenComponent; $0.blue = c.blueComponent } }
                                }),supportsOpacity:false)
                            }
                        }
                        Button("Reset appearance") { store.updateStyle { style in let text = style.text; style = ClipStyle(); style.text = text } }.controlSize(.small)
                    }.padding(16)
                }
            } else if let gap = store.selectedGap {
                VStack(alignment:.leading,spacing:18) {
                    VStack(alignment:.leading,spacing:6) {
                        Text("Empty space").font(.system(size:13,weight:.semibold))
                        Text("\(gap.lane.rawValue) · Gap").font(.system(size:10)).foregroundStyle(Theme.accent)
                    }
                    section("TIMING") {
                        info("Start",store.project.frameRate.timecode(gap.start))
                        info("End",store.project.frameRate.timecode(gap.end))
                        info("Duration",store.project.frameRate.timecode(gap.duration))
                    }
                    Text("Closing the gap pulls every later clip on \(gap.lane.rawValue) — and its linked audio — back by the gap length.")
                        .font(.system(size:11)).foregroundStyle(Theme.muted).fixedSize(horizontal:false,vertical:true)
                    Button("Close Gap  ⌘⌫") { store.closeSelectedGap() }.controlSize(.small)
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                Spacer(minLength:0)
            } else {
                VStack(spacing:12) {
                    Image(systemName:"cursorarrow.click").font(.system(size:25,weight:.light))
                    Text("Select a timeline clip").font(.system(size:12,weight:.medium))
                    Text("Double-click empty track space\nto select a gap.").font(.system(size:11)).multilineTextAlignment(.center)
                }.foregroundStyle(Theme.muted).frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }.background(Theme.panel)
    }
    private func section<Content:View>(_ title:String,@ViewBuilder content:()->Content) -> some View {
        VStack(alignment:.leading,spacing:10) { panelTitle(title); content() }.font(.system(size:11))
    }
    private func info(_ key:String,_ value:String) -> some View {
        HStack { Text(key).foregroundStyle(Theme.muted); Spacer(); Text(value).font(.system(size:10,design:.monospaced)) }
    }
    private func control(_ label:String,_ key:WritableKeyPath<ClipStyle,Double>,range:ClosedRange<Double>,multiplier:Double = 1,suffix:String = "") -> some View {
        VStack(spacing:5) {
            HStack {
                Text(label).foregroundStyle(Theme.muted); Spacer()
                Text(String(format:"%.0f",(store.selectedClip?.style[keyPath:key] ?? 0)*multiplier)+suffix).font(.system(size:10,design:.monospaced))
            }
            Slider(value:Binding(get:{store.selectedClip?.style[keyPath:key] ?? range.lowerBound},set:{v in store.updateStyle { $0[keyPath:key] = v } }),in:range,onEditingChanged:{ active in if active { store.beginInteraction() } else { store.endInteraction() } }).controlSize(.mini).accessibilityLabel(label)
        }
    }
}
