import SwiftUI
import WidgetKit

// The widget extension renders from the App Group snapshot the menu-bar app
// publishes (Shared/HerdiSnapshot.swift). It never talks to herdr itself.

struct HerdiEntry: TimelineEntry {
    let date: Date
    let snapshot: HerdiSnapshot?
}

struct HerdiProvider: TimelineProvider {
    func placeholder(in context: Context) -> HerdiEntry {
        HerdiEntry(date: .now, snapshot: HerdiSnapshot(
            updatedAt: .now, blocked: 1, working: 2, done: 1, idle: 3,
            agents: [
                WidgetAgent(agent: "claude", project: "api-server", status: "blocked"),
                WidgetAgent(agent: "codex", project: "web", status: "working")
            ]
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (HerdiEntry) -> Void) {
        // The gallery preview: real data when the app has published any, so the
        // "add widget" sheet never shows a hollow 0/0/0.
        completion(HerdiEntry(date: .now, snapshot: HerdiSnapshot.load() ?? placeholder(in: context).snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HerdiEntry>) -> Void) {
        let entry = HerdiEntry(date: .now, snapshot: HerdiSnapshot.load())
        // The app calls reloadAllTimelines() on every state change, which is what
        // keeps this current; the policy only backstops the case where the app is
        // quit and nothing reloads again.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct HerdiWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HerdiEntry

    var body: some View {
        Group {
            if let s = entry.snapshot {
                content(s)
            } else {
                Text("Open Herdi to connect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var maxRows: Int {
        switch family {
        case .systemSmall: return 3
        case .systemLarge: return 12
        default: return 5
        }
    }

    private func content(_ s: HerdiSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            countsRow(s)
            if !s.agents.isEmpty {
                // small has no rows worth tapping individually: whole-widget opens the
                // default target (same rank order as the rows, so it equals row one).
                if family == .systemSmall {
                    contentBody(s)
                        .widgetURL(handoffURL(for: s.agents.first))
                } else {
                    contentBody(s)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func contentBody(_ s: HerdiSnapshot) -> some View {
        // medium/large: per-row Link (widgetURL is whole-widget only). small's
        // single target goes through .widgetURL on the container above.
        ForEach(s.agents.prefix(maxRows), id: \.self) { a in
            agentRow(a)
                .background {
                    Link(destination: handoffURL(for: a)) { Color.clear }
                }
        }
        if s.agents.count > maxRows {
            Text("+\(s.agents.count - maxRows) more")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// The shared handoff link (HandoffURL). Rows without an id (old cached
    /// snapshots) fall back to the bare URL, which the app treats as a no-op.
    private func handoffURL(for agent: WidgetAgent?) -> URL {
        HandoffURL.make(agentId: agent?.id)
    }

    private func countsRow(_ s: HerdiSnapshot) -> some View {
        HStack(spacing: 10) {
            badge(s.blocked, color: .red, icon: "exclamationmark.circle.fill")
            badge(s.working, color: .green, icon: "circle.fill")
            badge(s.done, color: .orange, icon: "checkmark.circle.fill")
            badge(s.idle, color: .gray, icon: "circle")
        }
    }

    private func agentRow(_ a: WidgetAgent) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color(for: a.status))
                .frame(width: 7, height: 7)
            Text(displayTitle(a))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(a.agent)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 【项目 · 会话名】when herdr's title says something real; bare project when the
    /// title is just the harness banner ("Claude Code") or empty — repeating the
    /// agent column as a title wastes the row.
    private func displayTitle(_ a: WidgetAgent) -> String {
        var session = (a.session ?? "").trimmingCharacters(in: .whitespaces)
        let project = a.project
        // codex titles end in " | project" — herdr appends it, and we already show
        // the project, so drop the tail before composing.
        if session.hasSuffix("| " + project) {
            session = String(session.dropLast(project.count + 2)).trimmingCharacters(in: .whitespaces)
        } else if session.hasSuffix("|" + project) {
            session = String(session.dropLast(project.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        let isBanner = session.isEmpty
            || session.lowercased() == a.agent.lowercased()
            || session.lowercased() == "claude code"
            || session.lowercased() == "codex"
        return isBanner ? project : "\(project) · \(session)"
    }

    private func badge(_ n: Int, color: Color, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color)
            Text("\(n)").font(.caption).monospacedDigit()
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "blocked": return .red
        case "working": return .green
        case "done": return .orange
        default: return .gray
        }
    }
}

struct HerdiWidget: Widget {
    let kind = "HerdiWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HerdiProvider()) { entry in
            HerdiWidgetView(entry: entry)
        }
        .configurationDisplayName("herdi agents")
        .description("Agent status from your herdr fleet, updated by the menu-bar app.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// The extension process's entry point. WidgetKit launches the .appex, walks the
// bundle for this @main, and drives every widget it lists from it. Leaving it out
// compiles clean and crashes instantly at willFinishLaunching (EXC_BREAKPOINT) —
// which the gallery reads as "not a widget" and hides it.
@main
struct HerdiWidgetBundle: WidgetBundle {
    var body: some Widget {
        HerdiWidget()
    }
}
