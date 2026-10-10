import XCTest
import AppKit
@testable import Herdi

/// The status-item click router: left click opens the agent panel, right
/// click opens the settings menu. Pinned because the shape this replaced —
/// `statusItem?.menu = menu` — routed every click to the menu and left the
/// notch panel with no manual way back, which read as "the agent list is
/// missing" (the README screenshot is the panel, expanded).
final class StatusItemClickTests: XCTestCase {

    func testLeftClickTogglesThePanel() {
        XCTAssertEqual(StatusItemClick.route(for: .leftMouseUp), .togglePanel)
    }

    func testRightClickOpensTheSettingsMenu() {
        XCTAssertEqual(StatusItemClick.route(for: .rightMouseUp), .settingsMenu)
    }

    func testAuxiliaryClickOpensTheSettingsMenu() {
        // Trackpad two-finger click arrives as rightMouseUp; pens and other
        // auxiliary buttons arrive as otherMouseUp — treat them the same.
        XCTAssertEqual(StatusItemClick.route(for: .otherMouseUp), .settingsMenu)
    }

    func testAnythingElseFallsToThePanel() {
        XCTAssertEqual(StatusItemClick.route(for: .leftMouseDown), .togglePanel)
        XCTAssertEqual(StatusItemClick.route(for: .scrollWheel), .togglePanel)
    }
}
