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
        // `SHORTCUTSLENS_DEBUG_CHANGE=<entry id>=<keys>` changes that shortcut, traces what it
        // reads back, then with `_UNDO` undoes it, and quits.
        if let change = env["SHORTCUTSLENS_DEBUG_CHANGE"] {
            waitForScan {
                Task { @MainActor in
                    await debugChange(change)
                    QuitConfirmation.quitNow()
                }
            }
            return true
        }
        // `SHORTCUTSLENS_DEBUG_EDITOR=<folder>` opens the Quick View shortcut's editor in Settings,
        // runs it through typed keys, pressed keys, Set, Clear and Esc, draws each step to
        // <folder>/editor-<step>.png, writes <folder>/editor.txt, and quits.
        if let folder = env["SHORTCUTSLENS_DEBUG_EDITOR"] {
            waitForScan { Task { @MainActor in await editorTest(folder); QuitConfirmation.quitNow() } }
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
    private static func debugChange(_ spec: String) async {
        guard let split = spec.range(of: "=", options: .backwards) else { trace("bad CHANGE spec"); return }
        let id = String(spec[..<split.lowerBound]), keys = String(spec[split.upperBound...])
        // A report may still be on its way.
        for _ in 0..<20 where !ShortcutStore.shared.all.contains(where: { $0.id == id }) { try? await Task.sleep(for: .milliseconds(250)) }
        guard let entry = ShortcutStore.shared.all.first(where: { $0.id == id }),
              let combo = KeyEquivalentParser.parseReadable(keys) ?? KeyEquivalentParser.parseKeyEquivalent(keys) else {
            trace("no entry \(id) or bad keys \(keys)"); return
        }
        trace("before \(entry.combo.display) changeable=\(ShortcutChanger.shared.canChange(entry))")
        do {
            try await ShortcutChanger.shared.change(entry, to: combo)
            trace("changed to \(combo.display)")
            try? await Task.sleep(for: .seconds(2))
            trace("rescanned: \(ShortcutStore.shared.all.first { $0.id == id }?.combo.display ?? "gone")")
            if env["SHORTCUTSLENS_DEBUG_UNDO"] != nil, let now = ShortcutStore.shared.all.first(where: { $0.id == id }) {
                try await ShortcutChanger.shared.undo(now)
                try? await Task.sleep(for: .seconds(2))
                trace("undone: \(ShortcutStore.shared.all.first { $0.id == id }?.combo.display ?? "gone")")
            }
        } catch {
            trace("failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func editorTest(_ folder: String) async {
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { lines.append("\(ok ? "PASS" : "FAIL") \(name) \(detail)") }
        func pause() async { try? await Task.sleep(for: .milliseconds(400)) }
        func draw(_ button: ShortcutRecorder.RecorderButton, _ step: String) {
            guard let view = button.debugPopoverView, let frame = view.window?.contentView?.superview ?? view.window?.contentView,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { lines.append("no popover for \(step)"); return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/editor-\(step).png"))
        }
        func key(_ code: Int, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))!
        }
        let prefs = Preferences.shared
        let start = prefs.quickViewHotKey
        lines.append("start \(start?.display ?? "none")")
        SettingsWindow.shared.show(.quickView)
        await pause()
        func find(_ view: NSView?) -> ShortcutRecorder.RecorderButton? {
            guard let view else { return nil }
            if let button = view as? ShortcutRecorder.RecorderButton { return button }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        guard let button = find(SettingsWindow.shared.debugWindow?.contentView) else {
            lines.append("FAIL no recorder button")
            try? lines.joined(separator: "\n").write(toFile: "\(folder)/editor.txt", atomically: true, encoding: .utf8)
            return
        }
        button.open()
        await pause()
        guard let model = button.debugModel else { lines.append("FAIL no editor"); return }
        check("opens with the current keys", model.combo == start, model.combo?.display ?? "nil")
        check("hotkey paused while open", HotKeyCenter.shared.debugPaused)
        check("button says Set a shortcut…", button.debugTitle == "Set a shortcut…", button.debugTitle)
        draw(button, "1-open")

        // "+" is ⇧ and the = key.
        model.modifiers = [.control, .option]
        model.key = "+"
        await pause()
        check("+ becomes ⇧=", model.combo == KeyCombo(keyCode: 24, modifiers: [.control, .option, .shift]) && model.key == "=",
              "\(model.combo?.display ?? "nil") key \(model.key)")
        draw(button, "2-plus")

        // A letter typed after a key replaces it.
        model.key = "=a"
        await pause()
        check("typed letter replaces the key", model.key == "A" || model.key == "a", model.key)
        model.key = "K"
        await pause()
        model.key = "K="
        await pause()
        check("typed = replaces K", model.key == "=" && model.combo?.keyCode == 24, "\(model.key) \(model.combo?.display ?? "nil")")
        model.key = "=k"
        await pause()
        check("typed k replaces =", model.combo?.keyCode == 40, "\(model.key) \(model.combo?.display ?? "nil")")

        // A bare letter (⇧ only) is refused.
        model.modifiers = [.shift]
        model.key = "K"
        await pause()
        check("bare letter refused", !model.canSet && model.problem != nil, model.problem ?? "no problem")
        draw(button, "3-bare")

        // F5 alone is fine.
        model.modifiers = []
        model.key = "F5"
        await pause()
        check("F-key alone allowed", model.canSet && model.combo == KeyCombo(keyCode: 96, modifiers: []), model.combo?.display ?? "nil")
        draw(button, "4-fkey")

        // Every key in the keyboard menu comes back as itself, with a printable name.
        var wrong: [String] = []
        for code in ComboPicker.specialKeys + KeyNames.functionKeys {
            let name = ComboPicker.specialKeys.contains(code) ? KeyNames.spokenName(for: code) : KeyNames.name(for: code)
            model.modifiers = [.control, .option]
            model.key = name
            await pause()
            let glyph = KeyNames.name(for: code)
            if model.combo?.keyCode != code || model.key != name || glyph.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
                wrong.append("\(code) \(name) -> \(model.key) \(model.combo?.display ?? "nil")")
            }
        }
        check("menu keys keep their names", wrong.isEmpty, wrong.joined(separator: "; "))
        lines.append("menu glyphs: " + (ComboPicker.specialKeys + KeyNames.functionKeys).map { KeyNames.name(for: $0) }.joined(separator: " "))

        // Pressing a shortcut fills everything in.
        let used = model.handle(key(40, [.control, .option, .command]))
        await pause()
        check("pressed ⌃⌥⌘K fills in", used && model.combo == KeyCombo(keyCode: 40, modifiers: [.control, .option, .command]),
              model.combo?.display ?? "nil")
        draw(button, "5-pressed")
        let plain = model.handle(key(0, []))
        check("plain letter goes to the key box", !plain)
        let fkey = model.handle(key(97, []))
        await pause()
        check("pressed F6 alone fills in", fkey && model.combo == KeyCombo(keyCode: 97, modifiers: []), model.combo?.display ?? "nil")

        // Return sets it.
        _ = model.handle(key(36, []))
        await pause()
        check("Return sets F6", prefs.quickViewHotKey == KeyCombo(keyCode: 97, modifiers: []), prefs.quickViewHotKey?.display ?? "nil")
        check("popover closed, hotkey resumed", button.debugModel == nil && !HotKeyCenter.shared.debugPaused)
        check("F6 registered", !HotKeyCenter.shared.registrationFailed)
        check("button shows F6", button.debugTitle == "F6", button.debugTitle)

        // Esc cancels.
        button.open()
        await pause()
        button.debugModel?.press(40, [.control, .shift])
        await pause()
        check("⌃⇧K allowed", button.debugModel?.canSet == true)
        _ = button.debugModel?.handle(key(53, []))
        await pause()
        lines.append("after Esc: model \(button.debugModel == nil ? "gone" : "still there"), popover shown \(button.debugPopoverView?.window?.isVisible ?? false)")
        try? await Task.sleep(for: .seconds(1))
        check("Esc cancels", prefs.quickViewHotKey == KeyCombo(keyCode: 97, modifiers: []) && button.debugModel == nil,
              prefs.quickViewHotKey?.display ?? "nil")

        // Clear turns it off.
        button.open()
        await pause()
        draw(button, "6-before-clear")
        button.debugModel?.finish?(.set(nil))
        await pause()
        check("Clear turns it off", prefs.quickViewHotKey == nil && button.debugTitle == "Click to set", button.debugTitle)
        button.open()
        await pause()
        check("Clear is off with no shortcut", button.debugModel?.original == nil)
        draw(button, "7-empty")
        button.debugModel?.finish?(.cancel)
        await pause()

        prefs.quickViewHotKey = start
        lines.append("restored \(prefs.quickViewHotKey?.display ?? "none")")
        try? lines.joined(separator: "\n").write(toFile: "\(folder)/editor.txt", atomically: true, encoding: .utf8)
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
