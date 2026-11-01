import Foundation

/// Finds global shortcuts in an app's settings file.
///
/// There's no system list of the hotkeys apps register, but most apps save theirs with one
/// of a few libraries, and each leaves a recognizable shape: KeyboardShortcuts writes JSON
/// strings under `KeyboardShortcuts_<name>`, MASShortcut archives a `MASShortcut` object,
/// ShortcutRecorder and many hand-rolled ones save a dictionary of key code and modifier
/// flags. The scanner walks every value looking for those shapes, but only under keys
/// whose names say "hotkey" or "shortcut" (or inside a library's own format), so a window
/// position or a typed-key log isn't taken for a shortcut.
public enum PrefsScanner {
    public struct Found: Hashable, Sendable {
        /// The settings key path it came from ("hotkey.quickPaste", "keyBindings[2].key").
        public var path: String
        public var title: String
        public var combo: KeyCombo
    }

    public static func scan(_ domain: [String: Any]) -> [Found] {
        var found: [String: Found] = [:]
        for (key, value) in domain where !isNoise(key) && !isSentKeys(key) {
            walk(value, path: [key], parent: nil, context: isHotKeyName(key), into: &found)
        }
        return found.values.sorted { $0.path < $1.path }
    }

    // MARK: - Walking

    private static func walk(_ value: Any, path: [String], parent: [String: Any]?, context: Bool, into found: inout [String: Found]) {
        switch value {
        case let dict as [String: Any]:
            if let combo = combo(in: dict, context: context) {
                record(combo, path: path, titleFrom: dict, parent: parent, into: &found)
                return
            }
            // A keyed archive read from data: MASShortcut and friends.
            if dict["$archiver"] as? String == "NSKeyedArchiver", let objects = dict["$objects"] as? [Any] {
                for case let object as [String: Any] in objects {
                    if let combo = combo(in: object, context: true) {
                        record(combo, path: path, titleFrom: nil, parent: parent, into: &found)
                        return
                    }
                }
                return
            }
            for (key, child) in dict where !isNoise(key) && !isSentKeys(key) {
                walk(child, path: path + [key], parent: dict, context: context || isHotKeyName(key), into: &found)
            }
        case let array as [Any]:
            for (i, child) in array.enumerated() {
                walk(child, path: path + ["[\(i)]"], parent: parent, context: context, into: &found)
            }
        case let data as Data:
            guard data.count < 64 * 1024 else { return }
            if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), !(json is NSNull) {
                walk(json, path: path, parent: parent, context: context, into: &found)
            } else if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                walk(plist, path: path, parent: parent, context: context, into: &found)
            }
        case let string as String:
            guard context, string.count < 2048 else { return }
            if let first = string.first, first == "{" || first == "[",
               let json = try? JSONSerialization.jsonObject(with: Data(string.utf8)) {
                walk(json, path: path, parent: parent, context: context, into: &found)
            } else if let combo = KeyEquivalentParser.parseReadable(string) {
                record(combo, path: path, titleFrom: nil, parent: parent, into: &found)
            }
        default:
            break
        }
    }

    private static func record(_ combo: KeyCombo, path: [String], titleFrom dict: [String: Any]?, parent: [String: Any]?,
                               into found: inout [String: Found]) {
        let joined = path.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        let title = name(in: dict) ?? name(in: parent) ?? humanize(path)
        found[joined] = Found(path: joined, title: title, combo: combo)
    }

    // MARK: - Shapes

    private static let keyCodeKeys = ["carbonKeyCode", "keyCode", "KeyCode", "keycode", "key_code", "virtualKey", "code", "kc"]
    private static let carbonModifierKeys = ["carbonModifiers", "carbonFlags", "modif"]
    private static let cocoaModifierKeys = ["modifierFlags", "ModifierFlags", "cocoaModifiers"]
    private static let otherModifierKeys = ["modifiers", "mods", "modifierMask", "Modifiers"]

    /// A shortcut held in one dictionary, or nil.
    static func combo(in dict: [String: Any], context: Bool) -> KeyCombo? {
        guard let keyCodeKey = keyCodeKeys.first(where: { dict[$0] != nil }), let keyCode = int(dict[keyCodeKey]) else { return nil }
        // Outside a setting named for a shortcut only a library's own spelling counts: a plain
        // keyCode could be a key an app sends or logs, not one it listens for.
        if !context && keyCodeKey != "carbonKeyCode" { return nil }
        guard (0...127).contains(keyCode) else { return nil }
        let modifiers: Modifiers
        if let key = carbonModifierKeys.first(where: { dict[$0] != nil }), let v = int(dict[key]) {
            modifiers = Modifiers(carbon: v)
        } else if let key = cocoaModifierKeys.first(where: { dict[$0] != nil }), let v = int(dict[key]) {
            modifiers = Modifiers(cocoa: v)
        } else if let key = otherModifierKeys.first(where: { dict[$0] != nil }), let v = int(dict[key]) {
            modifiers = keyCodeKey == "carbonKeyCode" ? Modifiers(carbon: v) : Modifiers(guessing: v)
        } else {
            return nil
        }
        let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
        // A plain letter with no modifiers can't be a global shortcut; F-keys and the keypad can.
        if combo.modifiers.isEmpty && KeyNames.special[keyCode] == nil { return nil }
        if !context && combo.modifiers.isEmpty { return nil }
        return combo
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: n
        case let n as Double: Int(n)
        case let n as NSNumber: n.intValue
        case let s as String: Int(s)
        default: nil
        }
    }

    // MARK: - Names

    /// Keys whose name says the value is a shortcut.
    static func isHotKeyName(_ key: String) -> Bool {
        let lower = key.lowercased()
        guard lower.contains("hotkey") || lower.contains("hot_key") || lower.contains("shortcut")
            || lower.contains("keybinding") || lower.contains("keyequivalent") || lower.contains("hot key")
            || lower.hasPrefix("keyboardshortcuts_") else { return false }
        // Flags about shortcuts rather than shortcuts.
        let flags = ["enabled", "disabled", "mode", "migrat", "answered", "retired", "removed", "repair", "tooltip",
                     "present", "count", "version", "date", "shown", "seen", "hint", "onboard", "tip", "location", "prompt"]
        return !flags.contains { lower.contains($0) }
    }

    /// Containers of keys an app types or sends (launcher buttons, macros), not keys it
    /// listens for.
    private static func isSentKeys(_ key: String) -> Bool {
        let lower = key.lowercased()
        return ["slots", "buttons", "actions", "macros", "keystrokes", "sequences", "snippets"].contains { lower.hasSuffix($0) }
            || lower == "lastaction"
    }

    private static func isNoise(_ key: String) -> Bool {
        key.hasPrefix("NSWindow Frame") || key.hasPrefix("NSStatusItem") || key.hasPrefix("NSNavPanel")
            || key.hasPrefix("NSOSPL") || key.hasPrefix("SU") || key.hasPrefix("NSSplitView") || key.hasPrefix("NSTableView")
            || key.hasPrefix("NSToolbar") || key == "NSUserKeyEquivalents"
    }

    private static func name(in dict: [String: Any]?) -> String? {
        guard let dict else { return nil }
        for key in ["title", "name", "label", "displayName", "actionName", "Name", "Title", "action"] {
            // Not "finderOpenFolder:": a selector isn't a name.
            if let s = dict[key] as? String, !s.isEmpty, s.count < 80, !s.hasSuffix(":") {
                return key == "action" ? s.prefix(1).uppercased() + s.dropFirst() : s
            }
        }
        return nil
    }

    /// "captureTextHotKey" → "Capture text"; "hotkey.quickPaste" → "Quick paste";
    /// "KeyboardShortcuts_toggleWidget" → "Toggle widget".
    static func humanize(_ path: [String]) -> String {
        let generic: Set<String> = ["key", "hotkey", "hotkeys", "shortcut", "shortcuts", "value", "data", "keys", "keyboardshortcuts",
                                    "keybinding", "keybindings", "binding", "bindings", "combo"]
        for part in path.reversed() where !part.hasPrefix("[") {
            for piece in part.split(separator: ".").reversed() {
                var s = String(piece)
                // "CompletionManager_acceptFull…" → the part after the last underscore.
                if let underscore = s.lastIndex(of: "_") { s = String(s[s.index(after: underscore)...]) }
                if UUID(uuidString: s) != nil { return "Custom shortcut" }
                // "assistantHotkeyKey2" → "assistant".
                for _ in 0..<2 {
                    s = s.replacingOccurrences(of: "(?i)(hot ?key|shortcut|keycombo|key)\\d*$", with: "", options: .regularExpression)
                }
                for prefix in ["hotKey", "hotkey", "shortcut"] where s.hasPrefix(prefix) && s.count > prefix.count {
                    s.removeFirst(prefix.count)
                }
                let words = splitCamel(s)
                guard !words.isEmpty, !generic.contains(words.joined().lowercased()) else { continue }
                let sentence = words.joined(separator: " ").lowercased()
                return sentence.prefix(1).uppercased() + sentence.dropFirst()
            }
        }
        return "Global shortcut"
    }

    private static func splitCamel(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        for ch in s {
            if ch == "-" || ch == " " || ch == "_" {
                if !current.isEmpty { words.append(current); current = "" }
            } else if ch.isUppercase, let last = current.last, last.isLowercase || last.isNumber {
                words.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.filter { !$0.allSatisfy(\.isNumber) }
    }
}

/// Shortcut strings in the forms apps and macOS write them.
public enum KeyEquivalentParser {
    /// AppKit's key-equivalent strings, as in App Shortcuts and Services: `@` ⌘, `$` ⇧,
    /// `~` ⌥, `^` ⌃, `#` keypad, then the character ("@$k" is ⇧⌘K).
    public static func parseKeyEquivalent(_ string: String) -> KeyCombo? {
        var mods: Modifiers = []
        var rest = Substring(string)
        while let first = rest.first, rest.count > 1, "@$~^#".contains(first) {
            switch first {
            case "@": mods.insert(.command)
            case "$": mods.insert(.shift)
            case "~": mods.insert(.option)
            case "^": mods.insert(.control)
            default: break
            }
            rest = rest.dropFirst()
        }
        guard rest.count == 1, let ch = rest.first else { return nil }
        // An uppercase letter means Shift.
        if ch.isUppercase && ch.isLetter { mods.insert(.shift) }
        guard let code = KeyNames.keyCode(for: ch) else { return nil }
        return KeyCombo(keyCode: code, modifiers: mods)
    }

    /// Readable forms: "⌃⌥⌘K", "control+shift:L", "cmd+shift+space", "⌥⌘←".
    public static func parseReadable(_ string: String) -> KeyCombo? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= 40 else { return nil }
        var mods: Modifiers = []
        var remainder = ""
        // Glyph form.
        let glyphs: [Character: Modifiers] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command, "🌐": .function]
        if s.contains(where: { glyphs[$0] != nil }) {
            for ch in s {
                if let m = glyphs[ch] { mods.insert(m) } else { remainder.append(ch) }
            }
        } else {
            // Word form, joined with + - or space, key after ":" or last.
            let words: [String: Modifiers] = ["control": .control, "ctrl": .control, "option": .option, "opt": .option, "alt": .option,
                                              "shift": .shift, "command": .command, "cmd": .command, "fn": .function]
            let parts = s.lowercased().split(whereSeparator: { "+-: ".contains($0) }).map(String.init)
            guard !parts.isEmpty else { return nil }
            for part in parts {
                if let m = words[part] { mods.insert(m) } else if remainder.isEmpty { remainder = part } else { return nil }
            }
            // Must name at least one modifier, or "Space" alone would count.
            guard !mods.isEmpty else { return nil }
        }
        remainder = remainder.trimmingCharacters(in: .whitespaces)
        if remainder.isEmpty {
            return mods.isEmpty ? nil : KeyCombo(keyCode: nil, modifiers: mods)
        }
        guard !mods.isEmpty, let code = keyCode(named: remainder) else { return nil }
        return KeyCombo(keyCode: code, modifiers: mods)
    }

    static func keyCode(named name: String) -> Int? {
        if name.count == 1, let ch = name.first { return KeyNames.keyCode(for: ch) }
        let lower = name.lowercased()
        if let match = KeyNames.special.first(where: { $0.value.glyph.lowercased() == lower || $0.value.name.lowercased() == lower }) {
            return match.key
        }
        let aliases = ["space": 49, "return": 36, "enter": 36, "esc": 53, "escape": 53, "tab": 48, "delete": 51, "backspace": 51,
                       "left": 123, "right": 124, "down": 125, "up": 126]
        return aliases[lower]
    }
}

/// Shortcuts given to Services menu items (`pbs` › `NSServicesStatus`).
public enum ServicesShortcuts {
    public static func entries(_ status: [String: Any]) -> [ShortcutEntry] {
        status.compactMap { key, value in
            guard let dict = value as? [String: Any], let equivalent = dict["key_equivalent"] as? String,
                  let combo = KeyEquivalentParser.parseKeyEquivalent(equivalent) else { return nil }
            // "<bundle id> - <title> - <selector>"
            let parts = key.components(separatedBy: " - ")
            let title = parts.count >= 2 ? parts[1] : key
            let enabled = (dict["enabled_services_menu"] as? Bool) ?? true
            return ShortcutEntry(id: "services|\(key)", ownerID: ShortcutEntry.servicesOwner, ownerName: "Services",
                                 title: title, category: "Services", combo: combo, enabled: enabled, source: .services,
                                 detail: "A Services menu item. Change it in System Settings › Keyboard › Keyboard Shortcuts › Services.")
        }
    }
}

/// App Shortcuts: menu items given new keys in Keyboard settings (`NSUserKeyEquivalents`).
public enum MenuOverrides {
    public static func entries(_ equivalents: [String: Any], ownerID: String, ownerName: String) -> [ShortcutEntry] {
        equivalents.compactMap { title, value in
            guard let string = value as? String, let combo = KeyEquivalentParser.parseKeyEquivalent(string) else { return nil }
            // A menu path is written "\u{1b}File\u{1b}Export…".
            let readable = title.split(separator: "\u{1b}").joined(separator: " › ")
            return ShortcutEntry(id: "menu|\(ownerID)|\(title)", ownerID: ownerID, ownerName: ownerName, title: readable,
                                 category: "App Shortcuts", combo: combo, source: .menuOverride,
                                 detail: ownerID == ShortcutEntry.allAppsOwner
                                     ? "A menu shortcut for every app that has this menu item. Change it in System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts."
                                     : "A menu shortcut set in System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts. It works only while \(ownerName) is in front.")
        }
    }
}
