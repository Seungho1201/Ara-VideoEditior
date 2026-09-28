import SwiftUI
import AppKit
import FrameCore

// MARK: - Language

/// The app's language: the Mac's, or one chosen in Settings. Stored as this app's own
/// `AppleLanguages`, as macOS does for a per-app language, so menus, panels and alerts follow
/// too. Takes effect when Ara starts again.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", korean = "ko"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: String(localized:"System default")
        case .english: "English"
        case .korean: "한국어"
        }
    }
    /// What this app itself was set to (not the Mac's list, which every app inherits).
    static func current(in defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) -> AppLanguage {
        let own = domain.flatMap { defaults.persistentDomain(forName:$0)?["AppleLanguages"] as? [String] }
        guard let first = own?.first else { return .system }
        return first.hasPrefix("ko") ? .korean : first.hasPrefix("en") ? .english : .system
    }
    func apply(to defaults: UserDefaults = .standard) {
        if self == .system { defaults.removeObject(forKey:"AppleLanguages") } else { defaults.set([rawValue],forKey:"AppleLanguages") }
    }
    /// The language this running copy of Ara is showing.
    static var running: String { Bundle.main.preferredLocalizations.first ?? "en" }
}

// MARK: - Shortcuts

/// A key with modifiers, as stored in Settings. `key` is a lowercased character, or a name
/// for a key that has none ("space", "left", "delete", …).
struct Shortcut: Codable, Hashable {
    var key: String
    var modifiers: UInt

    static let modifierMask: NSEvent.ModifierFlags = [.command,.shift,.option,.control]
    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = []) {
        self.key = key; self.modifiers = modifiers.intersection(Self.modifierMask).rawValue
    }
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue:modifiers) }

    private static let named: [UInt16:String] = [49:"space",123:"left",124:"right",125:"down",126:"up",51:"delete",117:"forwardDelete",
                                                  36:"return",76:"return",53:"escape",48:"tab",115:"home",119:"end",116:"pageUp",121:"pageDown"]
    /// US-layout letters and digits by key position, for input sources (Korean) that type
    /// something else: the physical key still counts.
    private static let positions: [UInt16:String] = [0:"a",11:"b",8:"c",2:"d",14:"e",3:"f",5:"g",4:"h",34:"i",38:"j",40:"k",37:"l",46:"m",
        45:"n",31:"o",35:"p",12:"q",15:"r",1:"s",17:"t",32:"u",9:"v",13:"w",7:"x",16:"y",6:"z",18:"1",19:"2",20:"3",21:"4",23:"5",
        22:"6",26:"7",28:"8",25:"9",29:"0",27:"-",24:"=",33:"[",30:"]",41:";",39:"'",43:",",47:".",44:"/",42:"\\",50:"`"]
    /// The key an event is for; nil for a modifier on its own.
    static func key(of event: NSEvent) -> String? {
        if let name = named[event.keyCode] { return name }
        // Letters as typed (Dvorak, AZERTY); digits and punctuation by position, as Shift
        // changes what they type (⇧1 types "!").
        if let typed = event.charactersIgnoringModifiers?.lowercased(), typed.count == 1,
           let first = typed.unicodeScalars.first, ("a"..."z").contains(first) { return typed }
        if let position = positions[event.keyCode] { return position }
        if let typed = event.charactersIgnoringModifiers?.lowercased(), typed.count == 1,
           let first = typed.unicodeScalars.first, first.isASCII, first.value > 0x20, first.value < 0x7F { return typed }
        return nil
    }
    init?(event: NSEvent) {
        guard let key = Self.key(of:event) else { return nil }
        self.init(key,event.modifierFlags)
    }
    func matches(_ event: NSEvent) -> Bool {
        Self.key(of:event) == key && event.modifierFlags.intersection(Self.modifierMask).rawValue == modifiers
    }
    var keyEquivalent: KeyEquivalent {
        switch key {
        case "space": .space
        case "left": .leftArrow
        case "right": .rightArrow
        case "up": .upArrow
        case "down": .downArrow
        case "delete": .delete
        case "forwardDelete": .deleteForward
        case "return": .return
        case "escape": .escape
        case "tab": .tab
        case "home": .home
        case "end": .end
        case "pageUp": .pageUp
        case "pageDown": .pageDown
        default: KeyEquivalent(key.first ?? " ")
        }
    }
    var keyboardShortcut: KeyboardShortcut {
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return KeyboardShortcut(keyEquivalent,modifiers:modifiers)
    }
    /// As macOS menus show it: ⌃⌥⇧⌘ then the key.
    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let glyphs = ["space":"Space","left":"←","right":"→","up":"↑","down":"↓","delete":"⌫","forwardDelete":"⌦","return":"↩",
                      "escape":"⎋","tab":"⇥","home":"↖","end":"↘","pageUp":"⇞","pageDown":"⇟"]
        return text+(glyphs[key] ?? key.uppercased())
    }
    /// Kept by macOS or Ara itself (Quit, Close, Hide, Settings, Minimise, copy and paste).
    var isReserved: Bool {
        flags == [.command] && ["q","w","h","m",",","c","v","x","a"].contains(key) || flags == [.command,.option] && key == "h"
    }
}

/// The commands a shortcut can be set for, with Ara's defaults.
enum AppCommand: String, CaseIterable, Identifiable {
    case newProject, openProject, startScreen, save, saveAs, importMedia, exportMovie, snapshot
    case undo, redo
    case playPause, previousFrame, nextFrame, clipStart, clipEnd, split, delete, closeGap, addText, snapping
    var id: String { rawValue }
    enum Group: String, CaseIterable { case file = "File", edit = "Edit", timeline = "Timeline" }
    var group: Group {
        switch self {
        case .newProject,.openProject,.startScreen,.save,.saveAs,.importMedia,.exportMovie,.snapshot: .file
        case .undo,.redo: .edit
        default: .timeline
        }
    }
    /// The menu item's name (localized through the string table).
    var title: String {
        switch self {
        case .newProject: String(localized:"New Project")
        case .openProject: String(localized:"Open Project…")
        case .startScreen: String(localized:"Start Screen")
        case .save: String(localized:"Save Project")
        case .saveAs: String(localized:"Save Project As…")
        case .importMedia: String(localized:"Import Media…")
        case .exportMovie: String(localized:"Export Movie…")
        case .snapshot: String(localized:"Save Timeline Snapshot…")
        case .undo: String(localized:"Undo")
        case .redo: String(localized:"Redo")
        case .playPause: String(localized:"Play / Pause")
        case .previousFrame: String(localized:"Previous Frame")
        case .nextFrame: String(localized:"Next Frame")
        case .clipStart: String(localized:"Go to Selected Clip Start")
        case .clipEnd: String(localized:"Go to Selected Clip End")
        case .split: String(localized:"Split at Playhead")
        case .delete: String(localized:"Delete Linked Selection")
        case .closeGap: String(localized:"Close Gap")
        case .addText: String(localized:"Add Text Clip")
        case .snapping: String(localized:"Snapping")
        }
    }
    var standard: Shortcut? {
        switch self {
        case .newProject: Shortcut("n",.command)
        case .openProject: Shortcut("o",.command)
        case .startScreen: Shortcut("1",[.command,.shift])
        case .save: Shortcut("s",.command)
        case .saveAs: Shortcut("s",[.command,.shift])
        case .importMedia: Shortcut("i",.command)
        case .exportMovie: Shortcut("e",.command)
        case .snapshot: Shortcut("e",[.command,.shift])
        case .undo: Shortcut("z",.command)
        case .redo: Shortcut("z",[.command,.shift])
        case .playPause: Shortcut("space")
        case .previousFrame: Shortcut("left")
        case .nextFrame: Shortcut("right")
        case .clipStart: Shortcut("left",.option)
        case .clipEnd: Shortcut("right",.option)
        case .split: Shortcut("b",.command)
        case .delete: Shortcut("delete")
        case .closeGap: Shortcut("delete",.command)
        case .addText: Shortcut("t",[.command,.shift])
        case .snapping: Shortcut("n")
        }
    }
}

/// The shortcuts in use: Ara's defaults with the user's changes, kept in the app's defaults.
@MainActor final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()
    private let defaults: UserDefaults
    static let storageKey = "shortcuts.v1"
    /// Changed commands only; a stored nil means "no shortcut".
    @Published private(set) var changes: [AppCommand:Shortcut?] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey:Self.storageKey), let stored = try? JSONDecoder().decode([String:Shortcut?].self,from:data) {
            for (id,value) in stored { if let command = AppCommand(rawValue:id) { changes[command] = .some(value) } }
        }
    }
    func shortcut(_ command: AppCommand) -> Shortcut? {
        if let changed = changes[command] { return changed }
        return command.standard
    }
    func keyboardShortcut(_ command: AppCommand) -> KeyboardShortcut? { shortcut(command)?.keyboardShortcut }
    /// "⌘B", or "" when the command has none.
    func label(_ command: AppCommand) -> String { shortcut(command)?.display ?? "" }
    /// A tooltip naming the command's shortcut, whatever it is now.
    func hint(_ text: String, _ command: AppCommand) -> String {
        let label = label(command)
        return label.isEmpty ? text : "\(text) \(label)"
    }
    func isChanged(_ command: AppCommand) -> Bool { changes[command] != nil && shortcut(command) != command.standard }
    /// The command this key press is for, if any.
    func command(matching event: NSEvent) -> AppCommand? {
        AppCommand.allCases.first { shortcut($0)?.matches(event) == true }
    }
    /// Sets (or clears) a shortcut. A command that had it gives it up; it is returned.
    @discardableResult func set(_ shortcut: Shortcut?, for command: AppCommand) -> AppCommand? {
        var taken: AppCommand?
        if let shortcut, let other = AppCommand.allCases.first(where: { $0 != command && self.shortcut($0) == shortcut }) {
            changes[other] = .some(nil); taken = other
        }
        changes[command] = .some(shortcut)
        persist(); return taken
    }
    func reset(_ command: AppCommand) {
        changes[command] = nil
        // A default another command took over goes back to its owner only if that key is free.
        persist()
    }
    func resetAll() { changes.removeAll(); persist() }
    /// Commands whose shortcuts clash (a default brought back where another command now has it).
    var clashes: Set<AppCommand> {
        var seen: [Shortcut:AppCommand] = [:], clashing = Set<AppCommand>()
        for command in AppCommand.allCases {
            guard let shortcut = shortcut(command) else { continue }
            if let other = seen[shortcut] { clashing.insert(other); clashing.insert(command) } else { seen[shortcut] = command }
        }
        return clashing
    }
    private func persist() {
        let stored = Dictionary(uniqueKeysWithValues:changes.map { ($0.key.rawValue,$0.value) })
        if stored.isEmpty { defaults.removeObject(forKey:Self.storageKey) }
        else if let data = try? JSONEncoder().encode(stored) { defaults.set(data,forKey:Self.storageKey) }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var store: EditorStore
    var body: some View {
        TabView {
            GeneralSettings(store:store).tabItem { Label("General",systemImage:"gearshape") }
            HapticSettings(store:store).tabItem { Label("Trackpad",systemImage:"hand.tap") }
            ShortcutSettingsView().tabItem { Label("Shortcuts",systemImage:"keyboard") }
        }
        .frame(width:560,height:520)
        .preferredColorScheme(.dark)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var store: EditorStore
    @State private var language = AppLanguage.current()
    var body: some View {
        Form {
            Section {
                Picker("Language",selection:$language) {
                    ForEach(AppLanguage.allCases) { Text(verbatim:$0.title).tag($0) }
                }
                .onChange(of:language) { _,chosen in chosen.apply() }
                if language != AppLanguage.current(in:.standard) || needsRestart {
                    HStack {
                        Text("Ara shows the new language after it starts again.").font(.system(size:11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { store.relaunch() }
                    }
                }
            } footer: {
                Text("“System default” follows the language set for your Mac.").font(.system(size:11)).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Snapping",isOn:$store.snapping)
            }
        }
        .formStyle(.grouped)
    }
    /// The running copy shows another language than the one chosen.
    private var needsRestart: Bool {
        switch language {
        case .system: false
        case .english: !AppLanguage.running.hasPrefix("en")
        case .korean: !AppLanguage.running.hasPrefix("ko")
        }
    }
}

/// The kinds of trackpad haptic, each of which can be turned off.
enum HapticKind: String, CaseIterable, Identifiable {
    case skimming, snapping, mediaDrop, transitions, alignment
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .skimming: "Skimming"
        case .snapping: "Clips snapping into place"
        case .mediaDrop: "Dropping media on the timeline"
        case .transitions: "Dragging transitions"
        case .alignment: "Alignment guides in the preview"
        }
    }
    var detail: LocalizedStringKey {
        switch self {
        case .skimming: "A tick for each frame while you skim, and when the playhead meets a clip's edge."
        case .snapping: "When a moved or trimmed clip catches a clip edge, the playhead or the start."
        case .mediaDrop: "When media dragged from the library finds a place, and when it lands."
        case .transitions: "When a transition finds a cut or clip edge, and when it is applied."
        case .alignment: "When a clip's centre lines up with another in the preview."
        }
    }
}

private struct HapticSettings: View {
    @ObservedObject var store: EditorStore
    var body: some View {
        Form {
            Section {
                Toggle("Trackpad Haptics",isOn:$store.scrubHaptics)
            } footer: {
                Text("Needs a Force Touch trackpad with Force Click and haptic feedback turned on in System Settings.")
                    .font(.system(size:11)).foregroundStyle(.secondary)
            }
            Section {
                ForEach(HapticKind.allCases) { kind in
                    Toggle(isOn:Binding(get:{ !store.hapticsOff.contains(kind) },
                                        set:{ on in if on { store.hapticsOff.remove(kind) } else { store.hapticsOff.insert(kind) } })) {
                        VStack(alignment:.leading,spacing:2) {
                            Text(kind.title)
                            Text(kind.detail).font(.system(size:11)).foregroundStyle(.secondary)
                        }
                    }
                    if kind == .skimming {
                        // macOS has no haptic strength: a gentler skim pulses less often.
                        Picker("Skimming rate",selection:$store.skimHapticStrength) {
                            Text("Precise").tag(ScrubFeedbackCadence.Strength.precise)
                            Text("Standard").tag(ScrubFeedbackCadence.Strength.standard)
                            Text("Light").tag(ScrubFeedbackCadence.Strength.light)
                        }
                        .pickerStyle(.segmented)
                        .disabled(store.hapticsOff.contains(.skimming))
                    }
                }
            }.disabled(!store.scrubHaptics)
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettingsView: View {
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @State private var recording: AppCommand?
    @State private var note: String?
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Form {
                ForEach(AppCommand.Group.allCases,id:\.self) { group in
                    Section(LocalizedStringKey(group.rawValue)) {
                        ForEach(AppCommand.allCases.filter { $0.group == group }) { command in
                            ShortcutRow(command:command,shortcuts:shortcuts,recording:$recording,note:$note)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text(verbatim:note ?? String(localized:"Click a shortcut, then press the new keys. Esc cancels.")).font(.system(size:11))
                    .foregroundStyle(note == nil ? .secondary : Color.orange).lineLimit(2)
                Spacer()
                Button("Restore Defaults") { shortcuts.resetAll(); note = nil }.disabled(shortcuts.changes.isEmpty)
            }.padding(.horizontal,20).padding(.bottom,14)
        }
    }
}

private struct ShortcutRow: View {
    let command: AppCommand
    @ObservedObject var shortcuts: ShortcutSettings
    @Binding var recording: AppCommand?
    @Binding var note: String?
    @State private var monitor: Any?
    var body: some View {
        HStack {
            Text(verbatim:command.title)
            Spacer()
            Button {
                if recording == command { stop() } else { start() }
            } label: {
                Text(verbatim:recording == command ? String(localized:"Type a shortcut…") : (shortcuts.shortcut(command)?.display ?? String(localized:"None")))
                    .font(.system(size:12,design:.rounded)).frame(minWidth:110)
                    .foregroundStyle(shortcuts.clashes.contains(command) ? Color.orange : recording == command ? Theme.accent : Color.primary)
            }
            .accessibilityLabel(Text(verbatim:"\(command.title) \(shortcuts.label(command))"))
            Button { shortcuts.set(nil,for:command); note = nil } label: { Image(systemName:"xmark.circle") }
                .buttonStyle(.borderless).help("Remove shortcut").disabled(shortcuts.shortcut(command) == nil)
            Button { shortcuts.reset(command); note = nil } label: { Image(systemName:"arrow.uturn.backward") }
                .buttonStyle(.borderless).help("Restore default").disabled(!shortcuts.isChanged(command) && !shortcuts.clashes.contains(command))
        }
        .onDisappear { stop() }
    }
    private func start() {
        stop(); recording = command; note = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { event in
            guard recording == command else { return event }
            if event.keyCode == 53, event.modifierFlags.intersection(Shortcut.modifierMask).isEmpty { stop(); return nil }
            guard let shortcut = Shortcut(event:event) else { return nil }
            if shortcut.isReserved {
                note = String(localized:"\(shortcut.display) is kept for macOS or copy and paste. Choose another.")
                return nil
            }
            if let taken = shortcuts.set(shortcut,for:command) {
                note = String(localized:"\(shortcut.display) moved here from “\(taken.title)”, which now has none.")
            } else { note = nil }
            stop(); return nil
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording == command { recording = nil }
    }
}

extension EditorStore {
    /// Quits and opens Ara again, asking about unsaved changes as a quit does.
    func relaunch() {
        AppDelegate.relaunchOnQuit = true
        NSApplication.shared.terminate(nil)
        // Only reached when the quit was cancelled.
        AppDelegate.relaunchOnQuit = false
    }
}

extension EditorStore {
    /// Runs a timeline command typed while the timeline has focus (when the menu did not take the
    /// key, as with a Korean input source). False for commands only the menus run.
    func performFromKeyboard(_ command: AppCommand, repeating: Bool = false) -> Bool {
        switch command {
        case .playPause: if !repeating { togglePlayback() }
        case .previousFrame: step(-1)
        case .nextFrame: step(1)
        case .clipStart: goToSelectedClipStart()
        case .clipEnd: goToSelectedClipEnd()
        case .delete: deleteSelection()
        case .closeGap: if selectedGap != nil { closeSelectedGap() }
        case .split: if selectedClip != nil { split() }
        case .addText: addText()
        case .snapping: if !repeating { snapping.toggle() }
        default: return false
        }
        return true
    }
}

extension TransitionKind {
    /// The name shown in Ara's language (`name` stays the English one saved in status text).
    var displayName: String { Bundle.main.localizedString(forKey:name,value:name,table:nil) }
}
extension TransitionKind.Category {
    var displayName: String { Bundle.main.localizedString(forKey:rawValue,value:rawValue,table:nil) }
}

extension EditorStore {
    /// " · ⌘Z to undo", with whatever Undo is set to (nothing when it has no shortcut).
    var undoHint: String {
        let key = ShortcutSettings.shared.label(.undo)
        return key.isEmpty ? "" : String(localized:" · \(key) to undo")
    }
    /// An undo step's name (kept in English in the history) as the menus show it.
    static func localizedAction(_ name: String) -> String {
        name.isEmpty ? name : Bundle.main.localizedString(forKey:name,value:name,table:nil)
    }
}
