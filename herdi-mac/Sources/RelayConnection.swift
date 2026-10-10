import Foundation
import Network
import Observation
import os
import UserNotifications
import WidgetKit

@Observable
final class RelayConnection {
    private let sendLog = Logger(subsystem: "com.herdr.herdi", category: "Send")
    var agents: [Agent] = []
    var isConnected = false
    var hostAddress = "ws://127.0.0.1:8375"
    var mode: ConnectionMode = .direct
    var herdrError: String? = nil  // Surfaces binary-not-found etc.

    enum ConnectionMode: String, CaseIterable {
        case direct = "Direct (herdr CLI)"
        case relay = "Relay (WebSocket)"
    }

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var pollTimer: Timer?
    private var lastRemotePoll: Date?
    private var isPolling = false
    private var reconnectAttempt = 0
    private var reconnecting = false
    private var herdrPath: String = ""
    var remotes: [String] = [] // SSH targets, e.g. ["user@host"]

    init() {
        herdrPath = resolveHerdrPath()
        migrateLegacyConfig()
        // Load saved remotes
        if let saved = UserDefaults.standard.stringArray(forKey: "herdi_remotes") {
            remotes = saved
        }
        startDirect()
    }

    /// The bundle id changed (com.dcolinmorgan.herdi -> com.goingta.herdi) when real
    /// development signing arrived — the old ids are registered to the original
    /// author's team and a personal team cannot claim them. Pull the hand-set
    /// configuration across once so an in-place upgrade keeps its remotes.
    private func migrateLegacyConfig() {
        guard let legacy = UserDefaults(suiteName: "com.dcolinmorgan.herdi") else { return }
        let cur = UserDefaults.standard
        if cur.stringArray(forKey: "herdi_remotes") == nil,
           let old = legacy.stringArray(forKey: "herdi_remotes") {
            cur.set(old, forKey: "herdi_remotes")
        }
        if cur.data(forKey: "herdi_remote_settings") == nil,
           let old = legacy.data(forKey: "herdi_remote_settings") {
            cur.set(old, forKey: "herdi_remote_settings")
        }
        if cur.string(forKey: "herdi_herdr_path") == nil,
           let old = legacy.string(forKey: "herdi_herdr_path") {
            cur.set(old, forKey: "herdi_herdr_path")
        }
    }

    /// Resolve herdr binary: UserDefaults override → HERDR_BIN env → PATH lookup → common locations
    private func resolveHerdrPath() -> String {
        // 1. UserDefaults override (set via Settings)
        if let custom = UserDefaults.standard.string(forKey: "herdi_herdr_path"),
           !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        // 2. HERDR_BIN environment variable
        if let envPath = ProcessInfo.processInfo.environment["HERDR_BIN"],
           FileManager.default.isExecutableFile(atPath: envPath) {
            return envPath
        }
        // 3. Resolve via PATH using /usr/bin/which
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["herdr"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {}
        // 4. Common install locations
        let commonPaths = [
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            NSString(string: "~/.local/bin/herdr").expandingTildeInPath,
            NSString(string: "~/bin/herdr").expandingTildeInPath
        ]
        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Not found — return empty and set error in pollHerdr
        return ""
    }

    // MARK: - Direct Mode (polls herdr CLI)

    func startDirect() {
        mode = .direct
        task?.cancel(with: .normalClosure, reason: nil)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollHerdr()
        }
        pollHerdr() // immediate first poll
    }

    private func pollHerdr() {
        // One poll in flight at any time. A tick that fires while the previous one
        // still runs (slow SSH link, hung subprocess) is skipped outright — enqueueing
        // it would pile a new utility thread onto the same blockage every 2s, which
        // is exactly how the process once accumulated 500+ stuck poll threads.
        guard !isPolling else { return }
        isPolling = true
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { isPolling = false }
            // Remote cadence is decided first: a Mac without a local herdr still polls
            // its remotes — the missing binary only zeroes the list when there is
            // nothing else to ask. The early return this replaces was the "0 agents"
            // dead end for anyone whose agents all live on the dev box.
            let pollRemotes: Bool
            if let last = lastRemotePoll, Date().timeIntervalSince(last) < 4.5 {
                pollRemotes = false
            } else {
                lastRemotePoll = Date()
                pollRemotes = true
            }

            let hasLocal = !herdrPath.isEmpty
            var allAgents = [ParsedAgent]()
            if hasLocal {
                allAgents = parseAgents(from: runHerdr("pane", "list"), host: "local")
            }
            if pollRemotes {
                for remote in remotes {
                    let result = runSSH(remote, remoteHerdrBin(remote), "pane", "list")
                    allAgents += parseAgents(from: result, host: remote)
                }
            }

            DispatchQueue.main.async { [self] in
                if hasLocal {
                    isConnected = true
                    herdrError = nil  // Clear any previous error
                } else if remotes.isEmpty {
                    isConnected = false
                    herdrError = "herdr not found. Install herdr or set path in Settings."
                    agents = []
                    return
                } else {
                    isConnected = true
                    herdrError = nil  // Remote agents still flow; no local binary needed
                }
                var seen = Set<String>()
                for a in allAgents {
                    seen.insert(a.id)
                    if let existing = agents.first(where: { $0.id == a.id }) {
                        if existing.status != a.status {
                            if a.status == .blocked && existing.status != .blocked {
                                readPaneForBlocked(existing, remote: a.host == "local" ? nil : a.host)
                            }
                            existing.status = a.status
                        }
                        if existing.project != a.project { existing.project = a.project }
                        if existing.host != a.host { existing.host = a.host }
                        if existing.session != a.session { existing.session = a.session }
                    } else {
                        let agent = Agent(id: a.id, name: a.name, status: a.status, project: a.project, cwd: a.cwd, host: a.host)
                        agent.session = a.session
                        agents.append(agent)
                        if a.status == .blocked { readPaneForBlocked(agent, remote: a.host == "local" ? nil : a.host) }
                    }
                }
                // A tick that skipped the remotes has no say over them: the sweep would
                // delete every remote agent on the ticks between remote polls.
                agents.removeAll { a in
                    if a.host != "local" && !pollRemotes { return false }
                    return !seen.contains(a.id)
                }
                publishWidgetSnapshot()
            }
        }
    }

    /// The desktop widget cannot reach herdr itself — no SSH, no socket — so the
    /// app publishes a snapshot into the shared container after every poll that
    /// changed something, and asks WidgetKit to re-read it. Reloads are budgeted
    /// by the system, so identical states are skipped: most ticks are idle panes
    /// repeating themselves, and spending the budget on those starves real changes.
    private func publishWidgetSnapshot() {
        let rows = agents.map {
            WidgetAgent(id: $0.id, agent: $0.name, project: $0.project, status: $0.status.rawValue, session: $0.session)
        }
        let snapshot = HerdiSnapshot(
            updatedAt: Date(),
            blocked: rows.filter { $0.status == "blocked" }.count,
            working: rows.filter { $0.status == "working" }.count,
            done: rows.filter { $0.status == "done" }.count,
            idle: rows.filter { $0.status == "idle" || $0.status == "unknown" }.count,
            agents: rows.sorted { ($0.rank, $0.project) < ($1.rank, $1.project) }
        )
        // Change detection reads the App Group suite only.
        if let current = HerdiSnapshot.loadFromSuite(), current.blocked == snapshot.blocked,
           current.working == snapshot.working, current.done == snapshot.done,
           current.idle == snapshot.idle, current.agents == snapshot.agents {
            return
        }
        HerdiSnapshot.save(snapshot)
        // The widget reads the app's own defaults domain through the shared-preference
        // temporary exception, so this native write IS the data delivery — no
        // cross-container paths involved.
        UserDefaults.standard.set(snapshot.agents.count, forKey: "herdi_snapshot_written_count")
        WidgetCenter.shared.reloadAllTimelines()
    }

    private struct ParsedAgent {
        let id: String, name: String, status: AgentStatus, project: String, cwd: String, host: String
        var session: String?
    }

    private func parseAgents(from output: String, host: String) -> [ParsedAgent] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultObj = json["result"] as? [String: Any],
              let panes = resultObj["panes"] as? [[String: Any]] else { return [] }

        return panes.compactMap { p in
            guard let agent = p["agent"] as? String, !agent.isEmpty else { return nil }
            let paneId = (host == "local" ? "" : "\(host):") + (p["pane_id"] as? String ?? "")
            let status = AgentStatus(rawValue: p["agent_status"] as? String ?? "unknown") ?? .unknown
            let cwd = p["cwd"] as? String ?? ""
            // herdr's terminal title carries the live task name ("接入 deepseek-harness 到多
            // Agent 方案"); the stripped variant drops the harness spinner prefix. Idle
            // panes leave the harness banner here ("Claude Code") — the widget de-dupes.
            let session = (p["terminal_title_stripped"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return ParsedAgent(id: paneId, name: agent, status: status, project: (cwd as NSString).lastPathComponent, cwd: cwd, host: host, session: session.isEmpty ? nil : session)
        }
    }

    // MARK: - Reply wire rules (pure, pinned by HerdiTests)

    /// shlex-quote each argument: ssh hands everything after the host to the
    /// remote shell, which re-splits argv on whitespace and newline.
    static func shlexQuoted(_ args: [String]) -> [String] {
        args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    }

    /// The bytes one reply puts on the wire. Shortcut-key replies (codex
    /// approval menu: "y" / "p" / ESC) go bare — the dialog is already
    /// confirmed by the time a trailing newline would arrive, and it lands in
    /// the freshly emptied composer as a stray blank line. Word replies keep
    /// the newline: for a text-answer prompt it is the Enter that submits.
    static func replyPayload(_ text: String) -> String {
        text.count <= 1 ? text : text + "\n"
    }

    private func runSSH(_ remote: String, _ args: String...) -> String {
        let process = Process()
        // Keychain only when a password is known to exist: a lookup for a remote
        // that has none can surface an authorization prompt in a GUI session —
        // invisible, modal, and one per poll — which stalls this thread and with
        // it the entire poll loop.
        let password = Self.loadRemoteSettings()[remote]?.hasPassword == true
            ? KeychainHelper.getPassword(for: remote)
            : nil

        // ClearAllForwardings: a one-shot command needs none of the user's
        // DynamicForward/RemoteForward config, and rebuilding those every poll would
        // race the user's own sessions holding them.
        //
        // No ControlMaster/ControlPersist on purpose: the persist master forks away
        // from the command ssh and keeps the inherited stdout pipe open, and a poll
        // every few seconds keeps resetting its persist timer — the master never
        // exits, readDataToEndOfFile never sees EOF, and every poll thread from then
        // on hangs in read() forever. One full handshake per command is the price.
        let connectionOptions = [
            "-o", "ConnectTimeout=5",
            "-o", "ClearAllForwardings=yes"
        ]

        // ssh hands everything after the host to the REMOTE shell, which re-splits
        // argv on whitespace and newline. Unquoted, "yes, single permission\n"
        // arrived as three words plus a second shell command — the newline that
        // submits the reply never reached herdr, so Allow/Trust/Deny did nothing
        // and the approval prompt re-fired. shlex-quote each argument, matching
        // what the relay does (_invoke_herdr, PR #77's fix).
        let remoteArgs = Self.shlexQuoted(Array(args))

        if let password, FileManager.default.fileExists(atPath: "/opt/homebrew/bin/sshpass") {
            // Use sshpass for password auth
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sshpass")
            process.arguments = ["-p", password, "ssh", "-o", "StrictHostKeyChecking=no"] + connectionOptions + [remote] + remoteArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes"] + connectionOptions + [remote] + remoteArgs
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            // Watchdog: a subprocess that neither exits nor closes its pipe (hung
            // network, wedged proxy chain) must never pin this thread — readDataToEndOfFile
            // has no timeout of its own. 20s covers ConnectTimeout + a slow herdr start.
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [process] in
                if process.isRunning { process.terminate() }
            }
            // Read BEFORE waiting: waitUntilExit first is the classic pipe deadlock —
            // a child blocked writing past the 64KB buffer and a parent blocked in
            // waitUntilExit watch each other forever. readDataToEndOfFile returns at
            // EOF, which the child's exit produces, so this orders itself correctly.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        } catch { return "" }
    }

    func addRemote(_ remote: String, password: String? = nil, label: String? = nil, herdrPath: String? = nil) {
        guard !remote.isEmpty, !remotes.contains(remote) else { return }
        remotes.append(remote)
        UserDefaults.standard.set(remotes, forKey: "herdi_remotes")
        let storedPassword = password.flatMap { $0.isEmpty ? nil : $0 }
        if let storedPassword {
            KeychainHelper.setPassword(storedPassword, for: remote)
        }
        saveRemoteSettings(remote, label: label, herdrPath: herdrPath, hasPassword: storedPassword != nil)
    }

    func removeRemote(_ remote: String) {
        remotes.removeAll { $0 == remote }
        UserDefaults.standard.set(remotes, forKey: "herdi_remotes")
        KeychainHelper.deletePassword(for: remote)
        var settings = Self.loadRemoteSettings()
        settings.removeValue(forKey: remote)
        Self.storeRemoteSettings(settings)
    }

    // MARK: - Remote settings

    struct RemoteSettings: Codable {
        var label: String?
        var herdrPath: String?
        // Whether a password was ever stored for this remote. Keychain lookups from a
        // GUI process can block on an authorization prompt nobody sees — and one hung
        // lookup per remote poll starves the whole poll loop — so a remote with no
        // password never touches the Keychain at all.
        var hasPassword: Bool?
    }

    /// Per-remote extras keyed by the SSH target string. `herdi_remotes` stays a plain
    /// array so hand-written `defaults write` configs keep working; everything new
    /// hangs off a separate dictionary.
    private static func loadRemoteSettings() -> [String: RemoteSettings] {
        guard let data = UserDefaults.standard.data(forKey: "herdi_remote_settings"),
              let decoded = try? JSONDecoder().decode([String: RemoteSettings].self, from: data) else { return [:] }
        return decoded
    }

    private static func storeRemoteSettings(_ settings: [String: RemoteSettings]) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "herdi_remote_settings")
        }
    }

    private func saveRemoteSettings(_ remote: String, label: String?, herdrPath: String?, hasPassword: Bool? = nil) {
        var settings = Self.loadRemoteSettings()
        let existing = settings[remote] ?? RemoteSettings(label: nil, herdrPath: nil, hasPassword: nil)
        let trimmed = (label ?? "").trimmingCharacters(in: .whitespaces)
        let bin = (herdrPath ?? "").trimmingCharacters(in: .whitespaces)
        settings[remote] = RemoteSettings(
            label: trimmed.isEmpty ? nil : trimmed,
            herdrPath: bin.isEmpty ? nil : bin,
            hasPassword: hasPassword ?? existing.hasPassword
        )
        Self.storeRemoteSettings(settings)
    }

    func displayName(for remote: String) -> String {
        let s = Self.loadRemoteSettings()[remote]?.label
        return (s?.isEmpty == false) ? s! : remote
    }

    /// The binary name sent over SSH. Users whose herdr is not on the non-interactive
    /// shell's PATH (e.g. ~/.local/bin) set a full path per remote in the form.
    func remoteHerdrBin(_ remote: String) -> String {
        if let p = Self.loadRemoteSettings()[remote]?.herdrPath, !p.isEmpty { return p }
        return "herdr"
    }

    // MARK: - Test connection

    enum TestResult {
        case ok(agentCount: Int)
        case authFailed
        case timeout
        case binaryNotFound(bin: String)
        case sshpassMissing
        case failed(String)
    }

    /// One probe before saving. Failures are classified, never silent — the poll path
    /// returns "" for everything, which is exactly why "0 agents" used to be a dead end.
    func testConnection(_ remote: String, herdrPath: String?) -> TestResult {
        let bin = (herdrPath?.trimmingCharacters(in: .whitespaces).isEmpty == false)
            ? herdrPath!.trimmingCharacters(in: .whitespaces)
            : "herdr"
        let password = Self.loadRemoteSettings()[remote]?.hasPassword == true
            ? KeychainHelper.getPassword(for: remote)
            : nil
        if password != nil && !FileManager.default.fileExists(atPath: "/opt/homebrew/bin/sshpass") {
            return .sshpassMissing
        }
        let started = Date()
        let output = runSSH(remote, bin, "pane", "list")
        let elapsed = Date().timeIntervalSince(started)

        if !output.isEmpty {
            let count = parseAgents(from: output, host: remote).count
            return .ok(agentCount: count)
        }
        if elapsed >= 4.5 {
            return .timeout
        }
        // Distinguish auth from a missing binary: BatchMode ssh exits 255 on auth
        // failure, while a successful connection running an unknown command does not.
        if sshExitStatus(remote, bin, ["--help"]) == 255 {
            return .authFailed
        }
        return .binaryNotFound(bin: bin)
    }

    private func sshExitStatus(_ remote: String, _ bin: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                             "-o", "ClearAllForwardings=yes", remote, bin] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch { return -1 }
    }

    private func readPaneForBlocked(_ agent: Agent, remote: String? = nil) {
        // Extract the real pane_id (strip host prefix if present)
        let paneId = agent.id.contains(":") && remote != nil
            ? String(agent.id.drop(while: { $0 != ":" }).dropFirst())
            : agent.id

        DispatchQueue.global(qos: .utility).async { [self] in
            // `visible`, not `recent`, as the relay does (PROMPT_READ_SOURCE). `recent` past the
            // pane's viewport makes herdr harvest the extra rows by walking the agent's own
            // scroll interface, which moves the operator's terminal -- something a read fired by
            // a status change must never do. 20 rows sits inside most viewports, so this is
            // usually a no-op; on a pane split down under 20 rows it is not. The prompt is on
            // screen by definition, so nothing is given up either way.
            let raw: String
            if let remote {
                raw = runSSH(remote, remoteHerdrBin(remote), "pane", "read", paneId, "--lines", "20", "--source", "visible")
            } else {
                raw = runHerdr("pane", "read", paneId, "--lines", "20", "--source", "visible")
            }
            let lines = raw.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .suffix(6)
            let content = lines.joined(separator: "\n")
            let options = Self.detectOptions(content)

            DispatchQueue.main.async {
                agent.prompt = String(content.prefix(500))
                agent.options = options
                self.sendNotification(agent: agent.name, project: agent.project)
            }
        }
    }

    static func detectOptions(_ text: String) -> [String] {
        let lower = text.lowercased()
        // Codex's approval menu is a key-select list ("1. Yes, proceed (y)"),
        // not a text prompt: the reply that works is the option's own shortcut
        // key, and the rawValue doubles as the bytes send-text puts on the wire.
        // Option words typed in full would confirm on the leading "y" and spill
        // "es, single permission" into the composer.
        if lower.contains("press enter to confirm") || lower.contains("yes, proceed") {
            return ["y", "p", "\u{1B}"]
        }
        if lower.contains("yes, single permission") {
            return ["yes, single permission", "trust, always allow", "no (tab to edit)"]
        }
        if lower.contains("approve all pending") {
            return ["approve all pending", "configure individually", "exit (cancel subagents)"]
        }
        return ["yes, single permission", "trust, always allow", "no (tab to edit)"]
    }

    private func runHerdr(_ args: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: herdrPath)
        process.arguments = Array(args)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [process] in
                if process.isRunning { process.terminate() }
            }
            // Read before wait — see runSSH for the deadlock this orders away.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: - Relay Mode (WebSocket)

    func connectRelay(to urlString: String) {
        guard let url = URL(string: urlString) else { return }
        mode = .relay
        hostAddress = urlString
        pollTimer?.invalidate()
        pollTimer = nil
        reconnecting = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = session.webSocketTask(with: url)
        task?.resume()
        reconnectAttempt = 0
        listen()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        pollTimer?.invalidate()
        isConnected = false
    }

    func send(response: ResponseMessage) {
        if mode == .direct {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let paneId = response.pane_id
                let payload = Self.replyPayload(response.text)
                // The one trace of an outgoing reply: without it, a "clicked
                // Allow, nothing happened" report has nothing to inspect.
                sendLog.notice("reply pane=\(paneId, privacy: .public) bytes=\(payload.utf8.count, privacy: .public) bare=\(payload.count <= 1, privacy: .public) head=\(String(payload.prefix(12)).debugDescription, privacy: .public)")
                // Check if this is a remote agent (id starts with "host:")
                if let agent = agents.first(where: { $0.id == paneId }), agent.host != "local" {
                    let realId = String(paneId.drop(while: { $0 != ":" }).dropFirst())
                    _ = runSSH(agent.host, remoteHerdrBin(agent.host), "pane", "send-text", realId, payload)
                } else {
                    _ = runHerdr("pane", "send-text", paneId, payload)
                }
            }

        } else {
            guard let data = try? JSONEncoder().encode(response) else { return }
            task?.send(.string(String(data: data, encoding: .utf8)!)) { _ in }
        }
    }

    func toggleQuestionOption(paneId: String, promptId: String, option: String) {
        guard mode == .relay,
              let data = try? JSONEncoder().encode(
                QuestionToggleMessage(pane_id: paneId, prompt_id: promptId, option: option)
              ) else { return }
        task?.send(.string(String(data: data, encoding: .utf8)!)) { _ in }
    }

    func submitQuestion(paneId: String, promptId: String) {
        guard mode == .relay,
              let data = try? JSONEncoder().encode(
                QuestionSubmitMessage(pane_id: paneId, prompt_id: promptId)
              ) else { return }
        task?.send(.string(String(data: data, encoding: .utf8)!)) { _ in }
    }

    func focusPane(_ paneId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if let agent = agents.first(where: { $0.id == paneId }), agent.host != "local" {
                let prefix = agent.host + ":"
                let remotePaneId = paneId.hasPrefix(prefix) ? String(paneId.dropFirst(prefix.count)) : paneId
                // Single `agent focus` switches pane + tab + workspace together.
                // The old three-step chain (pane get → workspace focus → tab focus)
                // landed the tab's *remembered* pane instead of the target — verified
                // on herdr 0.9.x (see issue #2's research).
                _ = runSSH(agent.host, remoteHerdrBin(agent.host), "agent", "focus", remotePaneId)
                return
            }

            _ = runHerdr("agent", "focus", paneId)
        }
    }

    func interruptPane(_ paneId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _ = runHerdr("pane", "send-keys", paneId, "Ctrl+c")
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                DispatchQueue.main.async { if !self.isConnected { self.isConnected = true } }
                switch message {
                case .string(let text): self.handleWS(text)
                case .data(let data): self.handleWS(String(data: data, encoding: .utf8) ?? "")
                @unknown default: break
                }
                self.listen()
            case .failure:
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !reconnecting, mode == .relay else { return }
        reconnecting = true
        reconnectAttempt += 1
        let delay = min(Double(1 << min(reconnectAttempt, 5)), 30.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isConnected else { return }
            self.reconnecting = false
            self.connectRelay(to: self.hostAddress)
        }
    }

    private func handleWS(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(AgentMessage.self, from: data) else { return }
        DispatchQueue.main.async { [self] in
            switch msg.type {
            case "agents":
                guard let list = msg.agents else { return }
                var seen = Set<String>()
                for a in list {
                    seen.insert(a.pane_id)
                    upsertAgent(a)
                }
                agents.removeAll { !seen.contains($0.id) }
            case "agent_update":
                if let update = msg.agentData { upsertAgent(update) }
            case "blocked":
                if let pid = msg.pane_id, let agent = agents.first(where: { $0.id == pid }) {
                    agent.prompt = msg.prompt
                    agent.promptId = msg.prompt_id
                    agent.options = msg.options
                    agent.multiOptions = msg.multi_options ?? []
                    agent.selectedOptions = msg.selected_options ?? []
                    agent.interaction = msg.interaction
                    agent.isMultiSelect = msg.multi ?? false
                    agent.status = .blocked
                    if msg.update != true {
                        sendNotification(agent: agent.name, project: agent.project)
                    }
                }
            default: break
            }
        }
    }

    private func upsertAgent(_ data: AgentMessage.AgentData) {
        if let existing = agents.first(where: { $0.id == data.pane_id }) {
            existing.name = data.agent
            existing.status = AgentStatus(rawValue: data.status) ?? .unknown
            existing.project = data.project
            existing.cwd = data.cwd
            existing.host = data.host ?? "local"
            return
        }
        agents.append(Agent(
            id: data.pane_id, name: data.agent,
            status: AgentStatus(rawValue: data.status) ?? .unknown,
            project: data.project, cwd: data.cwd, host: data.host ?? "local"
        ))
    }

    private func sendNotification(agent: String, project: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Agent Blocked"
        content.body = "\(agent) needs input in \(project)"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
