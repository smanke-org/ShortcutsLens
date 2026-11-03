import AppKit
import ShortcutsLensKit
import SwiftUI

// `shortcutslens <command>` (the app binary under a short name): run it against the running
// app and exit, without starting a second copy. See Agent/AgentCLI.swift.
if let code = AgentCLI.runIfRequested() { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(AppPresence.showInDock && !AgentSocket.isTestRun ? .regular : .accessory)
app.run()

/// Quits ShortcutsLens without asking: for quitting itself (installing an update, ending a test).
@MainActor
enum QuitConfirmation {
    private(set) static var confirmed = false

    static func quitNow() {
        confirmed = true
        NSApp.terminate(nil)
    }
}

/// Launch, menus, the menu bar item, the Dock menu, and reopening.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    /// Links that arrive while ShortcutsLens is still launching; nil once launching is done.
    private var pendingURLs: [URL]? = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        #if DEBUG
        // A test run of the agent CLI (APP_STORE): its own settings, reports from the test
        // folder, and the agent socket. Nothing else starts: no sync, Quick View hotkey, menu
        // bar item, ToolHUD menu hub, report requests, or updater.
        if AgentSocket.isTestRun {
            ShortcutStore.shared.start()
            AgentSocket.listen { await AgentRouter.handle($0) }
            return
        }
        #endif
        AppAppearance.start()

        #if DEBUG
        // Before sync and the updater, so a test copy touches neither.
        if DebugHooks.runQuitTest() { return }
        if DebugUpdateNotes.run() { return }
        #endif

        // Set at the end of the first launch, so its absence means a brand-new install.
        let newInstall = !UserDefaults.standard.bool(forKey: "launchedBefore")
        if newInstall { SettingsSync.shared.adoptOnNewInstall() }
        SettingsSync.shared.start()

        ShortcutStore.shared.start()
        HotKeyCenter.shared.apply()

        setUpStatusItem()
        // ToolHUD can take the menu into its own while it runs.
        NotificationCenter.default.addObserver(forName: AppPresence.menuBarDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.statusItem?.isVisible = MenuHub.shared.showsOwnIcon }
        }
        MenuHub.shared.onChange = { SettingsSync.shared.localDidChange() }
        MenuHub.shared.start(menu: { [weak self] in
            let menu = NSMenu()
            self?.menuNeedsUpdate(menu)
            return menu
        }, icon: { [weak self] in self?.statusItem?.button?.image })

        #if DEBUG
        if DebugHooks.run() { return }
        #endif

        // `shortcutslens` and the MCP server talk to the app through this.
        AgentSocket.listen { await AgentRouter.handle($0) }

        AutoUpdater.shared.start()
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        // At login, ShortcutsLens starts quietly unless it has no icon to click. Launched by a
        // link, it does what the link asks and no more.
        let early = pendingURLs ?? []
        pendingURLs = nil
        if newInstall || (early.isEmpty && (!Self.launchedAsLoginItem || (!AppPresence.showInMenuBar && !AppPresence.showInDock))) {
            MainWindow.shared.show()
        }
        for url in early { run(url) }
    }

    /// Quitting asks first, while "Ask before quitting" is on in Settings › General. Not when
    /// the Mac is logging out, restarting or shutting down (macOS gives the quit a reason
    /// then), and not when ShortcutsLens quits itself to install an update.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        guard Preferences.shared.confirmQuit, !QuitConfirmation.confirmed, !systemQuit else { return .terminateNow }
        QuickView.shared.close()

        // Without a Dock icon ShortcutsLens needs to be a regular app for the alert to come to
        // the front; the old policy goes back a runloop turn later, once the alert is gone
        // (AppKit ignores it while the modal still holds the app active).
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { DispatchQueue.main.async { NSApp.setActivationPolicy(previousPolicy) } }

        let alert = NSAlert()
        alert.messageText = "Quit \(AppInfo.name)?"
        alert.informativeText = "The Quick View shortcut stops working until you open \(AppInfo.name) again."
        // NSAlert puts a Cancel button on Esc, and Quit has no key, so Return does nothing:
        // quitting takes a click on Quit, never a stray keystroke.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)

        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if alert.suppressionButton?.state == .on { Preferences.shared.confirmQuit = false }
        return .terminateNow
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("Open ShortcutsLens", #selector(showWindow)))
        menu.addItem(item("Quick View", #selector(showQuickView)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings)))
        return menu
    }

    /// Opening the app again (from Applications, Spotlight, or the Dock tile) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `shortcutslens://` links, for ToolHUD, Shortcuts and scripts.
    func application(_ application: NSApplication, open urls: [URL]) {
        if pendingURLs != nil {
            pendingURLs?.append(contentsOf: urls)
            return
        }
        for url in urls { run(url) }
    }

    private func run(_ url: URL) {
        guard url.scheme == "shortcutslens" else { return }
        switch url.host ?? "" {
        case "quickview", "hud": QuickView.shared.show()
        case "conflicts": MainWindow.shared.show(.conflicts)
        case "keyboard": MainWindow.shared.show(.keyboard)
        case "free": MainWindow.shared.show(.free)
        case "settings": SettingsWindow.shared.show()
        case "refresh": ShortcutStore.shared.refresh()
        default: MainWindow.shared.show()
        }
    }

    // MARK: - Menus

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("About ShortcutsLens", #selector(showAbout)))
        appMenu.addItem(item("Our other apps…", #selector(showOtherApps)))
        appMenu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ShortcutsLens", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ShortcutsLens", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f").tag =
            NSTextFinder.Action.showFindInterface.rawValue
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(item("All Shortcuts", #selector(showAll), key: "1"))
        view.addItem(item("Conflicts", #selector(showConflicts), key: "2"))
        view.addItem(item("Keyboard Map", #selector(showKeyboard), key: "3"))
        view.addItem(item("Find a Free Shortcut", #selector(showFree), key: "4"))
        view.addItem(item("App in Front", #selector(showFrontmost), key: "5"))
        view.addItem(.separator())
        view.addItem(item("Rescan", #selector(rescan), key: "r"))
        view.addItem(item("Show Turned-Off Shortcuts", #selector(toggleShowDisabled)))
        view.addItem(item("Only Conflicts", #selector(toggleOnlyConflicts)))
        view.addItem(item("Only Apps That Are Running", #selector(toggleOnlyRunning)))
        view.addItem(.separator())
        let sidebar = item("Hide Sidebar", #selector(toggleSidebar), key: "s")
        sidebar.keyEquivalentModifierMask = [.control, .command]
        view.addItem(sidebar)
        let inspector = item("Hide Inspector", #selector(toggleInspector), key: "i")
        inspector.keyEquivalentModifierMask = [.control, .command]
        view.addItem(inspector)
        view.addItem(.separator())
        view.addItem(item("Quick View", #selector(showQuickView)))
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("ShortcutsLens", #selector(showWindow), key: "0"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        main.addItem(windowItem)

        // Help menu, with the standard ⌘? (macOS adds its search field).
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(item("ShortcutsLens Help", #selector(showHelp), key: "?"))
        helpItem.submenu = help
        NSApp.helpMenu = help
        main.addItem(helpItem)
        return main
    }

    /// The status item's menu (also served to ToolHUD's menu hub).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = ShortcutStore.shared
        let quick = item("Quick View", #selector(showQuickView))
        if let combo = Preferences.shared.quickViewHotKey, let keyCode = combo.keyCode,
           let key = KeyNames.name(for: keyCode).lowercased().first, KeyNames.special[keyCode] == nil {
            quick.keyEquivalent = String(key)
            quick.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(combo.modifiers.cocoa))
        }
        menu.addItem(quick.showIcon("rectangle.on.rectangle"))
        menu.addItem(item("Open ShortcutsLens", #selector(showWindow)).showIcon("macwindow"))
        let conflicts = store.conflicts.count
        let conflictItem = item(conflicts == 0 ? "No Conflicts" : "\(conflicts) Conflict\(conflicts == 1 ? "" : "s")…", #selector(showConflicts))
        menu.addItem(conflictItem.showIcon(conflicts == 0 ? "checkmark.circle" : "exclamationmark.triangle"))
        menu.addItem(item("Keyboard Map", #selector(showKeyboard)))
        menu.addItem(item("Find a Free Shortcut", #selector(showFree)))
        menu.addItem(.separator())
        let helpEntry = item("ShortcutsLens Help", #selector(showHelp))
        helpEntry.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        menu.addItem(helpEntry)
        menu.addItem(item("Settings…", #selector(showSettings), key: ",").showIcon("gearshape"))
        menu.addItem(.separator())
        if let staged = AutoUpdater.shared.staged {
            menu.addItem(item("Update to \(staged.version) Now (Otherwise Installs When Idle)", #selector(installUpdateNow)).showIcon("arrow.down.circle"))
        } else if let pending = UpdateAvailability.shared.pending {
            menu.addItem(item("Update to \(pending)…", #selector(checkForUpdates)).showIcon("arrow.down.circle"))
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)).showIcon("arrow.down.circle"))
        }
        menu.addItem(item("About ShortcutsLens", #selector(showAbout)))
        menu.addItem(item("Our other apps…", #selector(showOtherApps)))
        menu.addItem(.separator())
        let version = NSMenuItem(title: "ShortcutsLens \(AppInfo.displayVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item("Quit ShortcutsLens", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "command.square", accessibilityDescription: "ShortcutsLens")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = MenuHub.shared.showsOwnIcon
        statusItem = item
    }

    // MARK: - Actions

    @objc func showWindow() { MainWindow.shared.show() }
    @objc func showAll() { MainWindow.shared.show(.all) }
    @objc func showConflicts() { MainWindow.shared.show(.conflicts) }
    @objc func showKeyboard() { MainWindow.shared.show(.keyboard) }
    @objc func showFree() { MainWindow.shared.show(.free) }
    @objc func showFrontmost() { MainWindow.shared.show(.frontmost) }
    @objc func showQuickView() { QuickView.shared.show() }
    @objc func rescan() { MainWindow.shared.rescan() }
    @objc func toggleShowDisabled() { Preferences.shared.showDisabled.toggle() }
    @objc func toggleOnlyConflicts() { MainWindow.shared.state.onlyConflicts.toggle(); MainWindow.shared.show() }
    @objc func toggleOnlyRunning() { MainWindow.shared.state.onlyRunning.toggle(); MainWindow.shared.show() }
    @objc func toggleSidebar() { MainWindow.shared.toggleSidebar() }
    @objc func toggleInspector() { MainWindow.shared.toggleInspector() }

    /// Check marks and Show/Hide titles that follow the window's state.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let state = MainWindow.shared.state
        switch menuItem.action {
        case #selector(toggleShowDisabled): menuItem.state = Preferences.shared.showDisabled ? .on : .off
        case #selector(toggleOnlyConflicts): menuItem.state = state.onlyConflicts ? .on : .off
        case #selector(toggleOnlyRunning): menuItem.state = state.onlyRunning ? .on : .off
        case #selector(toggleSidebar):
            menuItem.title = state.sidebarShown ? "Hide Sidebar" : "Show Sidebar"
            return MainWindow.shared.isVisible
        case #selector(toggleInspector):
            menuItem.title = state.showInspector ? "Hide Inspector" : "Show Inspector"
            return MainWindow.shared.isVisible
        default: break
        }
        return true
    }
    @objc func showSettings() { SettingsWindow.shared.show() }
    @objc func showHelp() { HelpWindow.shared.show() }
    @objc func checkForUpdates() { UpdateController.checkForUpdates() }
    @objc func installUpdateNow() { AutoUpdater.shared.installNow() }
    @objc func quit() { NSApp.terminate(nil) }

    /// The developer's site, which lists every app.
    @objc func showOtherApps() {
        if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
    }

    @objc func showAbout() {
        AppInfo.showAbout()
    }
}
