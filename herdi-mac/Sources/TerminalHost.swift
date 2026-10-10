import AppKit

/// The GUI terminal app hosting the user's attached herdr session.
/// Selected in the menu bar; persisted in UserDefaults.
enum TerminalHost: String, CaseIterable {
    case ghostty
    case iterm2 = "iterm"
    case terminal
    case vscode

    var displayName: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .iterm2: return "iTerm2"
        case .terminal: return "Terminal.app"
        case .vscode: return "VS Code"
        }
    }

    /// Bundle id for LaunchServices activation (`open -a` equivalent). VS Code's
    /// bundle is the stable Visual Studio Code stable-channel id.
    var bundleID: String {
        switch self {
        case .ghostty: return "com.mitchellh.ghostty"
        case .iterm2: return "com.googlecode.iterm2"
        case .terminal: return "com.apple.Terminal"
        case .vscode: return "com.microsoft.VSCode"
        }
    }

    static var selected: TerminalHost {
        if let raw = UserDefaults.standard.string(forKey: "herdi_terminal_host"),
           let host = TerminalHost(rawValue: raw) {
            return host
        }
        return .ghostty
    }

    static func select(_ host: TerminalHost) {
        UserDefaults.standard.set(host.rawValue, forKey: "herdi_terminal_host")
    }

    /// Bring the host app forward. Application-level activation via LaunchServices —
    /// no TCC prompt, works from any process context. Pane-level targeting (Ghostty
    /// AppleScript `focus <terminal>` by tty) is a strategy refinement pending the
    /// pane→ssh-process mapping; see the Wayfinder map's fog notes.
    /// `completion(false)` when the host app is not installed; the async launch
    /// result is also observed, so a failed launch surfaces instead of vanishing.
    func activate(completion: ((Bool) -> Void)? = nil) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            completion?(false)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // .activateAllWindows would surface every window; leaving it off matches
        // "bring the session the user last had forward".
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            if let error {
                NSLog("Herdi host activation failed for \(self.displayName): \(error)")
                completion?(false)
            } else {
                completion?(true)
            }
        }
    }
}
