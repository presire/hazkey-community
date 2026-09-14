import XCTest

@testable import hazkey_server

/// Tests that a long Shift press (hold >= 500 ms) does not toggle the
/// sub-input (Direct Input) mode, while a quick Shift tap still does.
final class ShiftLongPressTests: XCTestCase {
    private func currentInputMode(of state: HazkeyServerState) -> Hazkey_Commands_CurrentInputModeInfo.InputMode {
        state.getCurrentInputMode().currentInputModeInfo.inputMode
    }

    func testShortShiftTapTogglesSubInputMode() {
        let state = HazkeyServerState()
        XCTAssertEqual(currentInputMode(of: state), .normal)

        // First tap: normal -> direct.
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .press).status, .success)
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .release).status, .success)
        XCTAssertTrue(state.isSubInputMode)
        XCTAssertEqual(currentInputMode(of: state), .direct)

        // Second tap: direct -> normal.
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .press).status, .success)
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .release).status, .success)
        XCTAssertFalse(state.isSubInputMode)
        XCTAssertEqual(currentInputMode(of: state), .normal)
    }

    func testLongShiftPressDoesNotToggleSubInputMode() {
        let state = HazkeyServerState()
        XCTAssertEqual(currentInputMode(of: state), .normal)

        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .press).status, .success)
        // Simulate a 600 ms hold by backdating the press timestamp.
        state.shiftPressedAt = ContinuousClock.now - .milliseconds(600)
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .release).status, .success)

        XCTAssertFalse(state.isSubInputMode)
        XCTAssertEqual(currentInputMode(of: state), .normal)
    }

    func testShiftWithCharacterDoesNotToggle() {
        let state = HazkeyServerState()
        XCTAssertEqual(currentInputMode(of: state), .normal)

        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .press).status, .success)
        XCTAssertEqual(state.inputChar(inputString: "a").status, .success)
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .release).status, .success)

        XCTAssertFalse(state.isSubInputMode)
        XCTAssertEqual(currentInputMode(of: state), .normal)
    }

    func testCancelEventDoesNotToggleSubInputMode() {
        let state = HazkeyServerState()
        XCTAssertEqual(currentInputMode(of: state), .normal)

        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .press).status, .success)
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .cancel).status, .success)
        XCTAssertEqual(currentInputMode(of: state), .normal)

        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .press).status, .success)
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .release).status, .success)
        XCTAssertEqual(currentInputMode(of: state), .direct)
    }
}
