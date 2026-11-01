import AppKit
import Carbon.HIToolbox
import Observation
import ShortcutsLensKit

/// The Quick View's triggers: its shortcut, through Carbon's RegisterEventHotKey (no
/// permission needed), and optionally holding ⌘ on its own, which needs Accessibility to
/// see keys pressed in other apps.
@Observable
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// The shortcut couldn't be registered, almost always because another app holds it.
    private(set) var registrationFailed = false

    @ObservationIgnored private var ref: EventHotKeyRef?
    @ObservationIgnored private var installed = false
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var holdTimer: Timer?
    @ObservationIgnored private var peeking = false

    /// How long ⌘ has to be held alone.
    static let holdDelay: TimeInterval = 1.0

    func apply() {
        installHandlerOnce()
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registrationFailed = false
        if !paused, let combo = Preferences.shared.quickViewHotKey, let keyCode = combo.keyCode {
            var newRef: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x534C_4E53), id: 1) // "SLNS"
            let status = RegisterEventHotKey(UInt32(keyCode), UInt32(combo.modifiers.carbon), id, GetApplicationEventTarget(), 0, &newRef)
            #if DEBUG
            DebugHooks.trace("register \(combo.display) status \(status)")
            #endif
            if status == noErr {
                ref = newRef
            } else {
                registrationFailed = true
                NSLog("ShortcutsLens: Quick View shortcut \(combo.display) not registered, probably taken by another app")
            }
        }
        applyHoldMonitor()
    }

    /// While a shortcut is being recorded, the current one must not fire.
    func pause() { paused = true; apply() }
    func resume() { paused = false; apply() }

    private func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }

    fileprivate func fired() {
        #if DEBUG
        DebugHooks.trace("hotkey fired; Quick View shown \(QuickView.shared.isShown)")
        #endif
        QuickView.shared.toggle()
    }

    // MARK: - Holding ⌘

    var holdNeedsAccess: Bool { Preferences.shared.holdCommand && !MenuReader.isTrusted }

    private func applyHoldMonitor() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        holdTimer?.invalidate()
        guard Preferences.shared.holdCommand, !paused else { return }
        // Other apps' keys arrive only with Accessibility; ShortcutsLens's own always do.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel],
                                                          handler: { event in
                                                              let type = event.type, flags = event.modifierFlags
                                                              MainActor.assumeIsolated { HotKeyCenter.shared.handle(type, flags) }
                                                          }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in
            let type = event.type, flags = event.modifierFlags
            MainActor.assumeIsolated { HotKeyCenter.shared.handle(type, flags) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags) {
        let mods = flags.intersection([.command, .option, .control, .shift, .function])
        if type == .flagsChanged && mods == .command {
            // ⌘ alone went down: wait to see if it's held.
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let center = HotKeyCenter.shared
                    guard NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else { return }
                    center.peeking = true
                    QuickView.shared.peek()
                }
            }
            return
        }
        // Anything else, a key, a click, another modifier or letting go, is a shortcut being
        // typed or the end of the hold.
        holdTimer?.invalidate()
        holdTimer = nil
        if peeking {
            peeking = false
            QuickView.shared.endPeek()
        }
    }
}

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    MainActor.assumeIsolated { HotKeyCenter.shared.fired() }
    return noErr
}
