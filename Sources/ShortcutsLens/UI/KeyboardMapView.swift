import ShortcutsLensKit
import SwiftUI

/// A keyboard with every key lit that has a system-wide shortcut for the chosen modifiers.
/// Clicking a key lists everything on it in the inspector.
struct KeyboardMapView: View {
    @State var state: WindowState
    @State private var store = ShortcutStore.shared
    @State private var width: CGFloat = 600

    private var used: [ShortcutEntry] {
        var list = store.globalVisible.filter(\.enabled)
        if state.includeMenus { list += store.frontmostMenus.filter(\.enabled) }
        return list
    }

    /// The whole keyboard fits the page with keys of a readable size, so it needs no scroll bar.
    private var fits: Bool { (width - 16) / (15.5 + 0.12 * 14) >= 22 }

    /// One key unit, so the keyboard fills the page: 15.5 units plus the gaps between up to 14 keys.
    private var unit: CGFloat { min(max((width - 16) / (15.5 + 0.12 * 14), 22), 64) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Side by side when there's room, stacked in a narrow window.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { modifierPicker; Spacer(minLength: 12); legend }
                    VStack(alignment: .leading, spacing: 10) { modifierPicker; legend }
                }
                keyboard
                if store.accessibilityTrusted, let app = store.frontmost?.localizedName {
                    Toggle("Include \(app)'s menus", isOn: $state.includeMenus)
                        .onChange(of: state.includeMenus) { if state.includeMenus { store.readFrontmostMenus() } }
                }
                Text("Hover over a key to see what uses it. Click it to list everything on that key.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        // The page's width, not the keyboard's: the keys size from it, so measuring the keyboard
        // would feed back on itself.
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 40 } action: { width = $0 }
    }

    private var modifierPicker: some View {
        ControlGroup {
            ForEach(Modifiers.ordered, id: \.rawValue) { mod in
                Toggle(isOn: Binding(get: { state.keyboardModifiers.contains(mod) },
                                     set: { if $0 { state.keyboardModifiers.insert(mod) } else { state.keyboardModifiers.remove(mod) } })) {
                    SwiftUI.Group {
                        if mod == .function { Image(systemName: "globe") } else { Text(mod.symbol) }
                    }
                    .font(.system(size: 14, weight: .medium))
                    .frame(minWidth: 22)
                }
                .toggleStyle(.button)
                .help(mod.name)
                .accessibilityLabel(mod.name)
            }
        }
        .fixedSize()
    }

    /// The map scrolls sideways only in a window too narrow for keys of a readable size.
    private var keyboard: some View {
        SwiftUI.Group {
            if fits { keys } else { ScrollView(.horizontal) { keys } }
        }
            // No width of its own: the keys follow the page, so the page must not follow the keys,
            // or the split view folds the sidebar and inspector away to make room.
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: unit * 0.12) {
            ForEach(Array(KeyboardMap.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: unit * 0.12) {
                    ForEach(row) { key in keyView(key) }
                }
            }
            HStack(spacing: unit * 0.12) {
                ForEach(KeyboardMap.extraKeys) { key in keyView(key) }
            }
            .padding(.top, unit * 0.3)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func keyView(_ key: KeyboardMap.Key) -> some View {
        let modifiers = state.keyboardModifiers
        let uses = key.isModifier ? [] : used.filter { $0.combo.keyCode == key.keyCode && $0.combo.modifiers == modifiers }
        let owners = Set(uses.map(\.ownerID))
        let conflict = owners.count > 1 || Set(uses.map(\.title)).count > 1
        let held = KeyboardMap.modifierLabel(key.keyCode).map { label in modifiers.symbols.contains(label) } == true
        let fill: Color = key.isModifier
            ? (held ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06))
            : conflict ? Color.orange.opacity(0.8) : uses.isEmpty ? Color(nsColor: .controlBackgroundColor) : Color.accentColor.opacity(0.75)
        let label = KeyboardMap.modifierLabel(key.keyCode) ?? KeyNames.name(for: key.keyCode)
        let picked = state.pickedKey == key.keyCode
        return Button {
            guard !key.isModifier else { return }
            state.pickedKey = key.keyCode
            if !state.showInspector { MainWindow.shared.toggleInspector() }
        } label: {
            KeyFace(label: label, unit: unit, width: unit * key.width + unit * 0.12 * (key.width - 1), fill: fill,
                    ink: uses.isEmpty ? Color.primary : conflict ? Color.black : Color.white,
                    picked: picked, count: uses.count)
        }
        .buttonStyle(.plain)
        .disabled(key.isModifier)
        .help(uses.isEmpty ? "\(modifiers.symbols)\(label) is free" : uses.map { "\($0.combo.display) \($0.title) (\($0.ownerName))" }.joined(separator: "\n"))
        .accessibilityLabel(KeyCombo(keyCode: key.keyCode, modifiers: modifiers).spoken)
        .accessibilityValue(uses.isEmpty ? "free" : uses.map { "\($0.ownerName), \($0.title)" }.joined(separator: "; "))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            swatch(Color.accentColor.opacity(0.75), "Taken")
            swatch(Color.orange.opacity(0.8), "Conflict")
            swatch(Color(nsColor: .controlBackgroundColor), "Free")
        }
    }

    private func swatch(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
            Text(title).font(.caption)
        }
    }
}

/// One key of the map: its name, and how many shortcuts it holds when that's more than one.
private struct KeyFace: View {
    let label: String
    let unit: CGFloat
    let width: CGFloat
    let fill: Color
    let ink: Color
    let picked: Bool
    let count: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: unit * 0.14, style: .continuous)
        let size: CGFloat = max(label.count > 2 ? unit * 0.24 : unit * 0.34, 10)
        KeyText.text(label)
            .font(.system(size: size, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(ink)
            .frame(width: width, height: unit)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(picked ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: picked ? 2.5 : 0.5))
            .overlay(alignment: .topTrailing) {
                if count > 1, unit >= 34 {
                    Text(verbatim: "\(count)").font(.system(size: 10, weight: .semibold)).padding(3).foregroundStyle(ink)
                }
            }
    }
}

/// A box that says whether a shortcut you have in mind is taken, then free shortcuts to pick from.
struct FreeShortcutsView: View {
    @State var state: WindowState
    @State private var store = ShortcutStore.shared
    @State private var copied: KeyCombo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                test
                ForEach(KeyboardMap.suggestedModifierSets, id: \.rawValue) { mods in
                    let free = Array(KeyboardMap.suggestions(used: store.all, perSet: 40).filter { $0.modifiers == mods }.prefix(12))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(mods.symbols)  \(mods.name)").font(.headline)
                            Text(free.isEmpty ? "None free" : "\(free.count) free").font(.caption).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(free, id: \.self) { combo in chip(combo) }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Modifier buttons plus a typed key, not a recorder: a shortcut another app holds never
    /// reaches ShortcutsLens as a key press, so recording can't check the taken ones.
    private var test: some View {
        VStack(spacing: 14) {
            Text("Check a shortcut").font(.headline)
            HStack(spacing: 6) {
                ForEach(Modifiers.ordered, id: \.rawValue) { mod in
                    Toggle(isOn: Binding(get: { state.checkModifiers.contains(mod) },
                                         set: { on in
                                             if on { state.checkModifiers.insert(mod) } else { state.checkModifiers.remove(mod) }
                                             updateCheck()
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
                TextField("Key", text: $state.checkKey)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .multilineTextAlignment(.center)
                    .frame(width: 90)
                    .onSubmit(updateCheck)
                    .onChange(of: state.checkKey) { updateCheck() }
                    .accessibilityLabel("Key")
                    .help("A letter, number or symbol, or a key name like F5, Space, Return, Tab, Esc, Delete or Left")
                Menu {
                    ForEach(Self.specialKeys, id: \.self) { code in
                        Button(KeyNames.spokenName(for: code)) { state.checkKey = KeyNames.spokenName(for: code) }
                    }
                    Divider()
                    ForEach(Array(KeyNames.functionKeys.prefix(12)), id: \.self) { code in
                        Button(KeyNames.name(for: code)) { state.checkKey = KeyNames.name(for: code) }
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
            SwiftUI.Group {
                if let check = state.freeCheck {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        ComboUsage(combo: check)
                        Button("Copy") { copy(check) }.controlSize(.small)
                    }
                } else if keyUnreadable {
                    Text("Type one key, like C, 5, F5 or Space.").foregroundStyle(.orange)
                } else {
                    Text("Choose the modifier keys, then type the key.").foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 22)
            Text("Checks every shortcut ShortcutsLens can see, including the menus of the app in front when Accessibility is allowed. Some apps keep their shortcuts where no other app can look, so a free result is a very good sign rather than a guarantee.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    static let specialKeys = [49, 36, 48, 53, 51, 117, 123, 124, 126, 125, 115, 119, 116, 121]

    private var keyUnreadable: Bool {
        let key = state.checkKey.trimmingCharacters(in: .whitespaces)
        return !key.isEmpty && state.freeCheck == nil
    }

    /// Reads the key field. A pasted whole shortcut ("⌃⇧C", "ctrl+shift+c") sets the buttons too.
    private func updateCheck() {
        let key = state.checkKey.trimmingCharacters(in: .whitespaces)
        if key.count > 1, let whole = KeyEquivalentParser.parseReadable(key), let code = whole.keyCode {
            state.checkModifiers = whole.modifiers
            state.checkKey = KeyNames.name(for: code)
            return  // the field's change runs this again with just the key
        }
        guard !key.isEmpty, let code = KeyEquivalentParser.keyCode(named: key) else {
            state.freeCheck = nil
            return
        }
        state.freeCheck = KeyCombo(keyCode: code, modifiers: state.checkModifiers)
    }

    private func chip(_ combo: KeyCombo) -> some View {
        let done = copied == combo
        return Button { copy(combo) } label: {
            SwiftUI.Group {
                if done {
                    Label("Copied", systemImage: "checkmark").font(.system(size: 13, weight: .medium))
                } else {
                    KeyText.text(combo.display).font(.system(size: 13, weight: .medium)).tracking(1)
                }
            }
            .lineLimit(1)
            .foregroundStyle(done ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(Capsule().fill(done ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(done ? 0 : 0.16), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Copy \(combo.display)")
        .accessibilityLabel("Copy \(combo.spoken)")
    }

    private func copy(_ combo: KeyCombo) {
        Actions.copy(combo.display)
        withAnimation(.easeOut(duration: 0.15)) { copied = combo }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copied == combo { withAnimation(.easeOut(duration: 0.2)) { copied = nil } }
        }
    }
}
