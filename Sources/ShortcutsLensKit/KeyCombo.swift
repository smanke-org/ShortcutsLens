import Foundation

/// The modifier keys of a shortcut, independent of how an app stored them: Carbon's
/// `cmdKey`-style bits, AppKit's `NSEvent.ModifierFlags`, or glyphs in a string.
public struct Modifiers: OptionSet, Hashable, Codable, Sendable, Comparable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)
    /// fn, the 🌐 key on newer keyboards.
    public static let function = Modifiers(rawValue: 1 << 4)

    /// ⌃⌥⇧⌘ in the order macOS writes them.
    public static let ordered: [Modifiers] = [.function, .control, .option, .shift, .command]

    // Carbon (Events.h)
    private static let carbonCommand = 0x0100, carbonShift = 0x0200, carbonOption = 0x0800, carbonControl = 0x1000
    // AppKit (NSEvent.ModifierFlags)
    private static let cocoaShift = 1 << 17, cocoaControl = 1 << 18, cocoaOption = 1 << 19, cocoaCommand = 1 << 20,
                       cocoaFunction = 1 << 23

    public init(carbon value: Int) {
        var m: Modifiers = []
        if value & Self.carbonControl != 0 { m.insert(.control) }
        if value & Self.carbonOption != 0 { m.insert(.option) }
        if value & Self.carbonShift != 0 { m.insert(.shift) }
        if value & Self.carbonCommand != 0 { m.insert(.command) }
        self = m
    }

    public init(cocoa value: Int) {
        var m: Modifiers = []
        if value & Self.cocoaControl != 0 { m.insert(.control) }
        if value & Self.cocoaOption != 0 { m.insert(.option) }
        if value & Self.cocoaShift != 0 { m.insert(.shift) }
        if value & Self.cocoaCommand != 0 { m.insert(.command) }
        if value & Self.cocoaFunction != 0 { m.insert(.function) }
        self = m
    }

    /// For values whose style isn't labeled. AppKit's flags all sit at bit 17 or above and
    /// Carbon's at bits 8 to 12, so the size tells them apart; anything under 256 is a
    /// compact ⌃ 1, ⌥ 2, ⇧ 4, ⌘ 8 set, as some apps (and this type) store.
    public init(guessing value: Int) {
        if value >= 1 << 16 {
            self = Modifiers(cocoa: value)
        } else if value >= 0x100 {
            self = Modifiers(carbon: value)
        } else {
            self = Modifiers(rawValue: value & 0x1F)
        }
    }

    public var carbon: Int {
        var v = 0
        if contains(.control) { v |= Self.carbonControl }
        if contains(.option) { v |= Self.carbonOption }
        if contains(.shift) { v |= Self.carbonShift }
        if contains(.command) { v |= Self.carbonCommand }
        return v
    }

    public var cocoa: Int {
        var v = 0
        if contains(.control) { v |= Self.cocoaControl }
        if contains(.option) { v |= Self.cocoaOption }
        if contains(.shift) { v |= Self.cocoaShift }
        if contains(.command) { v |= Self.cocoaCommand }
        if contains(.function) { v |= Self.cocoaFunction }
        return v
    }

    public var symbols: String {
        Self.ordered.filter(contains).map(\.symbol).joined()
    }

    public var symbol: String {
        switch self {
        case .function: "🌐"
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        default: symbols
        }
    }

    public var name: String {
        switch self {
        case .function: "fn"
        case .control: "Control"
        case .option: "Option"
        case .shift: "Shift"
        case .command: "Command"
        default: Self.ordered.filter(contains).map(\.name).joined(separator: "-")
        }
    }

    public var count: Int { Self.ordered.filter(contains).count }

    public static func < (a: Modifiers, b: Modifiers) -> Bool {
        a.count != b.count ? a.count < b.count : a.rawValue < b.rawValue
    }
}

/// One key plus modifiers, or modifiers alone for apps triggered by holding or
/// double-pressing a modifier.
public struct KeyCombo: Hashable, Codable, Sendable, Comparable {
    /// The virtual key code (kVK_…), nil for a modifier-only trigger.
    public var keyCode: Int?
    public var modifiers: Modifiers

    public init(keyCode: Int?, modifiers: Modifiers) {
        self.keyCode = keyCode
        // macOS sets the fn flag on F-keys whether or not fn is held, so there it says nothing
        // and would keep equal shortcuts apart. On arrows it counts: macOS tiles windows with
        // 🌐⌃← and moves between Spaces with ⌃←.
        var m = modifiers
        if let keyCode, KeyNames.impliesFunction(keyCode) { m.remove(.function) }
        self.modifiers = m
    }

    public var isModifierOnly: Bool { keyCode == nil }

    /// "⌃⌥⌘K".
    public var display: String {
        guard let keyCode else { return modifiers.symbols }
        return modifiers.symbols + KeyNames.name(for: keyCode)
    }

    /// "Control-Option-Command-K", for VoiceOver and tooltips.
    public var spoken: String {
        guard let keyCode else { return modifiers.name }
        let key = KeyNames.spokenName(for: keyCode)
        return modifiers.isEmpty ? key : modifiers.name + "-" + key
    }

    public static func < (a: KeyCombo, b: KeyCombo) -> Bool {
        if a.modifiers != b.modifiers { return a.modifiers < b.modifiers }
        return (a.keyCode ?? -1) < (b.keyCode ?? -1)
    }
}

/// Names for virtual key codes. Letters and punctuation come from the US layout unless the
/// app supplies the user's layout through `layoutName`.
public enum KeyNames {
    /// Set by the app to read the current keyboard layout (UCKeyTranslate); nil falls back
    /// to US names.
    nonisolated(unsafe) public static var layoutName: ((Int) -> String?)?

    public static func name(for keyCode: Int) -> String {
        if let special = special[keyCode] { return special.glyph }
        if let name = layoutName?(keyCode), !name.isEmpty { return name.uppercased() }
        return ansi[keyCode]?.uppercased() ?? "Key \(keyCode)"
    }

    public static func spokenName(for keyCode: Int) -> String {
        if let special = special[keyCode] { return special.name }
        return name(for: keyCode)
    }

    /// Keys whose shortcuts carry the fn flag whether or not fn is down.
    public static func impliesFunction(_ keyCode: Int) -> Bool {
        functionKeys.contains(keyCode)
    }

    public static let functionKeys: [Int] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// The key code for a typed character, US layout (for `@$k`-style strings).
    public static func keyCode(for character: Character) -> Int? {
        let lower = String(character).lowercased()
        if let code = ansi.first(where: { $0.value == lower })?.key { return code }
        switch character {
        case " ": return 49
        case "\r", "\n": return 36
        case "\t": return 48
        case "\u{1b}": return 53
        case "\u{7f}", "\u{8}": return 51
        default: break
        }
        // AppKit's function-key characters (NSUpArrowFunctionKey and so on).
        guard let scalar = character.unicodeScalars.first?.value else { return nil }
        switch scalar {
        case 0xF700: return 126
        case 0xF701: return 125
        case 0xF702: return 123
        case 0xF703: return 124
        case 0xF704...0xF713: return functionKeys[Int(scalar - 0xF704)]
        case 0xF728: return 117
        case 0xF729: return 115
        case 0xF72B: return 119
        case 0xF72C: return 116
        case 0xF72D: return 121
        default: return nil
        }
    }

    public struct Special: Sendable { public let glyph: String; public let name: String }

    public static let special: [Int: Special] = {
        var s: [Int: Special] = [
            36: .init(glyph: "↩", name: "Return"), 48: .init(glyph: "⇥", name: "Tab"),
            49: .init(glyph: "Space", name: "Space"), 51: .init(glyph: "⌫", name: "Delete"),
            53: .init(glyph: "⎋", name: "Escape"), 76: .init(glyph: "⌤", name: "Enter"),
            117: .init(glyph: "⌦", name: "Forward Delete"), 115: .init(glyph: "↖", name: "Home"),
            119: .init(glyph: "↘", name: "End"), 116: .init(glyph: "⇞", name: "Page Up"),
            121: .init(glyph: "⇟", name: "Page Down"), 123: .init(glyph: "←", name: "Left Arrow"),
            124: .init(glyph: "→", name: "Right Arrow"), 125: .init(glyph: "↓", name: "Down Arrow"),
            126: .init(glyph: "↑", name: "Up Arrow"), 114: .init(glyph: "Help", name: "Help"),
            57: .init(glyph: "⇪", name: "Caps Lock"),
            // What menus report for Start Dictation's key (the 🎤 key on newer keyboards).
            128: .init(glyph: "🎤", name: "Dictation"),
            65: .init(glyph: "Pad.", name: "Keypad Decimal"), 67: .init(glyph: "Pad*", name: "Keypad Multiply"),
            69: .init(glyph: "Pad+", name: "Keypad Plus"), 71: .init(glyph: "Clear", name: "Keypad Clear"),
            75: .init(glyph: "Pad/", name: "Keypad Divide"), 78: .init(glyph: "Pad-", name: "Keypad Minus"),
            81: .init(glyph: "Pad=", name: "Keypad Equals"),
        ]
        for (i, code) in functionKeys.enumerated() { s[code] = .init(glyph: "F\(i + 1)", name: "F\(i + 1)") }
        for (digit, code) in [82, 83, 84, 85, 86, 87, 88, 89, 91, 92].enumerated() {
            s[code] = .init(glyph: "Pad\(digit)", name: "Keypad \(digit)")
        }
        return s
    }()

    /// US layout characters by key code.
    public static let ansi: [Int: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 10: "§", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[",
        34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n",
        46: "m", 47: ".", 50: "`",
    ]
}
