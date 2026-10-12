import Foundation

enum AgentStatus: String, Codable {
    case working, blocked, idle, unknown
}

@Observable
final class Agent: Identifiable {
    let id: String
    var name: String
    var status: AgentStatus
    var project: String
    var cwd: String
    var host: String
    // herdr's stripped terminal title — the live task name ("pnpm 项目启动"); nil for
    // panes whose title is just the harness banner.
    var session: String?
    var prompt: String?
    var options: [String]?
    var promptId: String?
    var multiOptions: [String] = []
    var selectedOptions: [String] = []
    var interaction: String?
    var isMultiSelect = false
    /// Monotonic marker for the current blocked episode. Bumped on entering
    /// blocked and when the question ends; a background screen read captures
    /// the value at start and may only publish what it read while the episode
    /// is unchanged — a read that lands after the answer must not resurrect
    /// the card it was for.
    var blockedGeneration = 0

    init(id: String, name: String, status: AgentStatus, project: String, cwd: String, host: String = "local") {
        self.id = id
        self.name = name
        self.status = status
        self.project = project
        self.cwd = cwd
        self.host = host
    }

    /// The question ended somewhere else — answered at the desk, in Ghostty, or
    /// from another client. Drop every field the approval card renders: a card
    /// left holding stale options puts option text on the wire into a composer
    /// that no longer shows a menu (the composer-residue bug of 2026-10-11).
    func clearPrompt() {
        prompt = nil
        options = nil
        promptId = nil
        multiOptions = []
        selectedOptions = []
        interaction = nil
        isMultiSelect = false
        blockedGeneration += 1
    }

    /// The next agent whose approval card should stand in place of one just
    /// retracted: the first still-blocked agent other than `afterId`, in poll
    /// order. Nil when the queue is empty — the panel collapses. Pure so the
    /// switch-to-next policy is testable without AppKit.
    static func nextBlockedAgent(afterId: String, agents: [Agent]) -> Agent? {
        agents.first { $0.status == .blocked && $0.id != afterId }
    }
}

struct AgentMessage: Decodable {
    let type: String
    let agents: [AgentData]?
    let pane_id: String?
    let agent: String?
    let agentData: AgentData?
    let project: String?
    let prompt: String?
    let options: [String]?
    let prompt_id: String?
    let multi_options: [String]?
    let selected_options: [String]?
    let interaction: String?
    let multi: Bool?
    let update: Bool?

    struct AgentData: Decodable {
        let pane_id: String
        let agent: String
        let status: String
        let cwd: String
        let project: String
        let host: String?
    }

    private enum CodingKeys: String, CodingKey {
        case type, agents, pane_id, agent, project, prompt, options, prompt_id
        case multi_options, selected_options, interaction, multi, update
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        agents = try? values.decode([AgentData].self, forKey: .agents)
        pane_id = try? values.decode(String.self, forKey: .pane_id)
        project = try? values.decode(String.self, forKey: .project)
        prompt = try? values.decode(String.self, forKey: .prompt)
        options = try? values.decode([String].self, forKey: .options)
        prompt_id = try? values.decode(String.self, forKey: .prompt_id)
        multi_options = try? values.decode([String].self, forKey: .multi_options)
        selected_options = try? values.decode([String].self, forKey: .selected_options)
        interaction = try? values.decode(String.self, forKey: .interaction)
        multi = try? values.decode(Bool.self, forKey: .multi)
        update = try? values.decode(Bool.self, forKey: .update)
        if type == "agent_update" {
            agentData = try? values.decode(AgentData.self, forKey: .agent)
            agent = nil
        } else {
            agent = try? values.decode(String.self, forKey: .agent)
            agentData = nil
        }
    }
}

struct ResponseMessage: Codable {
    let type = "respond"
    let pane_id: String
    let prompt_id: String?
    let text: String
}

struct QuestionToggleMessage: Codable {
    let type = "question_toggle"
    let pane_id: String
    let prompt_id: String
    let option: String
}

struct QuestionSubmitMessage: Codable {
    let type = "question_submit"
    let pane_id: String
    let prompt_id: String
}
