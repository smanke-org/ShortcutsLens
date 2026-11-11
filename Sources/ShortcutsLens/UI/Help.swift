import AppKit
import ShortcutsLensKit
import SwiftUI

// MARK: - Content

/// One page of Help. `{hotkey:quickview}` shows the user's own Quick View shortcut,
/// so the text matches their settings.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    static func resolve(_ text: String) -> String {
        guard text.contains("{") else { return text }
        return text.replacingOccurrences(of: "{hotkey:quickview}",
                                         with: Preferences.shared.quickViewHotKey?.display ?? "(no shortcut set)")
    }

    /// The topic each Settings pane's Help button opens.
    static func topic(for pane: SettingsPane) -> String {
        switch pane {
        case .general: "getting-started"
        case .quickView: "quick-view"
        case .sources: "sources"
        case .sync, .updates: "sync"
        }
    }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("ShortcutsLens lists the keyboard shortcuts that work everywhere on your Mac: macOS's own, Services, and the global shortcuts apps register, each with the name of the app it belongs to. It points out shortcuts that collide, shows which keys are free, and puts a cheat sheet for the app you're using one keystroke away."),
            .heading("Where to find it"),
            .keys([
                ("{hotkey:quickview}", "Open the Quick View over any app"),
                ("Menu bar icon", "The ShortcutsLens menu"),
                ("Dock icon", "Opens the window"),
                ("⌘0", "Bring the ShortcutsLens window back"),
                ("⌘1 to ⌘5", "All Shortcuts, Conflicts, Keyboard Map, Find a Free Shortcut, App in Front"),
                ("⌘R", "Look for shortcuts again"),
                ("⌘F", "Search the list"),
                ("⌘C", "Copy the selected shortcut"),
                ("⌃⌘S", "Show or hide the sidebar"),
                ("⌃⌘I", "Show or hide the inspector"),
                ("⌘,", "Settings"),
                ("⌘?", "This Help"),
            ]),
            .heading("The window"),
            .text("The sidebar has All Shortcuts, Conflicts, the Keyboard Map, Find a Free Shortcut, App in Front, macOS, Services and App Shortcuts, then every app ShortcutsLens found shortcuts for. Each shortcut shows its name on the left and its keys on the right, the way menus do."),
            .text("Click a shortcut to see it in the inspector on the right: where it came from, whether it's on, whether its app is running and what it collides with. The button at the top right, or ⌃⌘I, shows and hides the inspector."),
            .text("The Filter button in the toolbar (also in the View menu) chooses what the lists show: turned-off shortcuts, only conflicts, or only apps that are running. The line under the page title says what's filtered."),
            .text("Search matches names, apps and keys. Type the symbols in any order: ⌘⇧4 finds ⇧⌘4."),
            .text("Right-click a shortcut to copy it, copy every shortcut shown, or hide it. Right-click an app in the sidebar to hide everything from it."),
            .heading("The menu bar menu"),
            .text("The menu opens the Quick View, the window, the Conflicts page (it says how many there are), the Keyboard Map and Find a Free Shortcut, plus Help, Settings, updates and the version you're running."),
            .heading("What the marks mean"),
            .keys([
                ("⚠︎", "Another shortcut uses the same keys"),
                ("Off", "Turned off, so it does nothing"),
                ("☾ (in the sidebar)", "The app isn't running, so its shortcut waits until it opens"),
                ("🔍", "Found in the app's settings file rather than reported by the app"),
            ]),
            .tip("While ToolHUD is running, ShortcutsLens's menu moves into ToolHUD's menu bar menu as a submenu, and the icon here steps aside until ToolHUD quits. To keep the icon, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings › General."),
            .tip("Quitting asks first, since the Quick View shortcut stops while ShortcutsLens is closed. Turn off \"Ask before quitting\" in Settings › General, or tick \"Don't ask again\" when it asks."),
        ]),

        HelpTopic(id: "sources", title: "Where Shortcuts Come From", symbol: "tray.full", blocks: [
            .text("macOS keeps no single list of every shortcut, so ShortcutsLens gathers them from several places:"),
            .keys([
                ("macOS", "The shortcuts in System Settings › Keyboard › Keyboard Shortcuts, named and grouped as there, with the values macOS is using right now"),
                ("Built in", "Fixed ones Keyboard settings doesn't list, such as Force Quit, Lock Screen and the 🌐 key's shortcuts"),
                ("Services", "Services menu items you've given a shortcut"),
                ("App Shortcuts", "Menu items you've given new keys in Keyboard settings; these work only while their app is in front"),
                ("Apps' settings", "Global shortcuts apps save in their settings files, found by recognizing how the common shortcut libraries store them"),
                ("Reported", "Apps that tell ShortcutsLens their shortcuts directly while they run, which is exact"),
            ]),
            .heading("What it can't see"),
            .text("An app that keeps its shortcuts in its own database, or registers fixed ones in code, leaves nothing to read, and macOS doesn't tell one app which keys another has registered. Those shortcuts won't be listed. That's why a free shortcut here is a very good sign, not a promise."),
            .text("A few apps, Snagit among them, never write their default shortcut down until you change it. ShortcutsLens knows those defaults and lists them, marked with a question mark, while it finds nothing else for the app. If you've changed one in the app, hide it."),
            .text("App Store apps keep their settings in a sandbox. Turn on \"Also look in sandboxed apps\" in Settings › Sources to include them; macOS asks once whether ShortcutsLens may see other apps' data."),
            .heading("Keeping up"),
            .text("ShortcutsLens looks again when you come back to it, when an app with shortcuts opens, and when you press ⌘R. Settings › Sources shows the last look, has a Rescan button, and lists the shortcuts and apps you've hidden, each with Show to bring it back."),
            .text("Turned-off shortcuts are listed and marked Off. To leave them out, turn off Show Turned-Off Shortcuts in the Filter menu, the View menu, or Settings › Sources (all three are the same setting)."),
            .tip("A shortcut found in a settings file can occasionally be one that only works inside the app, such as a key in its Open dialog. Right-click it and choose Hide This Shortcut, or hide everything from an app by right-clicking it in the sidebar."),
        ]),

        HelpTopic(id: "conflicts", title: "Conflicts", symbol: "exclamationmark.triangle", blocks: [
            .text("Two shortcuts conflict when both are on and use the same keys everywhere. Only one of them gets the keys, usually whichever app registered them first, so the other one silently does nothing."),
            .text("The Conflicts page shows one card for each set of keys, with every shortcut that wants them. Click a shortcut to change it from the inspector (see Changing a Shortcut), or use the button that leads to where it's changed: Keyboard settings for macOS's own, the app itself for an app's. Click a shortcut for its details in the inspector. The Quick View has a Conflicts tab too."),
            .tip("Turned-off shortcuts and menu shortcuts that only work inside one app don't count as conflicts. Neither do two of one app's own shortcuts on the same keys used in different ways, such as holding a key and double-tapping it, when the app reports them."),
        ]),

        HelpTopic(id: "change", title: "Changing a Shortcut", symbol: "pencil", blocks: [
            .text("Select a shortcut and click Change Shortcut… in the inspector. Choose the modifier buttons and type the key, as on Find a Free Shortcut. The sheet says right away what else uses the new keys; you can still save them with Change Anyway."),
            .text("ShortcutsLens can change three kinds of shortcuts:"),
            .keys([
                ("macOS's own", "Saved where System Settings saves them; they work right away."),
                ("App Shortcuts", "Menu shortcuts from System Settings › Keyboard › Keyboard Shortcuts › App Shortcuts. The app uses the new keys the next time it opens."),
                ("Apps that accept changes", "Apps that report their shortcuts to ShortcutsLens and take new keys. The app saves them in its own settings, so its Settings window shows them too. It has to be running."),
            ]),
            .text("Other apps' shortcuts can't be changed here. Each app stores them its own way, and a running app would overwrite a change, so ShortcutsLens never writes their settings. Use Open in the inspector to go to the app instead."),
            .tip("After a change, the inspector shows the keys it had before with an Undo button, which puts the original keys back even after several changes. Changes are remembered on this Mac only."),
        ]),

        HelpTopic(id: "keyboard", title: "Keyboard Map and Free Shortcuts", symbol: "keyboard.badge.ellipsis", blocks: [
            .text("The Keyboard Map draws your keyboard, as wide as the window, for the modifiers you choose at the top. Keys with a system-wide shortcut are lit, conflicts are orange, and free keys are plain; a number in a key's corner says how many shortcuts it holds. Hover over a key to see what uses it, or click it to list everything on that key, with any modifiers, in the inspector."),
            .text("Turn on \"Include … menus\" to light the menu shortcuts of the app you were using as well."),
            .heading("Find a Free Shortcut"),
            .text("To check a shortcut you have in mind, click its modifier buttons at the top (⌃ Control, ⌥ Option, ⇧ Shift, ⌘ Command, fn) and type the key in the Key box: a letter, number or symbol, or a name like F5, Space, Return or Left (the keyboard menu lists them). You can also paste a whole shortcut such as ⌃⇧C or ctrl+shift+c. ShortcutsLens says right away whether anything uses it and which app, and the inspector shows the details. You choose the keys rather than pressing them because a shortcut another app holds never reaches ShortcutsLens when you press it. Below are free shortcuts for the modifier sets least likely to collide with app menus. Click one to copy it; it says Copied for a moment."),
            .tip("Shortcuts with three or four modifiers, such as ⌃⌥⌘, almost never appear in app menus, which makes them good choices for global shortcuts."),
        ]),

        HelpTopic(id: "quick-view", title: "Quick View", symbol: "rectangle.on.rectangle", blocks: [
            .text("The Quick View floats over the app you're using with its menu shortcuts, every system-wide shortcut and the conflicts, in columns you can take in at a glance."),
            .keys([
                ("{hotkey:quickview}", "Open the Quick View, ready to search; press it again to close"),
                ("Esc", "Close it and go back to your app"),
                ("⌘1, ⌘2, ⌘3", "Switch to the app in front, System-wide, or Conflicts"),
                ("Hold ⌘", "Show it until you let go, when turned on in Settings › Quick View (needs Accessibility permission)"),
            ]),
            .text("Settings › Quick View changes the shortcut (click it, press new keys, or press Delete to clear it), turns on holding ⌘, and chooses whether it opens on the app in front or on system-wide shortcuts. If another app already holds the keys you pick, it says so in red."),
            .text("Shortcuts that collide are orange, with a warning sign. The line along the bottom repeats the keys that work in the Quick View."),
            .tip("Holding ⌘ waits a second, so ordinary ⌘ shortcuts never bring it up."),
        ]),

        HelpTopic(id: "app-menus", title: "The App in Front", symbol: "macwindow", blocks: [
            .text("With Accessibility permission, ShortcutsLens reads the menus of the app you were using and lists every item that has a shortcut, with where it sits in the menus. It only reads names and keys, and never changes or clicks anything."),
            .text("The sidebar's app row and the Quick View's first tab always show the last app you used before ShortcutsLens."),
            .tip("Allow Accessibility in Settings › General › Permission, or in System Settings › Privacy & Security › Accessibility. Everything else in ShortcutsLens works without it."),
        ]),

        HelpTopic(id: "sync", title: "Sync and Updates", symbol: "icloud", blocks: [
            .text("Turn on sync in Settings › Sync to keep the Quick View shortcut, options, hidden shortcuts and apps, appearance and update choice the same on every Mac signed in to your iCloud account. Open at login stays per Mac."),
            .text("Settings › Updates chooses whether new versions install by themselves, ask first, or wait for Check Now, and how often to check: once a day, or on a schedule you set, from every hour to once a year. An automatic update waits until the Quick View is closed and the Mac has been idle for two minutes. What's New… shows the notes for recent versions, and About ShortcutsLens shows the last 10 releases."),
        ]),

        HelpTopic(id: "links", title: "Links, ToolHUD and the Command Line", symbol: "link", blocks: [
            .text("ToolHUD buttons, Shortcuts and scripts can open ShortcutsLens pages with links:"),
            .keys([
                ("shortcutslens://open", "The window"),
                ("shortcutslens://quickview", "The Quick View"),
                ("shortcutslens://conflicts", "The Conflicts page"),
                ("shortcutslens://keyboard", "The Keyboard Map"),
                ("shortcutslens://free", "Find a Free Shortcut"),
                ("shortcutslens://settings", "Settings"),
            ]),
            .heading("Command line and AI agents"),
            .text("ShortcutsLens is also a command line tool, so scripts and AI agents such as Claude Code or Codex can search your shortcuts by app, keys or source, list the conflicts, check whether a key combination is free, suggest free ones, and hide shortcuts from the lists. Commands run in the open app, so the answers match what the window shows."),
            .keys([
                ("shortcutslens help", "List every command and its options"),
                ("shortcutslens shortcuts list --search screenshot", "Find shortcuts, as the window's search does"),
                ("shortcutslens keys check \"ctrl+opt+cmd+k\"", "Is it free? Everything that uses those keys"),
                ("shortcutslens conflicts list", "Keys that two or more shortcuts claim"),
                ("shortcutslens mcp", "Offer the same commands to MCP apps, such as Claude Desktop"),
            ]),
            .text("To type shortcutslens in Terminal, link it once: ln -s /Applications/ShortcutsLens.app/Contents/MacOS/ShortcutsLens ~/.local/bin/shortcutslens (with ~/.local/bin on your PATH). MCP apps take the full path to that program, followed by mcp."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("An app's shortcut is missing"),
            .text("The app may keep its shortcuts where ShortcutsLens can't read them, or it may be an App Store app: turn on \"Also look in sandboxed apps\" in Settings › Sources. Check Settings › Sources › Hidden too."),
            .heading("A shortcut is listed but the app says something else"),
            .text("Press ⌘R to look again. Some apps save a changed shortcut only when they quit."),
            .heading("The Quick View shortcut does nothing"),
            .text("Another app may hold the same keys. Settings › Quick View shows a warning; record a different shortcut."),
            .heading("The app's menus page is empty"),
            .text("Allow Accessibility in Settings › General. Some apps build their menus only when you open them, so a few items may not show until you've used them once."),
            .heading("Starting over"),
            .text("Settings › General › Reset to Defaults puts the options back and shows every hidden shortcut and app again."),
        ]),
    ] }
}


// MARK: - Window

@Observable
@MainActor
final class HelpState {
    var selection: String? = "getting-started"
    var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppInfo.name) Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 820, height: min(600, screen - 80)))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ShortcutsLensHelp")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @Bindable var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) {
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "\(AppInfo.name) Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}
