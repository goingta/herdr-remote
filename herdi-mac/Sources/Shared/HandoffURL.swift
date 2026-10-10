import Foundation

/// The widget→app handoff link, shared so the producing and parsing ends can
/// never drift: `herdi://focus?agent=<urlencoded Agent.id>`.
enum HandoffURL {
    static let scheme = "herdi"
    static let fallback = URL(string: "herdi://focus")!

    static func make(agentId: String?) -> URL {
        guard let agentId, !agentId.isEmpty else { return fallback }
        var components = URLComponents(string: "herdi://focus")!
        components.queryItems = [URLQueryItem(name: "agent", value: agentId)]
        return components.url ?? fallback
    }

    /// The Agent.id a URL targets, or nil when the link carries none (rows from
    /// old cached snapshots): the app treats those as no-op by design.
    static func agentId(in url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == "focus",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let id = components.queryItems?.first(where: { $0.name == "agent" })?.value
        return (id?.isEmpty == false) ? id : nil
    }
}
