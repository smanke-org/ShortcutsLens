import Foundation

/// A drawn Mac keyboard (US layout, by key code) for the keyboard map, and the search for
/// free shortcuts.
public enum KeyboardMap {
    public struct Key: Hashable, Sendable, Identifiable {
        public var keyCode: Int
        /// Width in key units (a letter key is 1).
        public var width: Double
        /// Modifier keys can't take a shortcut; they're drawn but never lit.
        public var isModifier: Bool
        public var id: Int { keyCode }
    }

    private static func k(_ code: Int, _ width: Double = 1, modifier: Bool = false) -> Key {
        Key(keyCode: code, width: width, isModifier: modifier)
    }

    /// Six rows of 15 units, like a MacBook keyboard.
    public static let rows: [[Key]] = [
        [k(53, 1.5)] + KeyNames.functionKeys.prefix(12).map { k($0, 1.125) },
        [k(50), k(18), k(19), k(20), k(21), k(23), k(22), k(26), k(28), k(25), k(29), k(27), k(24), k(51, 2)],
        [k(48, 1.5), k(12), k(13), k(14), k(15), k(17), k(16), k(32), k(34), k(31), k(35), k(33), k(30), k(42, 1.5)],
        [k(57, 1.75, modifier: true), k(0), k(1), k(2), k(3), k(5), k(4), k(38), k(40), k(37), k(41), k(39), k(36, 2.25)],
        [k(56, 2.25, modifier: true), k(6), k(7), k(8), k(9), k(11), k(45), k(46), k(43), k(47), k(44), k(60, 2.75, modifier: true)],
        [k(63, 1, modifier: true), k(59, 1, modifier: true), k(58, 1, modifier: true), k(55, 1.25, modifier: true), k(49, 5),
         k(54, 1.25, modifier: true), k(61, 1, modifier: true), k(123), k(126), k(125), k(124)],
    ]

    /// Keys a full-size keyboard adds, shown in a strip under the main block.
    public static let extraKeys: [Key] = [k(105), k(107), k(113), k(106), k(64), k(79), k(80), k(115), k(119), k(116), k(121), k(117)]

    /// Labels for the modifier keys, which `KeyNames` doesn't name.
    public static func modifierLabel(_ keyCode: Int) -> String? {
        switch keyCode {
        case 57: "⇪"
        case 56, 60: "⇧"
        case 63: "🌐"
        case 59: "⌃"
        case 58, 61: "⌥"
        case 55, 54: "⌘"
        default: nil
        }
    }

    public static var assignableKeys: [Int] {
        (rows.flatMap { $0 } + extraKeys).filter { !$0.isModifier }.map(\.keyCode)
    }

    /// Keys with no system-wide shortcut on them for these modifiers.
    public static func freeKeys(modifiers: Modifiers, used: [ShortcutEntry]) -> [Int] {
        let taken = Set(used.filter { $0.enabled && $0.isGlobal && $0.combo.modifiers == modifiers }.compactMap(\.combo.keyCode))
        return assignableKeys.filter { !taken.contains($0) }
    }

    /// Modifier sets worth suggesting, from least to most likely to clash with an app's
    /// own menus: three or four modifiers rarely appear in menus.
    public static let suggestedModifierSets: [Modifiers] = [
        [.control, .option, .command], [.control, .option, .shift, .command], [.control, .option], [.option, .shift, .command],
        [.control, .shift, .command], [.control, .option, .shift],
    ]

    /// Free shortcuts on letters and digits, a few per modifier set.
    public static func suggestions(used: [ShortcutEntry], perSet: Int = 6) -> [KeyCombo] {
        let letters = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        let digits = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        return suggestedModifierSets.flatMap { mods -> [KeyCombo] in
            let free = Set(freeKeys(modifiers: mods, used: used))
            return (letters + digits).filter(free.contains).prefix(perSet).map { KeyCombo(keyCode: $0, modifiers: mods) }
        }
    }
}
