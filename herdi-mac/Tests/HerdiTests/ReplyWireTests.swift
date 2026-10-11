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

    func testUnknownScreenGetsNoButtons() {
        // The fallback used to hand back the claude permission triple for every
        // unrecognized blocked pane. The row's Allow button then put a full
        // option sentence on the wire to codex menus — the leading "y" confirmed
        // the dialog and "es, single permission" piled into the composer.
        XCTAssertEqual(RelayConnection.detectOptions("some unrecognized prompt"), [])
    }

    // MARK: detectOptions — claude numbered menus take digit presses

    func testClaudeNumberedMenuMapsToDigitKeys() {
        let screen = """
        Do you want to proceed?
        ❯ 1. Yes
          2. Yes, and always allow access to /tmp from this project
          3. No
        Esc to cancel · Tab to amend
        """
        XCTAssertEqual(RelayConnection.detectOptions(screen), ["1", "2", "3"])
    }

    func testNumberedRunWithWrappedContinuationStillParses() {
        // Claude wraps long labels and indents their description lines; both
        // belong to the run.
        let screen = """
        › 1. 删 App Group 先装上（推荐）
             把 entitlements 里的 App Group 删掉，立即可装
          2. 你手动在 Xcode 注册
        Esc to cancel
        """
        XCTAssertEqual(RelayConnection.detectOptions(screen), ["1", "2"])
    }

    func testNumberedListInAgentOutputIsNotAMenu() {
        // Same rows, but the menu's own footer is missing: output text, and the
        // honest answer is no buttons.
        let screen = """
        Steps:
        1. run the tests
        2. push the branch
        """
        XCTAssertEqual(RelayConnection.detectOptions(screen), [])
    }

    func testMenuWithDescriptionsAboveAClippedWindowStillParses() {
        // A claude numbered menu with per-option descriptions runs ~10 rows; the
        // read window (readPaneForBlocked keeps the last 12 non-empty lines) must
        // hold the whole run — a window clipping "❯ 1." off the top left detection
        // no run starting at 1, and the pane got no buttons at all.
        let screen = """
        Reason: the sandbox could not start. Allow the command?

        ❯ 1. 删 App Group 先装上（推荐）
             我把 entitlements 里的 App Group 删掉，立即可装
          2. 你手动在 Xcode 注册
             你在 mac 上打开 Xcode 手动注册，然后告诉我重试
          3. No, and tell me what to do differently
        Esc to cancel
        """
        XCTAssertEqual(RelayConnection.detectOptions(screen), ["1", "2", "3"])
    }

    func testCodexMenuNeverYieldsDigits() {
        // Codex rows carry (y)/(p) markers; even with the footer clipped off the
        // read window the shortcut branch must win before numbered detection.
        let screen = """
        › 1. Yes, proceed (y)
          2. Yes, and don't ask again (p)
          3. No, and tell Codex what to do differently (esc)
        """
        XCTAssertEqual(RelayConnection.detectOptions(screen), ["y", "p", "\u{1B}"])
    }

    func testNumberedMenuBeyondNineOptionsGetsNoButtons() {
        // A tenth-of-a-second digit would ride the word-reply newline a menu
        // selection must never carry, so wide menus get no buttons at all.
        let rows = (1...10).map { "\($0). option \($0)" }.joined(separator: "\n")
        XCTAssertEqual(RelayConnection.detectOptions("pick one\n\(rows)\nEsc to cancel"), [])
    }
}
