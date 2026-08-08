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

    // A JSON object that omits autoConvertHotkey must decode to nil, matching
    // swift-protobuf's optional field semantics for an unset optional string.
    func testAutoConvertHotkeyDecodesToNilWhenOmitted() throws {
        let jsonData = try XCTUnwrap("{\"profileName\": \"Test\"}".data(using: .utf8))
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: jsonData)

        XCTAssertNil(decoded.autoConvertHotkey)
    }
}
