import Foundation
import XCTest

@testable import hazkey_server

final class UserDictionaryProfileSettingTests: XCTestCase {
  func testUserDictionaryDefaultsToTrueWhenFieldMissing() {
    var profile = Hazkey_Config_Profile()
    profile.profileName = "Default"

    XCTAssertFalse(profile.hasUseUserDictionary)
    XCTAssertTrue(profile.useUserDictionaryEffective)
  }

  func testUserDictionaryRespectsExplicitFalse() {
    var profile = Hazkey_Config_Profile()
    profile.profileName = "Disabled"
    profile.useUserDictionary = false

    XCTAssertTrue(profile.hasUseUserDictionary)
    XCTAssertFalse(profile.useUserDictionaryEffective)
  }

  func testUserDictionaryRespectsExplicitTrue() {
    var profile = Hazkey_Config_Profile()
    profile.profileName = "Enabled"
    profile.useUserDictionary = true

    XCTAssertTrue(profile.hasUseUserDictionary)
    XCTAssertTrue(profile.useUserDictionaryEffective)
  }
}
