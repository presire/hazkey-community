import XCTest

@testable import hazkey_server

/// [Shift]キーの長押し (500[ms]以上) ではサブ入力 (Direct Input) モードを切り替えず、
/// 短い[Shift]キータップでは従来どおり切り替えることを検証する
final class ShiftLongPressTests: XCTestCase {
    private func currentInputMode(of state: HazkeyServerState) -> Hazkey_Commands_CurrentInputModeInfo.InputMode {
        state.getCurrentInputMode().currentInputModeInfo.inputMode
    }

    func testShortShiftTapTogglesSubInputMode() {
        let state = HazkeyServerState()
        XCTAssertEqual(currentInputMode(of: state), .normal)

        // 1回目のタップ: normal -> direct
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .press).status, .success)
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .release).status, .success)
        XCTAssertTrue(state.isSubInputMode)
        XCTAssertEqual(currentInputMode(of: state), .direct)

        // 2回目のタップ: direct -> normal
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .press).status, .success)
        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .release).status, .success)
        XCTAssertFalse(state.isSubInputMode)
        XCTAssertEqual(currentInputMode(of: state), .normal)
    }

    func testLongShiftPressDoesNotToggleSubInputMode() {
        let state = HazkeyServerState()
        XCTAssertEqual(currentInputMode(of: state), .normal)

        XCTAssertEqual(state.processModifierEvent(modifier: .shift, event: .press).status, .success)
        // 押下時刻を過去に設定し、600[ms]の長押しを再現する
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
