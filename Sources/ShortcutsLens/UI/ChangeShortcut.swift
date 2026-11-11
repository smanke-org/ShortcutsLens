import AppKit
import ShortcutsLensKit
import SwiftUI

/// Modifier buttons plus a typed key. Not a recorder: a shortcut another app holds never
/// reaches ShortcutsLens as a key press, so recording can't pick the taken ones.
struct ComboPicker: View {
    @Binding var modifiers: Modifiers
    @Binding var key: String
    /// The keys chosen, or nil while the key box is empty or unreadable.
    @Binding var combo: KeyCombo?

    static let specialKeys = [49, 36, 48, 53, 51, 117, 123, 124, 126, 125, 115, 119, 116, 121]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Modifiers.ordered, id: \.rawValue) { mod in
                Toggle(isOn: Binding(get: { modifiers.contains(mod) },
                                     set: { on in
                                         if on { modifiers.insert(mod) } else { modifiers.remove(mod) }
                                         update()
                                     })) {
                    HStack(spacing: 4) {
                        if mod == .function { Image(systemName: "globe") } else { Text(mod.symbol).fontWeight(.medium) }
                        Text(mod == .function ? "fn" : mod.name)
                    }
                    .frame(minWidth: 64)
                }
                .toggleStyle(.button)
                .controlSize(.large)
                .accessibilityLabel(mod.name)
            }
            Text("+").foregroundStyle(.secondary).padding(.horizontal, 2)
            TextField("Key", text: $key)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .multilineTextAlignment(.center)
                .frame(width: 90)
                .onSubmit(update)
                .onChange(of: key) { update() }
                .accessibilityLabel("Key")
                .help("A letter, number or symbol, or a key name like F5, Space, Return, Tab, Esc, Delete or Left")
            Menu {
                ForEach(Self.specialKeys, id: \.self) { code in
                    Button(KeyNames.spokenName(for: code)) { key = KeyNames.spokenName(for: code) }
                }
                Divider()
                ForEach(Array(KeyNames.functionKeys.prefix(12)), id: \.self) { code in
                    Button(KeyNames.name(for: code)) { key = KeyNames.name(for: code) }
                }
            } label: {
                Image(systemName: "keyboard")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pick a key that doesn't type a character")
            .accessibilityLabel("Other keys")
        }
        .fixedSize()
        .onAppear(perform: update)
    }

    /// Whether something is typed that isn't a key.
    static func unreadable(_ key: String, combo: KeyCombo?) -> Bool {
        !key.trimmingCharacters(in: .whitespaces).isEmpty && combo == nil
    }

    /// Reads the key box. A pasted whole shortcut ("⌃⇧C", "ctrl+shift+c") sets the buttons too.
    private func update() {
        let typed = key.trimmingCharacters(in: .whitespaces)
        if typed.count > 1, let whole = KeyEquivalentParser.parseReadable(typed), let code = whole.keyCode {
            modifiers = whole.modifiers
            key = KeyNames.name(for: code)
            return  // the key box's change runs this again with just the key
        }
        guard !typed.isEmpty, let code = KeyEquivalentParser.keyCode(named: typed) else {
            combo = nil
            return
        }
        combo = KeyCombo(keyCode: code, modifiers: modifiers)
    }
}

/// Picks new keys for one shortcut, warns about conflicts, and saves them where they belong.
struct ChangeShortcutSheet: View {
    let entry: ShortcutEntry
    @Environment(\.dismiss) private var dismiss
    @State private var modifiers: Modifiers
    @State private var key: String
    @State private var combo: KeyCombo?
    @State private var working = false
    @State private var failure: String?
    @State private var changer = ShortcutChanger.shared

    init(entry: ShortcutEntry) {
        self.entry = entry
        _modifiers = State(initialValue: entry.combo.modifiers)
        _key = State(initialValue: entry.combo.keyCode.map(KeyNames.name(for:)) ?? "")
        #if DEBUG
        // `SHORTCUTSLENS_DEBUG_SHEET_KEYS=⌃⌥⌘D` types new keys into the sheet for screenshots.
        if let keys = ProcessInfo.processInfo.environment["SHORTCUTSLENS_DEBUG_SHEET_KEYS"] { _key = State(initialValue: keys) }
        #endif
    }

    private var unchanged: Bool { combo == entry.combo }
    private var taken: Bool {
        guard let combo else { return false }
        return !ShortcutStore.shared.uses(of: combo).filter { $0.id != entry.id && $0.enabled }.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: ShortcutStore.shared.icon(for: entry.ownerID)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Change “\(entry.title)”").font(.headline)
                    HStack(spacing: 6) {
                        Text("\(entry.ownerName) · now")
                        Keycaps(combo: entry.combo, size: .small)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            ComboPicker(modifiers: $modifiers, key: $key, combo: $combo)
            SwiftUI.Group {
                if let combo, !unchanged {
                    ComboUsage(combo: combo, ignoring: entry.id)
                } else if ComboPicker.unreadable(key, combo: combo) {
                    Text("Type one key, like C, 5, F5 or Space.").foregroundStyle(.orange)
                } else if unchanged {
                    Text("These are the keys it has now.").foregroundStyle(.secondary)
                } else {
                    Text("Choose the modifier keys, then type the key.").foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 22, alignment: .topLeading)
            Text(changer.explanation(for: entry))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(taken ? "Change Anyway" : "Change", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(combo == nil || unchanged || working)
            }
        }
        .padding(20)
        .frame(width: 680)
        #if DEBUG
        // Screenshots: a sheet shown before the app is active never becomes key by itself.
        .onAppear {
            guard ProcessInfo.processInfo.environment["SHORTCUTSLENS_DEBUG_CHANGE_SHEET"] != nil else { return }
            for delay in [2.0, 3.0, 4.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSApp.windows.filter(\.isSheet).forEach { $0.makeKeyAndOrderFront(nil) }
                }
            }
        }
        #endif
    }

    private func save() {
        guard let combo else { return }
        working = true
        failure = nil
        Task {
            do {
                try await changer.change(entry, to: combo)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            working = false
        }
    }
}

/// The inspector's Change Shortcut button, the last change with Undo, or why it can't change.
struct ChangeControls: View {
    let entry: ShortcutEntry
    @State private var changer = ShortcutChanger.shared
    @State private var showing = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if changer.canChange(entry) {
                Button("Change Shortcut…") { showing = true }
                    .buttonStyle(.borderedProminent)
                    .sheet(isPresented: $showing) { ChangeShortcutSheet(entry: entry) }
                    #if DEBUG
                    // `SHORTCUTSLENS_DEBUG_CHANGE_SHEET=1` opens the sheet for screenshots.
                    .onAppear { if ProcessInfo.processInfo.environment["SHORTCUTSLENS_DEBUG_CHANGE_SHEET"] != nil { showing = true } }
                    #endif
                if let record = changer.records[entry.id] {
                    HStack(spacing: 6) {
                        Text("Changed from").foregroundStyle(.secondary)
                        Keycaps(combo: record.old, size: .small)
                        Button("Undo") {
                            Task {
                                do { try await changer.undo(entry) } catch { failure = error.localizedDescription }
                            }
                        }
                        .controlSize(.small)
                        .help("Gives it back the keys it had before ShortcutsLens changed it")
                    }
                    .font(.callout)
                }
                if let failure {
                    Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            } else if let reason = changer.reasonNotChangeable(entry) {
                Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
