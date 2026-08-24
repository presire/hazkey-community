import XCTest

@testable import hazkey_server

final class DefaultProfileTests: XCTestCase {
    func testDefaultProfileResponseContainsFreshFactoryProfile() throws {
        // Given: the server's default-profile response factory.
        let response = HazkeyServerConfig.getDefaultProfile()

        // When: the factory builds the reset-preview response.
        let profile = try XCTUnwrap(response.currentConfig.profiles.first)

        // Then: it returns the unpersisted server defaults in CurrentConfig.
        XCTAssertEqual(response.status, .success)
        XCTAssertTrue(response.errorMessage.isEmpty)
        XCTAssertEqual(response.currentConfig.profiles.count, 1)
        XCTAssertEqual(profile.profileName, "Default")
        XCTAssertEqual(profile.autoConvertMode, .autoConvertForMultipleChars)
        XCTAssertEqual(profile.autoConvertMinChars, 2)
        XCTAssertEqual(profile.autoConvertHotkey, "Control+Shift+L")
    }
}
