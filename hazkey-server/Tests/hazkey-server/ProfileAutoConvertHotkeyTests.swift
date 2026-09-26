import Foundation
import XCTest
import SwiftProtobuf

@testable import hazkey_server

final class ProfileAutoConvertHotkeyTests: XCTestCase {
    // autoConvertHotkeyを設定したProfileは、fcitx5のキー文字列を正確に保持したままJSONラウンドトリップできなければならない
    // (Qtの"[Ctrl] + [Shift] + [L[]"ではない)
    func testAutoConvertHotkeyJSONRoundTrip() throws {
        var profile = Hazkey_Config_Profile()
        profile.autoConvertHotkey = "Control+Shift+L"

        let jsonData = try profile.jsonUTF8Data()
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: jsonData)

        XCTAssertEqual(decoded.autoConvertHotkey, "Control+Shift+L")
    }

    // autoConvertHotkeyを省略したJSONオブジェクトは、フィールドを明示設定済みにせずにデコードしなければならない
    // これは、proto3 "optional"に対するswift-protobufのフィールド存在判定に従う
    // 未設定時のアクセサは既定値（""）を返すため、存在確認には"hasAutoConvertHotkey"を使用する
    func testAutoConvertHotkeyDecodesToNilWhenOmitted() throws {
        let jsonData = try XCTUnwrap("{\"profileName\": \"Test\"}".data(using: .utf8))
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: jsonData)

        XCTAssertFalse(decoded.hasAutoConvertHotkey)
    }

    // deleteLearningHotkeyを設定したProfileは、fcitx5のキー文字列を正確に保持したままJSONラウンドトリップできなければならない
    // (候補学習データ削除ホットキー)
    func testDeleteLearningHotkeyJSONRoundTrip() throws {
        var profile = Hazkey_Config_Profile()
        profile.deleteLearningHotkey = "Control+Delete"

        let jsonData = try profile.jsonUTF8Data()
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: jsonData)

        XCTAssertEqual(decoded.deleteLearningHotkey, "Control+Delete")
    }

    // deleteLearningHotkeyを省略したJSONオブジェクトは、フィールドを明示設定済みにせずにデコードしなければならない
    // 未設定時のアクセサは""を返し、クライアントは組み込みの既定値へフォールバックする
    func testDeleteLearningHotkeyDecodesToNilWhenOmitted() throws {
        let jsonData = try XCTUnwrap("{\"profileName\": \"Test\"}".data(using: .utf8))
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: jsonData)

        XCTAssertFalse(decoded.hasDeleteLearningHotkey)
    }

    // acceptPredictionHotkeyを設定したProfileは、fcitx5のキー文字列を正確に保持したままJSONラウンドトリップできなければならない
    // (フィールド125)
    func testAcceptPredictionHotkeyJSONRoundTrip() throws {
        var profile = Hazkey_Config_Profile()
        profile.acceptPredictionHotkey = "F5"

        let jsonData = try profile.jsonUTF8Data()
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: jsonData)

        XCTAssertEqual(decoded.acceptPredictionHotkey, "F5")
    }

    // acceptPredictionHotkeyを省略したJSONオブジェクトは、フィールドを明示設定済みにせずにデコードしなければならない
    // これは、proto3 "optional"に対するswift-protobufのフィールド存在判定に従う
    // 未設定時のアクセサは既定値（""）を返すため、存在確認には"hasAcceptPredictionHotkey"を使用する
    func testAcceptPredictionHotkeyDecodesToNilWhenOmitted() throws {
        let jsonData = try XCTUnwrap("{\"profileName\": \"Test\"}".data(using: .utf8))
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: jsonData)

        XCTAssertFalse(decoded.hasAcceptPredictionHotkey)
    }

    func testZenzaiToggleHotkeyJSONRoundTrip() throws {
        // 前提: 永続化したプロファイルに専用トグルホットキーが含まれる
        var profile = Hazkey_Config_Profile()
        profile.zenzaiToggleHotkey = "Control+Alt+Z"

        // 実行: プロファイルがJSON永続化境界を通過する
        let decoded = try Hazkey_Config_Profile(jsonUTF8Data: profile.jsonUTF8Data())

        // 確認: fcitx5のキー文字列が正確に保持される
        XCTAssertEqual(decoded.zenzaiToggleHotkey, "Control+Alt+Z")
    }
}
