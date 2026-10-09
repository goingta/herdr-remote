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

    private func content(_ s: HerdiSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            countsRow(s)
            if !s.agents.isEmpty {
                ForEach(s.agents.prefix(4), id: \.self) { a in
                    agentRow(a)
                }
                if s.agents.count > 4 {
                    Text("+\(s.agents.count - 4) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
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
            Text(a.project)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(a.agent)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
        .supportedFamilies([.systemSmall, .systemMedium])
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
