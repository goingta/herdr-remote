import XCTest
@testable import Herdi

/// The reply wire rules: what a notch-panel button click puts on the wire.
/// Pinned here because the failure this guards against shipped twice — the
/// relay's twin was fixed in PR #77, the mac copy survived five days and ate
/// every approval reply's submit keystroke.
final class ReplyWireTests: XCTestCase {

    // MARK: shlexQuoted — client text must survive the remote shell as ONE argument

    func testPlainArgsQuoteToThemselves() {
        XCTAssertEqual(
            RelayConnection.shlexQuoted(["pane", "send-text", "wV:p1"]),
            ["'pane'", "'send-text'", "'wV:p1'"]
        )
    }

    func testReplyWithSpacesStaysOneArgument() {
        let payload = "yes, single permission\n"
        let quoted = RelayConnection.shlexQuoted([payload])
        XCTAssertEqual(quoted.count, 1)
        // Shell-stripping the quoting must restore the payload byte for byte.
        XCTAssertEqual(quoted[0], "'yes, single permission\n'")
    }

    func testSingleQuoteInPayloadSurvives() {
        // POSIX escaping: ' -> '\'' — the one case the naive wrap breaks on.
        let quoted = RelayConnection.shlexQuoted(["it's fine"])
        XCTAssertEqual(quoted, ["'it'\\''s fine'"])
    }

    func testMultilinePayloadKeepsItsNewline() {
        // The newline IS the Enter that submits a text-answer prompt.
        let quoted = RelayConnection.shlexQuoted(["yes\n"])
        XCTAssertEqual(quoted, ["'yes\n'"])
    }

    // MARK: replyPayload — shortcut replies bare, word replies submit

    func testShortcutKeysGoBare() {
        XCTAssertEqual(RelayConnection.replyPayload("y"), "y")
        XCTAssertEqual(RelayConnection.replyPayload("p"), "p")
        XCTAssertEqual(RelayConnection.replyPayload("\u{1B}"), "\u{1B}")
    }

    func testWordReplyCarriesSubmitNewline() {
        XCTAssertEqual(RelayConnection.replyPayload("yes, single permission"), "yes, single permission\n")
    }

    // MARK: detectOptions — per-harness dialog shapes

    func testCodexKeyMenuMapsToShortcutBytes() {
        let screen = """
        Would you like to run the following command?
        $ touch /tmp/x
        › 1. Yes, proceed (y)
          2. Yes, and don't ask again for commands that start with `touch /tmp/x` (p)
          3. No, and tell Codex what to do differently (esc)
        Press enter to confirm or esc to cancel
        """
        XCTAssertEqual(RelayConnection.detectOptions(screen), ["y", "p", "\u{1B}"])
    }

    func testOmpTextPromptMapsToOptionWords() {
        let screen = "Allow the tool? yes, single permission / trust, always allow / no (tab to edit)"
        XCTAssertEqual(
            RelayConnection.detectOptions(screen),
            ["yes, single permission", "trust, always allow", "no (tab to edit)"]
        )
    }

    func testApproveAllBatchMenu() {
        XCTAssertEqual(
            RelayConnection.detectOptions("approve all pending? configure individually or exit (cancel subagents)"),
            ["approve all pending", "configure individually", "exit (cancel subagents)"]
        )
    }

    func testUnknownScreenFallsBackToPermissionTriple() {
        XCTAssertEqual(
            RelayConnection.detectOptions("some unrecognized prompt"),
            ["yes, single permission", "trust, always allow", "no (tab to edit)"]
        )
    }
}
