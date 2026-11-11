import AppKit
import Carbon.HIToolbox
import ShortcutsLensKit
import SwiftUI

/// A shortcut drawn as keycaps: ⌃ ⌥ ⌘ K.
struct Keycaps: View {
    let combo: KeyCombo
    var size: SwiftUI.ControlSize = .regular
    var dimmed = false

    private var fontSize: CGFloat {
        switch size {
        case .mini, .small: 10.5
        case .large, .extraLarge: 17
        default: 12.5
        }
    }

    var body: some View {
        HStack(spacing: size == .large ? 4 : 2.5) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                KeyText.text(part)
                    .font(.system(size: fontSize, weight: .medium, design: .rounded))
                    .padding(.horizontal, part.count > 1 ? fontSize * 0.45 : 0)
                    .frame(minWidth: fontSize * 1.75, minHeight: fontSize * 1.75)
                    .background(RoundedRectangle(cornerRadius: fontSize * 0.35, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: fontSize * 0.35, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
            }
        }
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combo.spoken)
        .help(combo.spoken)
    }

    private var parts: [String] {
        var parts = Modifiers.ordered.filter(combo.modifiers.contains).map(\.symbol)
        if let keyCode = combo.keyCode { parts.append(KeyNames.name(for: keyCode)) }
        return parts
    }
}

/// A shortcut as one compact label on the right of a row, the way menus show it: ⌃⌥⌘2.
struct KeyLabel: View {
    let combo: KeyCombo
    var dimmed = false

    var body: some View {
        KeyText.text(combo.display)
            .font(.system(size: 13, weight: .medium))
            .tracking(1)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
            .opacity(dimmed ? 0.45 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(combo.spoken)
            .help(combo.spoken)
    }
}

/// Shortcut text with the 🌐 and 🎤 keys drawn as SF Symbols, so they match the letters
/// around them instead of showing as color emoji.
enum KeyText {
    static func text(_ string: String) -> Text {
        var result = Text(verbatim: "")
        var run = ""
        for character in string {
            let symbol: String? = switch character {
            case "🌐": "globe"
            case "🎤": "mic"
            default: nil
            }
            guard let symbol else { run.append(character); continue }
            result = Text("\(result)\(run)\(Image(systemName: symbol))")
            run = ""
        }
        return run.isEmpty ? result : Text("\(result)\(run)")
    }
}

/// One shortcut in a list.
struct ShortcutRow: View {
    let entry: ShortcutEntry
    var showOwner = true
    @State private var store = ShortcutStore.shared

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1).foregroundStyle(entry.enabled ? .primary : .secondary)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            badges
            KeyLabel(combo: entry.combo, dimmed: !entry.enabled)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String? {
        var parts: [String] = []
        if showOwner { parts.append(entry.ownerName) }
        if let gesture = entry.gestureTitle, entry.title.range(of: gesture, options: .caseInsensitive) == nil { parts.append(gesture) }
        if let category = entry.category, category != entry.ownerName, entry.source != .appMenus { parts.append(category) }
        if let path = entry.menuPath, entry.source == .appMenus {
            let between = path.components(separatedBy: " › ").dropFirst().dropLast()
            if !between.isEmpty { parts.append(between.joined(separator: " › ")) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 6) {
            if !store.partners(of: entry).isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Conflicts with \(store.partners(of: entry).map { "\($0.ownerName): \($0.title)" }.joined(separator: ", "))")
                    .accessibilityLabel("Conflict")
            }
            if !entry.enabled {
                Text("Off").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .help("Turned off")
            } else if entry.source.needsApp, !store.isRunning(entry.ownerID) {
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                    .help("\(entry.ownerName) isn't running, so this shortcut does nothing until it opens.")
                    .accessibilityLabel("Not running")
            }
            if entry.source == .appSettings {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                    .help("Found in \(entry.ownerName)'s settings")
            } else if entry.source == .knownDefault {
                Image(systemName: "questionmark.circle").font(.caption).foregroundStyle(.tertiary)
                    .help("\(entry.ownerName)'s usual default. It may use other keys if you've changed it.")
                    .accessibilityLabel("Usual default")
            }
        }
    }
}

/// Details for the selected shortcut.
struct ShortcutInspector: View {
    let entry: ShortcutEntry
    @State private var store = ShortcutStore.shared
    @State private var prefs = Preferences.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(nsImage: store.icon(for: entry.ownerID)).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading) {
                        Text(entry.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(entry.ownerName + (entry.category.map { " › \($0)" } ?? "")).foregroundStyle(.secondary)
                    }
                }
                Keycaps(combo: entry.combo, size: .large, dimmed: !entry.enabled)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow { Text("Keys").foregroundStyle(.secondary); Text(entry.combo.spoken).textSelection(.enabled) }
                    GridRow { Text("Works").foregroundStyle(.secondary); Text(entry.isGlobal ? "In every app" : "Only while \(entry.ownerName) is in front") }
                    GridRow { Text("Status").foregroundStyle(.secondary); Text(status) }
                    GridRow { Text("Source").foregroundStyle(.secondary); Text(entry.source.title) }
                }
                if let detail = entry.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                let partners = store.partners(of: entry)
                if !partners.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Also on \(entry.combo.display)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.headline)
                        ForEach(partners) { other in
                            Label {
                                Text("\(other.ownerName): \(other.title)")
                            } icon: {
                                Image(nsImage: store.icon(for: other.ownerID)).resizable().frame(width: 16, height: 16)
                            }
                        }
                        Text("Only one of them gets the keys: usually whichever registered them first. Change one of them so both work.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                }
                actions
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var status: String {
        if !entry.enabled { return "Turned off" }
        if entry.source.needsApp {
            return store.isRunning(entry.ownerID) ? "On; \(entry.ownerName) is running" : "On, but \(entry.ownerName) isn't running"
        }
        return "On"
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let action = Actions.changeAction(for: entry) {
                Button(action.title, action: action.run)
            }
            HStack {
                Button("Copy") { Actions.copy(entry) }
                Button(prefs.hiddenEntries.contains(entry.id) ? "Show Again" : "Hide") {
                    if prefs.hiddenEntries.contains(entry.id) { prefs.unhide(entry.id) } else { prefs.hide(entry) }
                    store.rebuild()
                }
                .help("Hidden shortcuts leave the lists and the conflict count. Settings › Sources lists them.")
            }
        }
    }
}

@MainActor
enum Actions {
    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") {
            NSWorkspace.shared.open(url)
        }
    }

    static func copy(_ entry: ShortcutEntry) {
        copy(line(for: entry))
    }

    /// Edit › Copy (⌘C) in a list: the selected shortcut, as Copy in its menu writes it.
    static func providers(for selection: ShortcutEntry.ID?, in entries: [ShortcutEntry]) -> [NSItemProvider] {
        guard let entry = entries.first(where: { $0.id == selection }) else { return [] }
        return [NSItemProvider(object: line(for: entry) as NSString)]
    }

    static func line(for entry: ShortcutEntry) -> String {
        "\(entry.combo.display)  \(entry.title) (\(entry.ownerName))"
    }

    struct ChangeAction {
        let title: String
        let run: () -> Void
    }

    /// The button that leads to where a shortcut is changed: Keyboard settings for macOS's,
    /// the app itself for an app's.
    static func changeAction(for entry: ShortcutEntry) -> ChangeAction? {
        switch entry.source {
        case .macOS, .services, .menuOverride, .builtIn:
            return ChangeAction(title: "Open Keyboard Shortcuts Settings…") { openKeyboardSettings() }
        case .appSettings, .appReport, .appMenus, .knownDefault:
            guard let url = ShortcutStore.shared.apps[entry.ownerID]?.url
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.ownerID) else { return nil }
            return ChangeAction(title: "Open \(entry.ownerName)") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The whole list as text, for pasting into a note or a support message.
    static func copyAll(_ entries: [ShortcutEntry]) {
        var lines: [String] = []
        var owner = ""
        for entry in entries {
            if entry.ownerName != owner {
                owner = entry.ownerName
                lines.append(lines.isEmpty ? owner : "\n" + owner)
            }
            lines.append("  \(entry.combo.display)\t\(entry.title)\(entry.enabled ? "" : " (off)")")
        }
        copy(lines.joined(separator: "\n"))
    }
}

/// Click, then press a shortcut. Esc cancels, Delete clears.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo?
    var placeholder = "Click to set"
    /// Bare keys are allowed for checking ("is F5 free?"), not for the Quick View shortcut.
    var requireModifier = true

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        update(view)
        return view
    }

    func updateNSView(_ view: RecorderButton, context: Context) { update(view) }

    private func update(_ view: RecorderButton) {
        view.onChange = { combo = $0 }
        view.placeholder = placeholder
        view.requireModifier = requireModifier
        view.combo = combo
    }

    final class RecorderButton: NSButton {
        var onChange: ((KeyCombo?) -> Void)?
        var placeholder = "Click to set" { didSet { refresh() } }
        var requireModifier = true
        var combo: KeyCombo? { didSet { refresh() } }
        private var recording = false { didSet { refresh() } }
        private var monitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded
            target = self
            action = #selector(toggle)
            refresh()
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize { NSSize(width: 140, height: super.intrinsicContentSize.height) }

        private func refresh() {
            title = recording ? "Press keys…" : (combo?.display ?? placeholder)
            setAccessibilityLabel(recording ? "Press keys" : (combo?.spoken ?? placeholder))
        }

        @objc private func toggle() { recording ? stop() : start() }

        private func start() {
            recording = true
            HotKeyCenter.shared.pause()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                switch Int(event.keyCode) {
                case kVK_Escape where flags.isEmpty:
                    self.stop()
                case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty:
                    self.combo = nil
                    self.onChange?(nil)
                    self.stop()
                default:
                    if self.requireModifier, flags.intersection([.command, .option, .control]).isEmpty {
                        NSSound.beep()
                        return nil
                    }
                    let combo = KeyCombo(keyCode: Int(event.keyCode), modifiers: Modifiers(cocoa: Int(event.modifierFlags.rawValue)))
                    self.combo = combo
                    self.onChange?(combo)
                    self.stop()
                }
                return nil
            }
        }

        private func stop() {
            recording = false
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            HotKeyCenter.shared.resume()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, recording { stop() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

/// A sentence about who uses a combo, for the recorder in Free Shortcuts and Settings.
struct ComboUsage: View {
    let combo: KeyCombo
    var ignoring: String? = nil
    @State private var store = ShortcutStore.shared

    var body: some View {
        let uses = store.uses(of: combo).filter { $0.id != ignoring && $0.enabled }
        if uses.isEmpty {
            Label("\(combo.display) is free: nothing ShortcutsLens can see uses it.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Label("\(combo.display) is taken", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                ForEach(uses) { use in
                    Text("\(use.ownerName): \(use.title)\(use.isGlobal ? "" : " (only in \(use.ownerName))")")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
