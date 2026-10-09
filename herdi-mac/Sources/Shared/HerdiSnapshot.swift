import Foundation

/// One row of the desktop widget's agent list. Written by the menu-bar app into the
/// shared container, read by the widget extension — no other transport exists between
/// the two processes, and the widget cannot SSH or open a socket itself.
///
/// Both targets compile this file; the fields are the stable string contract across
/// that boundary, so keep them Codable-stable.
struct WidgetAgent: Codable, Hashable {
    var agent: String
    var project: String
    var status: String

    /// Sort rank: the neediest first, matching the herd list's ordering idea.
    var rank: Int {
        switch status {
        case "blocked": return 0
        case "working": return 1
        case "done": return 2
        default: return 3
        }
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

    private static let suite = "group.com.dcolinmorgan.herdi"

    static func save(_ snapshot: HerdiSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: suite)?.set(data, forKey: appGroupKey)
    }

    static func load() -> HerdiSnapshot? {
        guard let data = UserDefaults(suiteName: suite)?.data(forKey: appGroupKey),
              let decoded = try? JSONDecoder().decode(HerdiSnapshot.self, from: data) else { return nil }
        return decoded
    }
}

