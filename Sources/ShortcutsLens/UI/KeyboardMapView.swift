import ShortcutsLensKit
import SwiftUI

/// A keyboard with every key lit that has a system-wide shortcut for the chosen modifiers.
struct KeyboardMapView: View {
    @State private var store = ShortcutStore.shared
    @State private var modifiers: Modifiers = [.command]
    @State private var picked: Int?
    @State private var includeMenus = false

    private var used: [ShortcutEntry] {
        var list = store.globalVisible.filter(\.enabled)
        if includeMenus { list += store.frontmostMenus.filter(\.enabled) }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Text("Modifiers").foregroundStyle(.secondary)
                    ForEach(Modifiers.ordered, id: \.rawValue) { mod in
                        Toggle(isOn: Binding(get: { modifiers.contains(mod) },
                                             set: { if $0 { modifiers.insert(mod) } else { modifiers.remove(mod) } })) {
                            Text(mod.symbol).font(.system(size: 15, weight: .medium)).frame(minWidth: 22)
                        }
                        .toggleStyle(.button)
                        .help(mod.name)
                        .accessibilityLabel(mod.name)
                    }
                    Spacer()
                    if store.accessibilityTrusted, let app = store.frontmost?.localizedName {
                        Toggle("Include \(app)'s menus", isOn: $includeMenus)
                            .onChange(of: includeMenus) { if includeMenus { store.readFrontmostMenus() } }
                    }
                }
                keyboard
                legend
                if let picked { pickedKey(picked) }
            }
            .padding(20)
        }
    }

    private var keyboard: some View {
        GeometryReader { geo in
            // 15.5 key units plus the gaps between up to 14 keys.
            let unit = min((geo.size.width - 20) / (15.5 + 0.12 * 14), 58)
            VStack(alignment: .leading, spacing: unit * 0.12) {
                ForEach(Array(KeyboardMap.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: unit * 0.12) {
                        ForEach(row) { key in keyView(key, unit: unit) }
                    }
                }
                HStack(spacing: unit * 0.12) {
                    ForEach(KeyboardMap.extraKeys) { key in keyView(key, unit: unit) }
                }
                .padding(.top, unit * 0.3)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        }
        .frame(height: 460)
    }

    private func keyView(_ key: KeyboardMap.Key, unit: CGFloat) -> some View {
        let uses = key.isModifier ? [] : used.filter { $0.combo.keyCode == key.keyCode && $0.combo.modifiers == modifiers }
        let owners = Set(uses.map(\.ownerID))
        let conflict = owners.count > 1 || Set(uses.map(\.title)).count > 1
        let fill: Color = key.isModifier
            ? (KeyboardMap.modifierLabel(key.keyCode).map { label in modifiers.symbols.contains(label) } == true ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06))
            : conflict ? Color.orange.opacity(0.75) : uses.isEmpty ? Color(nsColor: .controlBackgroundColor) : Color.accentColor.opacity(0.7)
        let label = KeyboardMap.modifierLabel(key.keyCode) ?? KeyNames.name(for: key.keyCode)
        return Button {
            picked = key.isModifier ? nil : key.keyCode
        } label: {
            VStack(spacing: 1) {
                Text(label).font(.system(size: label.count > 2 ? unit * 0.2 : unit * 0.3, weight: .medium))
                if let first = uses.first {
                    Text(uses.count > 1 ? "\(uses.count) uses" : first.ownerName)
                        .font(.system(size: unit * 0.15)).lineLimit(1).opacity(0.85)
                }
            }
            .foregroundStyle(uses.isEmpty ? Color.primary : Color.white)
            .frame(width: unit * key.width + unit * 0.12 * (key.width - 1), height: unit)
            .background(RoundedRectangle(cornerRadius: unit * 0.14, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: unit * 0.14, style: .continuous)
                .strokeBorder(picked == key.keyCode ? Color.primary : Color.primary.opacity(0.15), lineWidth: picked == key.keyCode ? 2 : 0.5))
        }
        .buttonStyle(.plain)
        .disabled(key.isModifier)
        .help(uses.isEmpty ? "\(modifiers.symbols)\(label) is free" : uses.map { "\($0.ownerName): \($0.title)" }.joined(separator: "\n"))
        .accessibilityLabel(KeyCombo(keyCode: key.keyCode, modifiers: modifiers).spoken)
        .accessibilityValue(uses.isEmpty ? "free" : uses.map { "\($0.ownerName), \($0.title)" }.joined(separator: "; "))
    }

    private var legend: some View {
        HStack(spacing: 16) {
            swatch(Color.accentColor.opacity(0.7), "Taken")
            swatch(Color.orange.opacity(0.75), "Conflict")
            swatch(Color(nsColor: .controlBackgroundColor), "Free")
            Spacer()
            Text("Click a key to see everything on it, with any modifiers.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func swatch(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 14, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
            Text(title).font(.caption)
        }
    }

    private func pickedKey(_ keyCode: Int) -> some View {
        let onKey = used.filter { $0.combo.keyCode == keyCode }.sorted { $0.combo < $1.combo }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Everything on \(KeyNames.name(for: keyCode))").font(.headline)
            if onKey.isEmpty {
                Text("No system-wide shortcut uses this key.").foregroundStyle(.secondary)
            } else {
                ForEach(onKey) { entry in ShortcutRow(entry: entry) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

/// Free shortcuts to pick from, and a box that says whether one you have in mind is taken.
struct FreeShortcutsView: View {
    @State private var store = ShortcutStore.shared
    @State private var check: KeyCombo?
    @State private var copied: KeyCombo?

    var body: some View {
        Form {
            Section {
                LabeledContent("Press a shortcut") {
                    ShortcutRecorder(combo: $check, placeholder: "Click, then press keys", requireModifier: false)
                }
                if let check { ComboUsage(combo: check) }
            } header: {
                Text("Is it free?")
            } footer: {
                Text("Checks every shortcut ShortcutsLens can see, including the menus of the app in front when Accessibility is allowed. Some apps keep their shortcuts where no other app can look, so a free result is a very good sign rather than a guarantee.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(KeyboardMap.suggestedModifierSets, id: \.rawValue) { mods in
                let free = KeyboardMap.suggestions(used: store.all, perSet: 40).filter { $0.modifiers == mods }.prefix(12)
                Section("\(mods.symbols)  \(mods.name)") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(Array(free), id: \.self) { combo in
                            Button {
                                Actions.copy(combo.display)
                                copied = combo
                            } label: {
                                Keycaps(combo: combo, size: .small)
                                    .overlay(alignment: .topTrailing) {
                                        if copied == combo {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).offset(x: 8, y: -6)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help("Copy \(combo.display)")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
    }
}
