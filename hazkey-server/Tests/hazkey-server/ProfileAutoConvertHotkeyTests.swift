import Foundation
import XCTest
import SwiftProtobuf

@testable import hazkey_server

final class ProfileAutoConvertHotkeyTests: XCTestCase {
    // A Profile with autoConvertHotkey set must survive a JSON round-trip
    // with the exact fcitx5 key string preserved (not Qt's "Ctrl+Shift+L").
    func testAutoConvertHotkeyJSONRoundTrip() throws {
        var profile = Hazkey_Config_Profile()
        profile.autoConvertHotkey = "Control+Shift+L"

        let jsonData = try profile.jsonUTF8Data()
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: jsonData)

        XCTAssertEqual(decoded.autoConvertHotkey, "Control+Shift+L")
    }

    // A JSON object that omits autoConvertHotkey must decode without the field
    // being marked as explicitly set, matching swift-protobuf's field-presence
    // semantics for proto3 `optional`. The accessor itself returns the default
    // value ("") when unset; use `hasAutoConvertHotkey` to check presence.
    func testAutoConvertHotkeyDecodesToNilWhenOmitted() throws {
        let jsonData = try XCTUnwrap("{\"profileName\": \"Test\"}".data(using: .utf8))
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: jsonData)

        XCTAssertFalse(decoded.hasAutoConvertHotkey)
    }

    // A Profile with deleteLearningHotkey set must survive a JSON round-trip
    // with the exact fcitx5 key string preserved ([community] candidate
    // learning-data delete hotkey).
    func testDeleteLearningHotkeyJSONRoundTrip() throws {
        var profile = Hazkey_Config_Profile()
        profile.deleteLearningHotkey = "Control+Delete"

        let jsonData = try profile.jsonUTF8Data()
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: jsonData)

        XCTAssertEqual(decoded.deleteLearningHotkey, "Control+Delete")
    }

    // A JSON object that omits deleteLearningHotkey must decode without the
    // field being marked as explicitly set. The accessor returns "" when
    // unset; the client falls back to its built-in default.
    func testDeleteLearningHotkeyDecodesToNilWhenOmitted() throws {
        let jsonData = try XCTUnwrap("{\"profileName\": \"Test\"}".data(using: .utf8))
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: jsonData)

        XCTAssertFalse(decoded.hasDeleteLearningHotkey)
    }

    // A Profile with acceptPredictionHotkey set must survive a JSON round-trip
    // with the exact fcitx5 key string preserved (field 125).
    func testAcceptPredictionHotkeyJSONRoundTrip() throws {
        var profile = Hazkey_Config_Profile()
        profile.acceptPredictionHotkey = "F5"

        let jsonData = try profile.jsonUTF8Data()
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: jsonData)

        XCTAssertEqual(decoded.acceptPredictionHotkey, "F5")
    }

    // A JSON object that omits acceptPredictionHotkey must decode without the
    // field being marked as explicitly set, matching swift-protobuf's
    // field-presence semantics for proto3 `optional`. The accessor itself
    // returns the default value ("") when unset; use
    // `hasAcceptPredictionHotkey` to check presence.
    func testAcceptPredictionHotkeyDecodesToNilWhenOmitted() throws {
        let jsonData = try XCTUnwrap("{\"profileName\": \"Test\"}".data(using: .utf8))
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: jsonData)

        XCTAssertFalse(decoded.hasAcceptPredictionHotkey)
    }
}
