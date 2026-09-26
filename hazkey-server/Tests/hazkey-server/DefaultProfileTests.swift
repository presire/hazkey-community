import XCTest

@testable import hazkey_server

final class DefaultProfileTests: XCTestCase {
    func testDefaultProfileResponseContainsFreshFactoryProfile() throws {
        // 前提: サーバの既定プロファイル応答ファクトリ
        let response = HazkeyServerConfig.getDefaultProfile()

        // 実行: ファクトリがリセットプレビュー用の応答を生成する
        let profile = try XCTUnwrap(response.currentConfig.profiles.first)

        // 期待: 未永続化のサーバ既定値をCurrentConfigで返す
        XCTAssertEqual(response.status, .success)
        XCTAssertTrue(response.errorMessage.isEmpty)
        XCTAssertEqual(response.currentConfig.profiles.count, 1)
        XCTAssertEqual(profile.profileName, "Default")
        XCTAssertEqual(profile.autoConvertMode, .autoConvertForMultipleChars)
        XCTAssertEqual(profile.autoConvertMinChars, 2)
        XCTAssertEqual(profile.autoConvertHotkey, "Control+Shift+L")
        XCTAssertEqual(profile.acceptPredictionHotkey, "F5")
        XCTAssertEqual(profile.zenzaiToggleHotkey, "Control+Alt+Z")
    }

    func testDefaultProfileDisablesAddressDictionary() throws {
        // 前提: サーバの既定プロファイル応答ファクトリ
        let response = HazkeyServerConfig.getDefaultProfile()

        // 実行: ファクトリがリセットプレビュー用の応答を生成する
        let profile = try XCTUnwrap(response.currentConfig.profiles.first)

        // 期待: 住所辞書は既定で明示的に無効化されている
        XCTAssertTrue(profile.hasUseAddressDictionary)
        XCTAssertEqual(profile.useAddressDictionary, false)
    }

    func testDefaultProfileDisablesEngineeringDictionary() throws {
        // 前提: サーバの既定プロファイル応答ファクトリ
        let response = HazkeyServerConfig.getDefaultProfile()

        // 実行: ファクトリがリセットプレビュー用の応答を生成する
        let profile = try XCTUnwrap(response.currentConfig.profiles.first)

        // 期待: 工学用語辞書は既定で明示的に無効化されている
        XCTAssertTrue(profile.hasUseEngineeringDictionary)
        XCTAssertEqual(profile.useEngineeringDictionary, false)
    }
}
