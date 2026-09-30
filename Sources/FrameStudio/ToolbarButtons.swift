import SwiftUI

/// A toolbar button: its whole square takes the click (a glyph drawn in thin lines too, not only
/// its lines), with a soft ground under the pointer, a firmer one and a small give while pressed,
/// and the accent ground while `selected` (a mode that is on).
struct ToolbarButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View { Face(configuration:configuration,selected:selected) }
    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false
        var body: some View {
            configuration.label
                .frame(minWidth:26,minHeight:26)
                .background(ToolbarGround(hovered:hovered && isEnabled,pressed:configuration.isPressed && isEnabled,selected:selected))
                .contentShape(RoundedRectangle(cornerRadius:6))
                .scaleEffect(configuration.isPressed && isEnabled ? 0.9 : 1)
                .animation(.easeOut(duration:0.12),value:hovered)
                .animation(.easeOut(duration:0.08),value:configuration.isPressed)
                .onHover { hovered = $0 }
        }
    }
}

/// The ground under a toolbar control: clear, soft under the pointer, firmer pressed, accent when on.
struct ToolbarGround: View {
    var hovered = false, pressed = false, selected = false
    var body: some View {
        RoundedRectangle(cornerRadius:6)
            .fill(selected ? Theme.accent.opacity(pressed ? 0.32 : 0.22) : Color.white.opacity(pressed ? 0.16 : hovered ? 0.08 : 0))
    }
}

/// The same soft ground under the pointer for a toolbar control that is not a button (a menu).
struct ToolbarHover: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .frame(minHeight:26).padding(.horizontal,4)
            .background(ToolbarGround(hovered:hovered))
            .contentShape(RoundedRectangle(cornerRadius:6))
            .animation(.easeOut(duration:0.12),value:hovered)
            .onHover { hovered = $0 }
    }
}
