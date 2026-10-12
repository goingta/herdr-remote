import XCTest
@testable import Herdi

/// The approval card's lifecycle rules: what the data layer does when a
/// question ends somewhere other than the card — answered at the desk, in
/// Ghostty, or from another client. The card must follow reality: stale
/// options put option text on the wire into a composer that no longer shows
/// a menu, and a card for a vanished pane hangs forever.
final class AgentPromptLifecycleTests: XCTestCase {

    private func agent(_ id: String, _ status: AgentStatus) -> Agent {
        Agent(id: id, name: "agent-\(id)", status: status, project: "proj", cwd: "/tmp")
    }

    // MARK: clearPrompt — no stale buttons after the question ends

    func testClearPromptDropsEveryCardField() {
        let a = agent("wV:p1", .blocked)
        a.prompt = "Allow rm /tmp/x?"
        a.options = ["y", "p", "\u{1B}"]
        a.promptId = "abc123"
        a.multiOptions = ["Push", "Watch"]
        a.selectedOptions = ["Push"]
        a.interaction = "multi_question"
        a.isMultiSelect = true
        let before = a.blockedGeneration

        a.clearPrompt()

        XCTAssertNil(a.prompt)
        XCTAssertNil(a.options)
        XCTAssertNil(a.promptId)
        XCTAssertEqual(a.multiOptions, [])
        XCTAssertEqual(a.selectedOptions, [])
        XCTAssertNil(a.interaction)
        XCTAssertFalse(a.isMultiSelect)
        // The episode is over: a background screen read that captured the old
        // generation must refuse to publish into the new one.
        XCTAssertEqual(a.blockedGeneration, before + 1)
    }

    // MARK: nextBlockedAgent — the switch-to-next queue policy

    func testNextBlockedSkipsTheRetractedCard() {
        let agents = [agent("a", .blocked), agent("b", .blocked), agent("c", .working)]
        XCTAssertEqual(Agent.nextBlockedAgent(afterId: "a", agents: agents)?.id, "b")
    }

    func testNextBlockedNilWhenQueueEmpty() {
        let agents = [agent("a", .working), agent("b", .idle)]
        XCTAssertNil(Agent.nextBlockedAgent(afterId: "a", agents: agents))
    }

    func testNextBlockedIgnoresNonBlockedRows() {
        // Only status == blocked queues a card: an idle twin must not take over.
        let agents = [agent("a", .blocked), agent("b", .idle), agent("c", .unknown)]
        XCTAssertNil(Agent.nextBlockedAgent(afterId: "a", agents: agents))
    }

    func testNextBlockedKeepsPollOrder() {
        // The first blocked agent in poll order wins — no sorting invented here.
        let agents = [agent("x", .working), agent("m", .blocked), agent("n", .blocked)]
        XCTAssertEqual(Agent.nextBlockedAgent(afterId: "x", agents: agents)?.id, "m")
    }
}
