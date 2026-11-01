import Foundation

/// macOS's own shortcuts: the ones in System Settings › Keyboard › Keyboard Shortcuts.
///
/// macOS stores only the ones you've changed (`com.apple.symbolichotkeys`), so the names,
/// sections and default keys come from the table Keyboard settings itself is built from
/// (`DefaultShortcutsTable.xml` in KeyboardSettings.appex), and the WindowServer's live
/// values win over both when the app can read them.
public enum SymbolicHotKeys {
    public struct Definition: Sendable, Hashable {
        public var id: Int
        public var name: String
        public var category: String
        public var defaultCombo: KeyCombo?
        public var defaultEnabled: Bool
    }

    /// A value from the user's settings or the WindowServer.
    public struct Value: Sendable, Hashable {
        public var enabled: Bool
        /// nil when the shortcut has no keys.
        public var combo: KeyCombo?
        public init(enabled: Bool, combo: KeyCombo?) {
            self.enabled = enabled
            self.combo = combo
        }
    }

    public static let settingsExtension = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex/Contents/Resources")

    /// Reads the table for the user's language, falling back to English.
    public static func catalog(resources: URL = settingsExtension, languages: [String] = Locale.preferredLanguages) -> [Int: Definition] {
        let strings = localizedStrings(resources: resources, languages: languages)
        var result: [Int: Definition] = [:]
        if let data = try? Data(contentsOf: resources.appending(path: "en.lproj/DefaultShortcutsTable.xml")),
           let groups = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
            for group in groups {
                let category = localize(group["name"] as? String ?? "", strings)
                collect(group["elements"] as? [[String: Any]] ?? [], category: category,
                        enabled: group["enabled"] as? Bool ?? true, strings: strings, into: &result)
            }
        }
        // Switch to Desktop 1–16 live in a table of their own.
        if let data = try? Data(contentsOf: resources.appending(path: "DefaultSpacesShortcuts.xml")),
           let spaces = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
            let category = localize("DO_NOT_LOCALIZE: Expose and Spaces", strings)
            collect(spaces, category: category, enabled: false, strings: strings, into: &result)
        }
        for (id, name) in extraNames where result[id] == nil {
            result[id] = Definition(id: id, name: name.name, category: name.category, defaultCombo: nil, defaultEnabled: true)
        }
        return result
    }

    /// Shortcuts the WindowServer knows that the table leaves out.
    static let extraNames: [Int: (name: String, category: String)] = [
        1: ("Switch to the next app", "App Switcher"),
        2: ("Switch to the previous app", "App Switcher"),
        57: ("Move focus to status menus", "Keyboard"),
        98: ("Show Help menu", "App Shortcuts"),
    ]

    private static func collect(_ elements: [[String: Any]], category: String, enabled: Bool,
                                strings: [String: String], into result: inout [Int: Definition]) {
        for element in elements {
            let elementEnabled = element["enabled"] as? Bool ?? enabled
            if let children = element["elements"] as? [[String: Any]] {
                collect(children, category: category, enabled: elementEnabled, strings: strings, into: &result)
                continue
            }
            // Apple's own spelling.
            guard let id = element["sybmolichotkey"] as? Int else { continue }
            let key = element["key"] as? Int ?? 65535
            let mods = element["modifier"] as? Int ?? 0
            let combo = key == 65535 ? nil : KeyCombo(keyCode: key, modifiers: Modifiers(cocoa: mods))
            result[id] = Definition(id: id, name: localize(element["name"] as? String ?? "Shortcut \(id)", strings),
                                    category: category, defaultCombo: combo, defaultEnabled: elementEnabled)
        }
    }

    private static func localizedStrings(resources: URL, languages: [String]) -> [String: String] {
        guard let data = try? Data(contentsOf: resources.appending(path: "DefaultShortcutsTable.loctable")),
              // Not [String: [String: String]]: a LocProvenance entry sits beside the languages.
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        for language in languages {
            let code = language.replacingOccurrences(of: "-", with: "_")
            for candidate in [code, String(code.prefix(while: { $0 != "_" }))] {
                if let strings = table[candidate] as? [String: String] { return strings }
            }
        }
        return table["en"] as? [String: String] ?? [:]
    }

    private static func localize(_ raw: String, _ strings: [String: String]) -> String {
        let key = raw.replacingOccurrences(of: "DO_NOT_LOCALIZE: ", with: "")
        return strings[key] ?? key
    }

    /// The values in `com.apple.symbolichotkeys` › `AppleSymbolicHotKeys`.
    public static func userValues(_ plist: [String: Any]) -> [Int: Value] {
        var result: [Int: Value] = [:]
        for (key, raw) in plist {
            guard let id = Int(key), let dict = raw as? [String: Any] else { continue }
            let enabled = dict["enabled"] as? Bool ?? (dict["enabled"] as? Int).map { $0 != 0 } ?? true
            var combo: KeyCombo?
            if let value = dict["value"] as? [String: Any], let params = value["parameters"] as? [Int] {
                if value["type"] as? String == "modifier", let mods = params.first {
                    combo = KeyCombo(keyCode: nil, modifiers: Modifiers(cocoa: mods))
                } else if params.count >= 3, params[1] != 65535 {
                    combo = KeyCombo(keyCode: params[1], modifiers: Modifiers(cocoa: params[2]))
                }
            }
            result[id] = Value(enabled: enabled, combo: combo)
        }
        return result
    }

    /// The shortcuts as they stand: live values first, then the user's settings, then the
    /// defaults. Entries with no keys are left out.
    public static func entries(catalog: [Int: Definition], user: [Int: Value], live: [Int: Value] = [:]) -> [ShortcutEntry] {
        catalog.values.compactMap { def in
            let combo: KeyCombo?
            let enabled: Bool
            if let value = live[def.id] {
                // The WindowServer reports arrows with the fn bit whether or not the shortcut
                // needs fn (Spaces' ⌃← comes back as 🌐⌃←, the same as tiling's). When that bit
                // is the only difference from the default, the default says which it is.
                if let live = value.combo, let standard = def.defaultCombo, live.keyCode == standard.keyCode,
                   live.modifiers.subtracting(.function) == standard.modifiers.subtracting(.function) {
                    (combo, enabled) = (standard, value.enabled)
                } else {
                    (combo, enabled) = (value.combo, value.enabled)
                }
            } else if let value = user[def.id] {
                // An entry with no value keeps the default keys (macOS writes just
                // `enabled` when a box is unchecked).
                (combo, enabled) = (value.combo ?? def.defaultCombo, value.enabled)
            } else {
                (combo, enabled) = (def.defaultCombo, def.defaultEnabled)
            }
            guard let combo else { return nil }
            return ShortcutEntry(id: "macOS|\(def.id)", ownerID: ShortcutEntry.macOSOwner, ownerName: "macOS",
                                 title: def.name, category: def.category, combo: combo, enabled: enabled, source: .macOS,
                                 detail: "Change it in System Settings › Keyboard › Keyboard Shortcuts › \(def.category).")
        }
    }
}

/// macOS shortcuts that aren't settings at all: they're fixed.
public enum BuiltInShortcuts {
    public static var entries: [ShortcutEntry] {
        let items: [(String, String, Int, Modifiers)] = [
            ("forcequit", "Force Quit Applications", 53, [.option, .command]),
            ("lock", "Lock Screen", 12, [.control, .command]),
            ("logout", "Log Out", 12, [.shift, .command]),
            ("logoutnow", "Log Out without asking", 12, [.option, .shift, .command]),
            ("emoji", "Emoji & Symbols", 49, [.control, .command]),
            ("globe-emoji", "Emoji & Symbols", 14, [.function]),
            ("globe-fullscreen", "Turn full screen on or off", 3, [.function]),
            ("globe-dock", "Move focus to the Dock", 0, [.function]),
            ("globe-apps", "Show Apps", 0, [.function, .shift]),
            ("globe-control", "Show Control Center", 8, [.function]),
            ("globe-notifications", "Show Notification Center", 45, [.function]),
        ]
        return items.map { id, title, key, mods in
            ShortcutEntry(id: "builtIn|\(id)", ownerID: ShortcutEntry.macOSOwner, ownerName: "macOS", title: title,
                          category: mods.contains(.function) ? "🌐 Globe key" : "Built in",
                          combo: KeyCombo(keyCode: key, modifiers: mods), source: .builtIn,
                          detail: mods.contains(.function)
                              ? "Works with the 🌐 or fn key. Choose what the key does on its own in System Settings › Keyboard."
                              : "Built into macOS; it can't be changed.")
        }
    }
}
