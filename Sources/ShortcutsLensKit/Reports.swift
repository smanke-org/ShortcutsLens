import Foundation

/// What apps tell ShortcutsLens about their own hotkeys.
///
/// ShortcutsLens asks with a distributed notification; each app that adopts the protocol
/// (Shared/ShortcutsLensReport.swift) answers with its hotkeys, and answers again by itself
/// when one changes. A report is exact, so it replaces whatever the settings scan guessed
/// for that app.
public enum ShortcutReports {
    public static let request = "com.smanke.ShortcutsLens.request"
    public static let report = "com.smanke.ShortcutsLens.report"

    /// Turns a report's userInfo into entries. `sender` is the notification's object, the
    /// app's bundle id.
    public static func entries(sender: String, userInfo: [AnyHashable: Any]) -> [ShortcutEntry]? {
        guard let list = userInfo["shortcuts"] as? [[String: Any]] else { return nil }
        let appName = userInfo["app"] as? String ?? sender
        return list.compactMap { item in
            guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
            let keyCode = item["keyCode"] as? Int
            let modifiers = (item["carbonModifiers"] as? Int).map(Modifiers.init(carbon:))
                ?? (item["cocoaModifiers"] as? Int).map(Modifiers.init(cocoa:)) ?? []
            guard keyCode != nil || !modifiers.isEmpty else { return nil }
            // "press" (or nothing) is the ordinary case.
            let gesture = (item["gesture"] as? String).flatMap { $0.isEmpty || $0 == "press" ? nil : $0 }
            return ShortcutEntry(id: "report|\(sender)|\(id)", ownerID: sender, ownerName: appName, title: title,
                                 category: item["category"] as? String, combo: KeyCombo(keyCode: keyCode, modifiers: modifiers),
                                 enabled: item["enabled"] as? Bool ?? true, source: .appReport,
                                 detail: "\(appName) reported this shortcut itself. Change it in \(appName)'s settings.",
                                 gesture: gesture)
        }
    }
}
