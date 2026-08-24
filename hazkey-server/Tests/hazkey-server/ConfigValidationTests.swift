import Foundation
import XCTest

@testable import hazkey_server

final class ConfigValidationTests: XCTestCase {
    func testDecodeProfilesRejectsWrongJSONShapes() {
        // Given: valid JSON whose top level or member has the wrong shape.
        let inputs = [Data("{}".utf8), Data("[\"profile\"]".utf8)]

        // When / Then: neither shape is accepted as a profile list.
        for input in inputs {
            XCTAssertThrowsError(try HazkeyServerConfig.decodeProfiles(from: input))
        }
    }

    func testDecodeProfilesNormalizesEmptyArrayToDefaultProfile() throws {
        // Given: an empty persisted profile list.
        let input = Data("[]".utf8)

        // When: it is decoded.
        let profiles = try HazkeyServerConfig.decodeProfiles(from: input)

        // Then: exactly one default profile is returned.
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(try XCTUnwrap(profiles.first).profileName, "Default")
    }

    func testNormalizeProfileUsesDefaultsForUnsetOptionalValues() throws {
        // Given: a profile received with optional configuration values unset.
        var profile = Hazkey_Config_Profile()
        profile.profileName = "Partial"

        // When: it crosses the configuration boundary.
        let normalized = try HazkeyServerConfig.normalizeProfile(profile)

        // Then: defaults are made explicit for all runtime numeric and enum settings.
        XCTAssertEqual(normalized.autoConvertMode, .autoConvertForMultipleChars)
        XCTAssertEqual(normalized.autoConvertMinChars, 2)
        XCTAssertEqual(normalized.numSuggestions, 3)
        XCTAssertEqual(normalized.numCandidatesPerPage, 9)
        XCTAssertEqual(normalized.zenzaiInferLimit, 10)
    }

    func testNormalizeProfileRejectsUnknownEnumAndInvalidNumericValues() {
        // Given: profiles containing values the server cannot safely interpret.
        var unknownEnum = HazkeyServerConfig.genDefaultConfig()
        unknownEnum.autoConvertMode = .UNRECOGNIZED(99)
        var invalidNumber = HazkeyServerConfig.genDefaultConfig()
        invalidNumber.zenzaiInferLimit = 101

        // When / Then: validation rejects both before persistence.
        XCTAssertThrowsError(try HazkeyServerConfig.normalizeProfile(unknownEnum))
        XCTAssertThrowsError(try HazkeyServerConfig.normalizeProfile(invalidNumber))
    }

    func testNormalizeProfileAcceptsNumericBoundsAndRejectsEmptyProfiles() throws {
        // Given: profiles using the UI's inclusive numeric limits.
        var minimum = HazkeyServerConfig.genDefaultConfig()
        minimum.numSuggestions = 1
        minimum.autoConvertMinChars = 1
        minimum.numCandidatesPerPage = 1
        minimum.zenzaiInferLimit = 1
        var maximum = HazkeyServerConfig.genDefaultConfig()
        maximum.numSuggestions = 10
        maximum.autoConvertMinChars = 10
        maximum.numCandidatesPerPage = 10
        maximum.zenzaiInferLimit = 100

        // When: valid boundary profiles are normalized.
        let normalized = try HazkeyServerConfig.normalizeProfiles([minimum, maximum])

        // Then: both values survive and an empty SetConfig list is rejected.
        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(try XCTUnwrap(normalized.first).numSuggestions, 1)
        XCTAssertEqual(try XCTUnwrap(normalized.last).zenzaiInferLimit, 100)
        XCTAssertThrowsError(try HazkeyServerConfig.normalizeProfiles([]))
    }

    func testCustomKeymapParserSkipsMalformedRowsAndLoadsValidRows() {
        // Given: empty, tab-only, incomplete, and over-wide rows around valid rules.
        let contents = "\n\t\nA\tあ\nB\tい\t\nC\tう\textra\tignored\nD\nE\t\n"

        // When: the custom keymap is parsed.
        let keymap = HazkeyServerConfig.parseCustomKeymap(contents)

        // Then: malformed rows are ignored without preventing valid rules from loading.
        XCTAssertEqual(keymap["A"]?.0, "あ")
        XCTAssertNil(keymap["A"]?.1)
        XCTAssertEqual(keymap["B"]?.0, "い")
        XCTAssertNil(keymap["B"]?.1)
        XCTAssertNil(keymap["D"])
        XCTAssertNil(keymap["E"])
        XCTAssertEqual(keymap["C"]?.0, "う")
        XCTAssertEqual(keymap["C"]?.1, "e")
    }
}
