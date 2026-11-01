import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ShortcutsLensKit

/// Reads every source of shortcuts. Runs off the main thread: the settings scan opens a few
/// hundred files.
enum SystemSources {
    struct Result: Sendable {
        var entries: [ShortcutEntry]
        /// Apps found with shortcuts, by bundle id, with where they live.
        var apps: [String: AppRecord]
    }

    struct AppRecord: Sendable, Hashable {
        var bundleID: String
        var name: String
        var url: URL?
        var sandboxed: Bool
    }

    static func collect(scanSandboxed: Bool) -> Result {
        var entries = macOS() + BuiltInShortcuts.entries
        if let status = CFPreferencesCopyAppValue("NSServicesStatus" as CFString, "pbs" as CFString) as? [String: Any] {
            entries += ServicesShortcuts.entries(status)
        }
        if let global = CFPreferencesCopyAppValue("NSUserKeyEquivalents" as CFString, kCFPreferencesAnyApplication) as? [String: Any] {
            entries += MenuOverrides.entries(global, ownerID: ShortcutEntry.allAppsOwner, ownerName: "All apps")
        }
        var apps: [String: AppRecord] = [:]
        for (record, domain) in appDomains(scanSandboxed: scanSandboxed) {
            var found: [ShortcutEntry] = PrefsScanner.scan(domain).map { item in
                ShortcutEntry(id: "settings|\(record.bundleID)|\(item.path)", ownerID: record.bundleID, ownerName: record.name,
                              title: item.title, combo: item.combo, source: .appSettings,
                              detail: "Found in \(record.name)'s settings (\(item.path)). Change it in \(record.name)'s own settings.")
            }
            // One shortcut stored twice under one name (a list kept for two contexts) is one.
            var seenKeys: Set<String> = []
            found = found.filter { seenKeys.insert("\($0.combo.display)|\($0.title)").inserted }
            if let menus = domain["NSUserKeyEquivalents"] as? [String: Any] {
                found += MenuOverrides.entries(menus, ownerID: record.bundleID, ownerName: record.name)
            }
            guard !found.isEmpty else { continue }
            entries += found
            apps[record.bundleID] = record
        }
        return Result(entries: entries, apps: apps)
    }

    // MARK: - macOS

    nonisolated(unsafe) private static var cachedCatalog: [Int: SymbolicHotKeys.Definition]?

    static func macOS() -> [ShortcutEntry] {
        let catalog = cachedCatalog ?? SymbolicHotKeys.catalog()
        cachedCatalog = catalog
        let user = (CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any])
            .map(SymbolicHotKeys.userValues) ?? [:]
        return SymbolicHotKeys.entries(catalog: catalog, user: user, live: LiveHotKeys.values(for: Array(catalog.keys)))
    }

    // MARK: - Apps' settings

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Every installed app's settings, as (app, settings).
    private static func appDomains(scanSandboxed: Bool) -> [(AppRecord, [String: Any])] {
        var result: [(AppRecord, [String: Any])] = []
        var seen: Set<String> = []
        let own = Bundle.main.bundleIdentifier ?? "com.smanke.ShortcutsLens"
        let prefs = home.appending(path: "Library/Preferences")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: prefs.path)) ?? []
        for file in files where file.hasSuffix(".plist") {
            let id = String(file.dropLast(6))
            guard !skip(id, own: own), let record = app(for: id, sandboxed: false) else { continue }
            // Through cfprefsd, so values an app hasn't flushed to disk yet are included.
            guard let keys = CFPreferencesCopyKeyList(id as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
                  let domain = CFPreferencesCopyMultiple(keys, id as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
            else { continue }
            seen.insert(id)
            result.append((record, domain))
        }
        guard scanSandboxed else { return result }
        // Sandboxed apps keep their settings in their container. Reading it makes macOS ask
        // once whether ShortcutsLens may see other apps' data, so it's opt-in.
        let containers = home.appending(path: "Library/Containers")
        for id in (try? FileManager.default.contentsOfDirectory(atPath: containers.path)) ?? [] {
            guard !seen.contains(id), !skip(id, own: own), let record = app(for: id, sandboxed: true) else { continue }
            let file = containers.appending(path: "\(id)/Data/Library/Preferences/\(id).plist")
            guard let data = try? Data(contentsOf: file),
                  let domain = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            result.append((record, domain))
        }
        return result
    }

    private static func skip(_ id: String, own: String) -> Bool {
        id.hasPrefix("com.apple.") || id.hasPrefix(".") || id == own || id.hasPrefix("ShortcutsLensTest") || id.contains("/")
            || id == "pbs" || id.hasPrefix("loginwindow") || id.hasPrefix("ContextStoreAgent")
    }

    /// The installed app a settings domain belongs to, or nil (left-over settings of an app
    /// that's gone, helpers, frameworks).
    static func app(for bundleID: String, sandboxed: Bool) -> AppRecord? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        // Apps only: a Spotlight importer or helper tool registered under that id isn't one.
        guard url.pathExtension == "app" else { return nil }
        return AppRecord(bundleID: bundleID, name: displayName(url), url: url, sandboxed: sandboxed)
    }

    static func displayName(_ url: URL) -> String {
        let bundle = Bundle(url: url)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// The WindowServer's live values for macOS's shortcuts, read through SkyLight. They
/// include every default, which the settings file leaves out, and they're what macOS is
/// actually using right now. A private interface, so it's looked up at run time and
/// everything still works from the settings file if it ever goes away.
enum LiveHotKeys {
    private typealias GetValue = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias IsEnabled = @convention(c) (Int32) -> Bool

    nonisolated(unsafe) private static let functions: (GetValue, IsEnabled)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let get = dlsym(handle, "CGSGetSymbolicHotKeyValue"), let enabled = dlsym(handle, "CGSIsSymbolicHotKeyEnabled")
        else { return nil }
        return (unsafeBitCast(get, to: GetValue.self), unsafeBitCast(enabled, to: IsEnabled.self))
    }()

    static var isAvailable: Bool { functions != nil }

    static func values(for ids: [Int]) -> [Int: SymbolicHotKeys.Value] {
        guard let (get, isEnabled) = functions else { return [:] }
        var result: [Int: SymbolicHotKeys.Value] = [:]
        for id in ids {
            var character: UInt16 = 0, keyCode: UInt16 = 0, modifiers: UInt32 = 0
            guard get(Int32(id), &character, &keyCode, &modifiers) == 0 else { continue }
            let combo: KeyCombo? = keyCode == 0xFFFF
                ? (modifiers == 0 ? nil : KeyCombo(keyCode: nil, modifiers: Modifiers(cocoa: Int(modifiers))))
                : KeyCombo(keyCode: Int(keyCode), modifiers: Modifiers(cocoa: Int(modifiers)))
            result[id] = SymbolicHotKeys.Value(enabled: isEnabled(Int32(id)), combo: combo)
        }
        return result
    }
}

/// Letters and punctuation as the current keyboard layout types them.
enum KeyboardLayout {
    static func install() {
        let names = currentNames()
        KeyNames.layoutName = { names[$0] }
    }

    private static func currentNames() -> [Int: String] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var names: [Int: String] = [:]
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in KeyNames.ansi.keys {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                if status == noErr, length > 0 {
                    let s = String(utf16CodeUnits: chars, count: length)
                    if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { names[code] = s }
                }
            }
        }
        return names
    }
}

/// The menu shortcuts of a running app, read through Accessibility.
enum MenuReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        // kAXTrustedCheckOptionPrompt's value; the constant itself isn't concurrency-safe.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Every menu item with a shortcut, skipping the Apple menu (the same in every app).
    static func shortcuts(pid: pid_t, bundleID: String, appName: String) -> [ShortcutEntry] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return [] }
        var result: [ShortcutEntry] = []
        var budget = 3000
        let topItems: [AXUIElement] = attribute(bar, kAXChildrenAttribute) ?? []
        for top in topItems.dropFirst() {
            let title: String = attribute(top, kAXTitleAttribute) ?? ""
            for menu in (attribute(top, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                walk(menu, path: [title], depth: 0, budget: &budget, bundleID: bundleID, appName: appName, into: &result)
            }
        }
        return result
    }

    private static func walk(_ menu: AXUIElement, path: [String], depth: Int, budget: inout Int, bundleID: String, appName: String,
                             into result: inout [ShortcutEntry]) {
        guard depth < 4 else { return }
        for item in (attribute(menu, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            budget -= 1
            guard budget > 0 else { return }
            let title: String = attribute(item, kAXTitleAttribute) ?? ""
            if let submenus: [AXUIElement] = attribute(item, kAXChildrenAttribute), !submenus.isEmpty {
                for sub in submenus {
                    walk(sub, path: path + [title], depth: depth + 1, budget: &budget, bundleID: bundleID, appName: appName, into: &result)
                }
                continue
            }
            guard !title.isEmpty, let combo = combo(of: item) else { continue }
            let enabled: Bool = attribute(item, kAXEnabledAttribute) ?? true
            let menuPath = (path + [title]).joined(separator: " › ")
            result.append(ShortcutEntry(id: "menus|\(bundleID)|\(menuPath)", ownerID: bundleID, ownerName: appName, title: title,
                                        category: path.first, combo: combo, enabled: enabled, source: .appMenus,
                                        detail: "In \(appName)'s \(menuPath) menu. It works only while \(appName) is in front.",
                                        menuPath: menuPath))
        }
    }

    /// The item's shortcut from its key character, key code or glyph, and AX modifiers
    /// (bit 0 Shift, 1 Option, 2 Control, 3 "no Command").
    private static func combo(of item: AXUIElement) -> KeyCombo? {
        let char: String? = attribute(item, kAXMenuItemCmdCharAttribute)
        let virtualKey: Int? = attribute(item, kAXMenuItemCmdVirtualKeyAttribute)
        let glyph: Int? = attribute(item, kAXMenuItemCmdGlyphAttribute)
        let raw: Int = attribute(item, kAXMenuItemCmdModifiersAttribute) ?? 0
        var keyCode: Int?
        if let glyph, glyph != 0, let code = glyphKeys[glyph] {
            keyCode = code
        } else if let char, let ch = char.first, char.unicodeScalars.first?.value != 0 {
            keyCode = KeyNames.keyCode(for: ch) ?? virtualKey
        } else if let virtualKey, virtualKey != 0 || char != nil {
            keyCode = virtualKey
        }
        guard let keyCode else { return nil }
        var mods: Modifiers = []
        if raw & 1 != 0 { mods.insert(.shift) }
        if raw & 2 != 0 { mods.insert(.option) }
        if raw & 4 != 0 { mods.insert(.control) }
        if raw & 8 == 0 { mods.insert(.command) }
        if raw & 16 != 0 { mods.insert(.function) }
        return KeyCombo(keyCode: keyCode, modifiers: mods)
    }

    /// Menu glyphs (kMenu…Glyph) to key codes.
    private static let glyphKeys: [Int: Int] = [
        0x02: 48, 0x04: 76, 0x0B: 36, 0x0D: 36, 0x09: 49, 0x17: 51, 0x0A: 117, 0x1B: 53,
        0x64: 123, 0x65: 124, 0x68: 126, 0x6A: 125, 0x66: 115, 0x69: 119, 0x62: 116, 0x6B: 121, 0x67: 114,
        0x6F: 122, 0x70: 120, 0x71: 99, 0x72: 118, 0x73: 96, 0x74: 97, 0x75: 98, 0x76: 100, 0x77: 101, 0x78: 109,
        0x79: 103, 0x7A: 111, 0x87: 105, 0x88: 107, 0x89: 113,
    ]

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == Int.self, let number = value as? NSNumber { return number.intValue as? T }
        if T.self == Bool.self, let number = value as? NSNumber { return number.boolValue as? T }
        return value as? T
    }
}
