#if DEBUG
import AppKit
import ShortcutsLensKit
import SwiftUI

/// Test hooks, Debug builds only.
enum DebugHooks {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// A line in `SHORTCUTSLENS_DEBUG_TRACE`'s file (NSLog from a staged copy doesn't reach
    /// the unified log reliably).
    static func trace(_ line: String) {
        guard let path = env["SHORTCUTSLENS_DEBUG_TRACE"] else { return }
        let text = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// `SHORTCUTSLENS_DEBUG_DUMP=<file>` writes every shortcut found and the conflicts to a
    /// text file once the scan is done, then quits.
    /// `SHORTCUTSLENS_DEBUG_PICK_KEY=<key code>` clicks that key on the Keyboard Map; `_NO_INSPECTOR` closes the inspector.
    /// `SHORTCUTSLENS_DEBUG_SHOW=<all|conflicts|keyboard|free|frontmost|macOS|app:<id>|quickview|settings:<pane>|help[:<topic>]>`
    /// opens that page; with `SHORTCUTSLENS_DEBUG_SNAPSHOT=<png>` it draws the window to the
    /// file and quits.
    @MainActor
    static func run() -> Bool {
        if let file = env["SHORTCUTSLENS_DEBUG_DUMP"] {
            waitForScan { dump(to: file); QuitConfirmation.quitNow() }
            return true
        }
        guard let show = env["SHORTCUTSLENS_DEBUG_SHOW"] else { return false }
        waitForScan {
            var window: NSWindow?
            switch show {
            case "quickview":
                QuickView.shared.show()
                window = QuickView.shared.debugPanel
            case let s where s.hasPrefix("help"):
                HelpWindow.shared.show(topic: s.hasPrefix("help:") ? String(s.dropFirst(5)) : nil)
                window = NSApp.windows.first { $0.title.contains("Help") }
            case let s where s.hasPrefix("settings"):
                let pane = SettingsPane(rawValue: String(s.dropFirst("settings:".count))) ?? .general
                SettingsWindow.shared.show(pane)
                window = SettingsWindow.shared.debugWindow
            default:
                let page: Page = switch show {
                case "conflicts": .conflicts
                case "keyboard": .keyboard
                case "free": .free
                case "frontmost": .frontmost
                case "macOS": .macOS
                case let s where s.hasPrefix("app:"): .app(String(s.dropFirst(4)))
                default: .all
                }
                MainWindow.shared.show(page)
                if let select = env["SHORTCUTSLENS_DEBUG_SELECT"] {
                    MainWindow.shared.state.selection = ShortcutStore.shared.all.first { $0.id.contains(select) }?.id
                }
                if let key = env["SHORTCUTSLENS_DEBUG_PICK_KEY"].flatMap(Int.init) { MainWindow.shared.state.pickedKey = key }
                // `SHORTCUTSLENS_DEBUG_CHECK=⌃⇧C` types that into Check a Shortcut's key box.
                if let check = env["SHORTCUTSLENS_DEBUG_CHECK"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainWindow.shared.state.checkKey = check }
                }
                if env["SHORTCUTSLENS_DEBUG_NO_INSPECTOR"] != nil { MainWindow.shared.state.showInspector = false }
                window = MainWindow.shared.debugWindow
            }
            guard let png = env["SHORTCUTSLENS_DEBUG_SNAPSHOT"] else { return }
            // `SHORTCUTSLENS_DEBUG_SIZE=820x600`: the window at that content size, to check narrow layouts.
            // Set just before the shot, since a window manager may resize a new window after launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // Not the Quick View: hiding it closes it, and it would come back as a peek.
                if show != "quickview", let size = env["SHORTCUTSLENS_DEBUG_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                    // Off screen first: macOS 27 ignores a new frame for a window that's showing.
                    if let window {
                        window.orderOut(nil)
                        window.setContentSize(NSSize(width: size[0], height: size[1]))
                        window.center()
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                // A ".wid" file gets the window number, for `screencapture -l`, which draws
                // the sidebar's vibrancy that cacheDisplay leaves blank.
                if png.hasSuffix(".wid") {
                    try? "\(window?.windowNumber ?? 0)".write(toFile: png, atomically: true, encoding: .utf8)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { QuitConfirmation.quitNow() }
                    return
                }
                if let window { snapshot(window, to: png) }
                QuitConfirmation.quitNow()
            }
        }
        return true
    }

    @MainActor
    private static func waitForScan(_ then: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            while ShortcutStore.shared.lastScan == nil { try? await Task.sleep(for: .milliseconds(250)) }
            // A moment for apps' reports to arrive.
            try? await Task.sleep(for: .seconds(1.5))
            then()
        }
    }

    @MainActor
    private static func dump(to file: String) {
        let store = ShortcutStore.shared
        var lines = ["\(store.all.count) shortcuts, \(store.conflicts.count) conflicts, live values: \(LiveHotKeys.isAvailable)", ""]
        for entry in store.all {
            lines.append("\(entry.enabled ? " " : "-") \(entry.combo.display.padding(toLength: 12, withPad: " ", startingAt: 0)) \(entry.ownerName) | \(entry.category ?? "") | \(entry.title) [\(entry.source.rawValue)] \(entry.source == .appSettings ? (entry.id.components(separatedBy: "|").last ?? "") : "")")
        }
        lines.append("")
        lines.append("CONFLICTS")
        for (combo, list) in store.conflicts.sorted(by: { $0.key < $1.key }) {
            lines.append("\(combo.display): " + list.map { "\($0.ownerName): \($0.title)" }.joined(separator: " / "))
        }
        try? lines.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }

    @MainActor
    private static func snapshot(_ window: NSWindow, to file: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
    }

    /// `SHORTCUTSLENS_DEBUG_QUIT_TEST=<return|cancel|quit|suppress|off>` quits as ⌘Q does, then
    /// answers the question a second later: presses Return (then Cancel), clicks Cancel or
    /// Quit (ticking "Don't ask again" first for `suppress`), or with `off` turns the setting
    /// off first. What the question looked like goes to `debug.quitTest` in the defaults, and
    /// the activation policy after a Cancel to `debug.quitTestAfter`. Run it under a test
    /// bundle id with SHORTCUTSLENS_SYNC_FOLDER set: the defaults are the app's own, and the
    /// sync folder is a test one then.
    @MainActor
    static func runQuitTest() -> Bool {
        guard let how = ProcessInfo.processInfo.environment["SHORTCUTSLENS_DEBUG_QUIT_TEST"] else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if how == "off" { Preferences.shared.confirmQuit = false }
            note("debug.quitTest", "no question; policy \(NSApp.activationPolicy().rawValue); active before \(NSApp.isActive)")
            UserDefaults.standard.removeObject(forKey: "debug.quitTestAfter")
            answer(how, after: 1)
            NSApp.terminate(nil)
            // Still running: the question was cancelled. The old policy comes back a turn later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                note("debug.quitTestAfter", "still running; confirmQuit \(Preferences.shared.confirmQuit); policy \(NSApp.activationPolicy().rawValue)")
            }
        }
        return true
    }

    private static func note(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
        UserDefaults.standard.synchronize()
    }

    /// A timer in `.common` mode, since a plain scheduled one doesn't fire inside runModal.
    @MainActor
    private static func answer(_ how: String, after seconds: TimeInterval) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { answerQuit(how) }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    private static func answerQuit(_ how: String) {
        guard let window = NSApp.modalWindow else {
            if how == "cancel-after-return" { note("debug.quitTestReturn", "after Return: question gone") }
            return
        }
        var texts: [String] = []
        var buttons: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton { buttons.append(button) }
            else if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        func click(_ title: String) { buttons.first { $0.title == title }?.performClick(nil) }
        if how == "cancel-after-return" {
            note("debug.quitTestReturn", "after Return: question still up")
            return click("Cancel")
        }
        let titles = buttons.map { "\($0.title)[\($0.keyEquivalent == "\r" ? "Return" : $0.keyEquivalent == "\u{1b}" ? "Esc" : $0.keyEquivalent)]" }
        note("debug.quitTest", "asked \(texts) buttons \(titles) key \(window.isKeyWindow) active \(NSApp.isActive) visible \(window.isVisible) level \(window.level.rawValue) frontmost \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") policy \(NSApp.activationPolicy().rawValue)")
        switch how {
        case "return":
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                NSApp.postEvent(event, atStart: false)
            }
            // Return should leave the question up; note that, then cancel it.
            answer("cancel-after-return", after: 1)
        case "cancel": click("Cancel")
        case "quit", "suppress":
            if how == "suppress" { click("Don't ask again") }
            click("Quit")
        default: break
        }
    }
}
#endif
