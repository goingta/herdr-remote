import Foundation

/// One row of the desktop widget's agent list. Written by the menu-bar app into the
/// shared container, read by the widget extension — no other transport exists between
/// the two processes, and the widget cannot SSH or open a socket itself.
///
/// Both targets compile this file; the fields are the stable string contract across
/// that boundary, so keep them Codable-stable.
struct WidgetAgent: Codable, Hashable {
    // The app's normalized Agent.id (local bare pane id, remote "host:pane") —
    // what the deep link hands back to the app for focusing. Snapshots cached by
    // older builds lack it (nil): rows then render without a tap target.
    var id: String?
    var agent: String
    var project: String
    var status: String
    // herdr's stripped terminal title — the live task name.
    var session: String?

    /// Sort rank: the neediest first, matching the herd list's ordering idea.
    var rank: Int {
        switch status {
        case "blocked": return 0
        case "working": return 1
        case "done": return 2
        default: return 3
        }
    }

    /// The row's display title: 【项目名 · Session Title】, bare project when the
    /// session title is just the harness banner ("Claude Code") or empty — repeating
    /// the agent column as a title wastes the row. Shared by the widget and the
    /// notch panel so the two cannot drift apart about what a row is called.
    var displayTitle: String {
        WidgetAgent.displayTitle(project: project, agent: agent, session: session)
    }

    /// Static form for callers holding the app's own `Agent` model instead of a
    /// `WidgetAgent` — same rule, single implementation.
    static func displayTitle(project: String, agent: String, session: String?) -> String {
        var session = (session ?? "").trimmingCharacters(in: .whitespaces)
        // codex titles end in " | project" — herdr appends it, and we already show
        // the project, so drop the tail before composing.
        if session.hasSuffix("| " + project) {
            session = String(session.dropLast(project.count + 2)).trimmingCharacters(in: .whitespaces)
        } else if session.hasSuffix("|" + project) {
            session = String(session.dropLast(project.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        let isBanner = session.isEmpty
            || session.lowercased() == agent.lowercased()
            || session.lowercased() == "claude code"
            || session.lowercased() == "codex"
        return isBanner ? project : "\(project) · \(session)"
    }
}

/// The whole payload the widget renders: counts for the small family, the list for
/// medium/large. One JSON blob under one key beats a forest of scalar defaults —
/// the counts and the list can never disagree about the same tick.
struct HerdiSnapshot: Codable {
    var updatedAt: Date
    var blocked: Int
    var working: Int
    var done: Int
    var idle: Int
    var agents: [WidgetAgent]

    static let appGroupKey = "herdi_snapshot"

    private static let suite = "group.com.goingta.herdi"

    /// The widget's own standard defaults. The menu-bar app writes the snapshot here
    /// with `defaults write <container plist>` as a fallback channel: a sandboxed
    /// widget's App Group access needs a container binding that free-team, ad-hoc
    /// setups never get, while its own container preferences are unconditionally
    /// readable. The app is unsandboxed and writes that file through cfprefsd, so
    /// both sides stay coherent.
    static let widgetStandardKey = "herdi_snapshot_json"
    static let widgetContainerDomain = "com.goingta.herdi.widget"

    static func save(_ snapshot: HerdiSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: suite)?.set(data, forKey: appGroupKey)
        // The app's own domain carries the same blob for the widget's
        // temporary-exception read (see load()).
        UserDefaults.standard.set(data, forKey: appGroupKey)
    }

    static func jsonString(_ snapshot: HerdiSnapshot) -> String? {
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func loadFromSuite() -> HerdiSnapshot? {
        // The App Group copy — the app-side source of truth for change detection.
        guard let data = UserDefaults(suiteName: suite)?.data(forKey: appGroupKey),
              let decoded = try? JSONDecoder().decode(HerdiSnapshot.self, from: data) else { return nil }
        return decoded
    }

    /// The menu-bar app's own defaults domain, readable by the sandboxed widget
    /// through the shared-preference temporary exception.
    private static let appDomain = "com.goingta.herdi"

    static func load() -> HerdiSnapshot? {
        // 1. The app's own domain — the primary channel under the temporary exception.
        if let data = UserDefaults(suiteName: appDomain)?.data(forKey: appGroupKey),
           let decoded = try? JSONDecoder().decode(HerdiSnapshot.self, from: data) {
            return decoded
        }
        // 2. The widget's own container defaults (defaults-CLI mirror channel).
        if let json = UserDefaults.standard.string(forKey: widgetStandardKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(HerdiSnapshot.self, from: data) {
            return decoded
        }
        // 3. The App Group suite (works when container binding is in place).
        return loadFromSuite()
    }
}

