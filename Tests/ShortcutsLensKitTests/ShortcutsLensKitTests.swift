import Foundation
import Testing
@testable import ShortcutsLensKit

@Suite struct KeyComboTests {
    @Test func carbonAndCocoaModifiersAgree() {
        let carbon = Modifiers(carbon: 0x0100 | 0x0800 | 0x1000) // ⌘⌥⌃
        let cocoa = Modifiers(cocoa: 1 << 20 | 1 << 19 | 1 << 18)
        #expect(carbon == cocoa)
        #expect(carbon.symbols == "⌃⌥⌘")
        #expect(Modifiers(guessing: 6400) == carbon)
        #expect(Modifiers(guessing: 1_835_008) == carbon)
        // A compact ⌃1 ⌥2 ⇧4 ⌘8 set.
        #expect(Modifiers(guessing: 11) == carbon)
        #expect(Modifiers(guessing: 3) == [.control, .option])
        #expect(Modifiers(carbon: carbon.carbon) == carbon)
        #expect(Modifiers(cocoa: carbon.cocoa) == carbon)
    }

    @Test func fnFlagIsDroppedOnFKeysOnly() {
        // macOS stores ⌃F2 with the fn bit set.
        let stored = KeyCombo(keyCode: 120, modifiers: Modifiers(cocoa: 8_650_752))
        #expect(stored == KeyCombo(keyCode: 120, modifiers: [.control]))
        #expect(stored.display == "⌃F2")
        // Window tiling's 🌐⌃← isn't Spaces' ⌃←.
        #expect(KeyCombo(keyCode: 123, modifiers: Modifiers(cocoa: 8_650_752)).display == "🌐⌃←")
        #expect(KeyCombo(keyCode: 123, modifiers: Modifiers(cocoa: 8_650_752)) != KeyCombo(keyCode: 123, modifiers: [.control]))
        // On a letter, fn means the 🌐 key and stays.
        #expect(KeyCombo(keyCode: 14, modifiers: [.function]).display == "🌐E")
    }

    @Test func displayAndSpokenNames() {
        let combo = KeyCombo(keyCode: 49, modifiers: [.command, .shift])
        #expect(combo.display == "⇧⌘Space")
        #expect(combo.spoken == "Shift-Command-Space")
        #expect(KeyCombo(keyCode: nil, modifiers: [.control]).display == "⌃")
    }
}

@Suite struct ParserTests {
    @Test func keyEquivalentStrings() {
        #expect(KeyEquivalentParser.parseKeyEquivalent("@$k") == KeyCombo(keyCode: 40, modifiers: [.command, .shift]))
        #expect(KeyEquivalentParser.parseKeyEquivalent("@~^x") == KeyCombo(keyCode: 7, modifiers: [.command, .option, .control]))
        #expect(KeyEquivalentParser.parseKeyEquivalent("@K") == KeyCombo(keyCode: 40, modifiers: [.command, .shift]))
        #expect(KeyEquivalentParser.parseKeyEquivalent("") == nil)
    }

    @Test func readableStrings() {
        #expect(KeyEquivalentParser.parseReadable("control+shift:L") == KeyCombo(keyCode: 37, modifiers: [.control, .shift]))
        #expect(KeyEquivalentParser.parseReadable("⌃⌥⌘K") == KeyCombo(keyCode: 40, modifiers: [.control, .option, .command]))
        #expect(KeyEquivalentParser.parseReadable("cmd+shift+space") == KeyCombo(keyCode: 49, modifiers: [.command, .shift]))
        #expect(KeyEquivalentParser.parseReadable("control") == KeyCombo(keyCode: nil, modifiers: [.control]))
        // Not shortcuts.
        #expect(KeyEquivalentParser.parseReadable("Space") == nil)
        #expect(KeyEquivalentParser.parseReadable("hold") == nil)
        #expect(KeyEquivalentParser.parseReadable("screenCenter") == nil)
    }
}

@Suite struct ScannerTests {
    @Test func keyboardShortcutsLibraryStrings() {
        let found = PrefsScanner.scan([
            "KeyboardShortcuts_toggleWidget": #"{"carbonModifiers":2304,"carbonKeyCode":49}"#,
            "KeyboardShortcuts_28F23C69-342C-44B1-84BE-EC6D9DC0B79D": #"{"carbonModifiers":6400,"carbonKeyCode":83}"#,
        ])
        #expect(found.count == 2)
        let toggle = found.first { $0.path == "KeyboardShortcuts_toggleWidget" }
        #expect(toggle?.title == "Toggle widget")
        #expect(toggle?.combo == KeyCombo(keyCode: 49, modifiers: [.option, .command]))
        #expect(found.contains { $0.title == "Custom shortcut" })
    }

    @Test func jsonDataUnderHotKeyNames() {
        let data = Data(#"{"keyCode":19,"modifiers":6400,"display":"⌃⌥⌘2"}"#.utf8)
        let found = PrefsScanner.scan([
            "captureTextHotKey": data,
            "hotkey.quickPaste": Data(#"{"keyCode":48,"modifiers":2048}"#.utf8),
            "captureAgainHotKey": Data("null".utf8),
            "lastAction": Data(#"{"keyCode":12,"modifiers":256}"#.utf8),
        ])
        #expect(found.map(\.title).sorted() == ["Capture text", "Quick paste"])
        #expect(found.first { $0.path == "captureTextHotKey" }?.combo == KeyCombo(keyCode: 19, modifiers: [.control, .option, .command]))
        #expect(found.first { $0.path == "hotkey.quickPaste" }?.combo == KeyCombo(keyCode: 48, modifiers: [.option]))
    }

    @Test func keyCodesOutsideShortcutSettingsAreIgnored() {
        // Keys an app sends or logs, not ones it listens for.
        #expect(PrefsScanner.scan(["lastTyped": ["keyCode": 4, "modifiers": 256]]).isEmpty)
        // A library's own spelling counts anywhere.
        #expect(PrefsScanner.scan(["prefs": ["toggle": ["carbonKeyCode": 4, "carbonModifiers": 256]]]).count == 1)
    }

    @Test func masShortcutArchive() throws {
        let archive: [String: Any] = [
            "$version": 100000, "$archiver": "NSKeyedArchiver", "$top": ["root": 1],
            "$objects": ["$null", ["KeyCode": 50, "ModifierFlags": 262144], ["$classname": "MASShortcut"]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        let found = PrefsScanner.scan(["ShortcutListener_temporaryToggleCompletionsShortcut": data])
        #expect(found.count == 1)
        #expect(found.first?.title == "Temporary toggle completions")
        #expect(found.first?.combo == KeyCombo(keyCode: 50, modifiers: [.control]))
    }

    @Test func namedBindingsInArrays() {
        let found = PrefsScanner.scan(["keyBindings": [
            ["name": "Section header", "key": [String: Any]()],
            ["name": "Open in Finder", "key": ["keyCode": 3, "modifierFlags": 1_572_864, "charactersIgnoringModifiers": "f"]],
        ]])
        #expect(found.count == 1)
        #expect(found.first?.title == "Open in Finder")
        #expect(found.first?.combo == KeyCombo(keyCode: 3, modifiers: [.option, .command]))
    }

    @Test func wordStringsUnderHotKeyNames() {
        let found = PrefsScanner.scan(["assistantHotkeyKey2": "control+shift:L", "hotKeyMode": "hold", "userCity": "Springfield"])
        #expect(found.count == 1)
        #expect(found.first?.title == "Assistant")
    }

    @Test func flagsAboutShortcutsAreIgnored() {
        let found = PrefsScanner.scan(["globalHotkeyEnabled": true, "shortcutHintShown": "⌘K", "PromptModeShortcutEnabled": 1])
        #expect(found.isEmpty)
    }
}

@Suite struct SymbolicHotKeyTests {
    let catalog: [Int: SymbolicHotKeys.Definition] = [
        64: .init(id: 64, name: "Show Spotlight search", category: "Spotlight", defaultCombo: KeyCombo(keyCode: 49, modifiers: [.command]), defaultEnabled: true),
        28: .init(id: 28, name: "Save picture of screen as a file", category: "Screenshots", defaultCombo: KeyCombo(keyCode: 20, modifiers: [.shift, .command]), defaultEnabled: true),
        118: .init(id: 118, name: "Switch to Desktop 1", category: "Mission Control", defaultCombo: KeyCombo(keyCode: 18, modifiers: [.control]), defaultEnabled: false),
        160: .init(id: 160, name: "Show Apps", category: "Spotlight", defaultCombo: nil, defaultEnabled: true),
    ]

    @Test func userValuesOverrideDefaults() {
        let user = SymbolicHotKeys.userValues([
            "64": ["enabled": false],
            "28": ["enabled": true, "value": ["type": "standard", "parameters": [65535, 21, 1_179_648]]],
        ])
        let entries = Dictionary(uniqueKeysWithValues: SymbolicHotKeys.entries(catalog: catalog, user: user).map { ($0.id, $0) })
        #expect(entries["macOS|64"]?.enabled == false)
        #expect(entries["macOS|64"]?.combo == KeyCombo(keyCode: 49, modifiers: [.command]))
        #expect(entries["macOS|28"]?.combo == KeyCombo(keyCode: 21, modifiers: [.shift, .command]))
        #expect(entries["macOS|118"]?.enabled == false)
        // No keys, no entry.
        #expect(entries["macOS|160"] == nil)
    }

    @Test func liveValuesWin() {
        let live: [Int: SymbolicHotKeys.Value] = [64: .init(enabled: true, combo: KeyCombo(keyCode: 49, modifiers: [.option]))]
        let user = SymbolicHotKeys.userValues(["64": ["enabled": false]])
        let spotlight = SymbolicHotKeys.entries(catalog: catalog, user: user, live: live).first { $0.id == "macOS|64" }
        #expect(spotlight?.enabled == true)
        #expect(spotlight?.combo.display == "⌥Space")
    }

    @Test func liveFnBitOnArrowsDefersToTheDefault() {
        let spaces: [Int: SymbolicHotKeys.Definition] = [
            79: .init(id: 79, name: "Move left a Space", category: "Mission Control", defaultCombo: KeyCombo(keyCode: 123, modifiers: [.control]), defaultEnabled: true),
            240: .init(id: 240, name: "Tile Left Half", category: "Windows", defaultCombo: KeyCombo(keyCode: 123, modifiers: [.control, .function]), defaultEnabled: true),
        ]
        let reported = KeyCombo(keyCode: 123, modifiers: [.control, .function])
        let live: [Int: SymbolicHotKeys.Value] = [79: .init(enabled: true, combo: reported), 240: .init(enabled: true, combo: reported)]
        let entries = SymbolicHotKeys.entries(catalog: spaces, user: [:], live: live)
        #expect(Conflicts.find(in: entries).isEmpty)
        #expect(entries.first { $0.id == "macOS|79" }?.combo.display == "⌃←")
    }

    @Test func realTableLoads() {
        let table = SymbolicHotKeys.catalog(languages: ["en"])
        // Present on every Mac running macOS 26.
        guard !table.isEmpty else { return }
        #expect(table[64]?.name == "Show Spotlight search")
        #expect(table[28]?.category == "Screenshots")
        #expect(table[118]?.name.contains("1") == true)
    }
}

@Suite struct ConflictTests {
    func entry(_ owner: String, _ title: String, _ combo: KeyCombo, source: ShortcutSource = .appSettings, enabled: Bool = true) -> ShortcutEntry {
        ShortcutEntry(id: "\(owner)|\(title)", ownerID: owner, ownerName: owner, title: title, combo: combo, enabled: enabled, source: source)
    }

    @Test func twoAppsOnOneComboConflict() {
        let combo = KeyCombo(keyCode: 49, modifiers: [.command])
        let list = [entry("macOS", "Spotlight", combo, source: .macOS), entry("app.one", "Launcher", combo),
                    entry("app.two", "Other", KeyCombo(keyCode: 49, modifiers: [.option]))]
        let conflicts = Conflicts.find(in: list)
        #expect(conflicts.count == 1)
        #expect(conflicts[combo]?.count == 2)
        #expect(Conflicts.partners(of: list[0], in: conflicts).map(\.ownerID) == ["app.one"])
    }

    @Test func disabledAndInAppEntriesDontConflict() {
        let combo = KeyCombo(keyCode: 49, modifiers: [.command])
        let list = [entry("macOS", "Spotlight", combo, source: .macOS, enabled: false), entry("app.one", "Launcher", combo),
                    entry("app.two", "Menu item", combo, source: .menuOverride)]
        #expect(Conflicts.find(in: list).isEmpty)
    }

    @Test func sameShortcutReportedTwiceByOneAppIsNotAConflict() {
        let combo = KeyCombo(keyCode: 2, modifiers: [.control, .option])
        let list = [entry("app.one", "Capture", combo, source: .appReport), entry("app.one", "capture", combo)]
        #expect(Conflicts.find(in: list).isEmpty)
        // Settings files often keep one shortcut twice under two names.
        #expect(Conflicts.find(in: [entry("app.one", "Layout", combo), entry("app.one", "Custom shortcut", combo)]).isEmpty)
        // Two different actions an app reports on one combo do collide.
        #expect(Conflicts.find(in: [entry("app.one", "A", combo, source: .appReport), entry("app.one", "B", combo, source: .appReport)]).count == 1)
    }

    @Test func holdAndDoubleTapOfOneKeyInOneAppDontConflict() {
        let option = KeyCombo(keyCode: nil, modifiers: [.option])
        let info: [AnyHashable: Any] = ["app": "Dictate", "shortcuts": [
            ["id": "dictation", "title": "Dictation", "carbonModifiers": 0x800, "gesture": "hold"],
            ["id": "handsFree", "title": "Hands-free", "carbonModifiers": 0x800, "gesture": "doubleTap"],
            ["id": "other", "title": "Other", "carbonModifiers": 0x800, "gesture": "press"],
        ]]
        let reported = ShortcutReports.entries(sender: "app.dictate", userInfo: info) ?? []
        #expect(reported.map(\.gesture) == ["hold", "doubleTap", nil])
        #expect(reported.allSatisfy { $0.combo == option })
        // Hold, double-tap and a press: three different ways to use ⌥, none colliding.
        #expect(Conflicts.find(in: reported).isEmpty)
        // Two actions on the same gesture still collide.
        var twin = reported[0]
        twin.id = "twin"; twin.title = "Assistant"
        #expect(Conflicts.find(in: reported + [twin])[option]?.map(\.id) == [reported[0].id, "twin"])
        // Another app on the same keys collides with all of them.
        let other = entry("app.two", "Launcher", option, source: .appReport)
        let conflicts = Conflicts.find(in: reported + [other])
        #expect(conflicts[option]?.count == 4)
        #expect(Conflicts.partners(of: reported[0], in: conflicts).map(\.ownerID) == ["app.two"])
    }

    @Test func launcherButtonsAreNotHotKeys() {
        let found = PrefsScanner.scan([
            "hotKey": Data(#"{"keyCode":49,"modifiers":11,"key":"Space"}"#.utf8),
            "slots": [["title": "Save windows", "shortcut": ["keyCode": 1, "modifiers": 11]]],
        ])
        #expect(found.count == 1)
        #expect(found.first?.title == "Global shortcut")
        #expect(found.first?.combo.display == "⌃⌥⌘Space")
    }
}

@Suite struct KeyboardMapTests {
    @Test func freeKeysSkipTakenOnes() {
        let used = [ShortcutEntry(id: "a", ownerID: "a", ownerName: "A", title: "A",
                                  combo: KeyCombo(keyCode: 40, modifiers: [.control, .option, .command]), source: .appSettings)]
        let free = KeyboardMap.freeKeys(modifiers: [.control, .option, .command], used: used)
        #expect(!free.contains(40))
        #expect(free.contains(37))
        #expect(KeyboardMap.freeKeys(modifiers: [.command], used: used).contains(40))
    }

    @Test func suggestionsAreFree() {
        let suggestions = KeyboardMap.suggestions(used: [])
        #expect(suggestions.count == KeyboardMap.suggestedModifierSets.count * 6)
        #expect(Set(suggestions).count == suggestions.count)
    }

    @Test func everyAssignableKeyHasAName() {
        for code in KeyboardMap.assignableKeys {
            #expect(!KeyNames.name(for: code).hasPrefix("Key "), "key \(code)")
        }
    }
}

@Suite struct ReportTests {
    @Test func reportsDecode() {
        let entries = ShortcutReports.entries(sender: "com.example.app", userInfo: [
            "app": "Example",
            "shortcuts": [["id": "capture", "title": "Capture Text", "keyCode": 19, "carbonModifiers": 6400],
                          ["id": "broken"]],
        ])
        #expect(entries?.count == 1)
        #expect(entries?.first?.combo == KeyCombo(keyCode: 19, modifiers: [.control, .option, .command]))
        #expect(entries?.first?.ownerName == "Example")
        #expect(ShortcutReports.entries(sender: "x", userInfo: [:]) == nil)
    }
}

@Suite struct SearchTests {
    @Test func matchesTitlesAndGlyphsInAnyOrder() {
        let e = ShortcutEntry(id: "x", ownerID: "macOS", ownerName: "macOS", title: "Save picture of selected area as a file",
                              category: "Screenshots", combo: KeyCombo(keyCode: 21, modifiers: [.shift, .command]), source: .macOS)
        #expect(e.matches("screenshots"))
        #expect(e.matches("selected file"))
        #expect(e.matches("⌘⇧4"))
        #expect(e.matches("⇧⌘"))
        #expect(!e.matches("⌥4"))
        #expect(!e.matches("spotlight"))
    }
}
