import XCTest
import SwiftProtobuf

@testable import hazkey_server

final class LearningHistoryProtoRoundtripTests: XCTestCase {
    func testLearningHistoryRequestsRoundTrip() throws {
        let getRequest = Hazkey_Config_GetLearningHistory.with {
            $0.profileID = "p1"
            $0.query = "きょう"
            $0.offset = 40
            $0.limit = 200
        }

        let decodedGetRequest = try Hazkey_Config_GetLearningHistory(
            serializedBytes: getRequest.serializedData())

        XCTAssertEqual(decodedGetRequest.profileID, "p1")
        XCTAssertEqual(decodedGetRequest.query, "きょう")
        XCTAssertEqual(decodedGetRequest.offset, 40)
        XCTAssertEqual(decodedGetRequest.limit, 200)

        let deleteRequest = Hazkey_Config_DeleteLearningEntries.with {
            $0.profileID = "p1"
            $0.entries = [
                Hazkey_Config_LearningEntryKey.with {
                    $0.reading = "きょう"
                    $0.word = "今日"
                    $0.lcid = 1358
                    $0.rcid = 1359
                },
                Hazkey_Config_LearningEntryKey.with {
                    $0.reading = "あした"
                    $0.word = "明日"
                    $0.lcid = 1360
                    $0.rcid = 1361
                },
            ]
        }

        let decodedDeleteRequest = try Hazkey_Config_DeleteLearningEntries(
            serializedBytes: deleteRequest.serializedData())

        XCTAssertEqual(decodedDeleteRequest.profileID, "p1")
        XCTAssertEqual(decodedDeleteRequest.entries.count, 2)
        XCTAssertEqual(decodedDeleteRequest.entries[0].reading, "きょう")
        XCTAssertEqual(decodedDeleteRequest.entries[0].word, "今日")
        XCTAssertEqual(decodedDeleteRequest.entries[0].lcid, 1358)
        XCTAssertEqual(decodedDeleteRequest.entries[0].rcid, 1359)
        XCTAssertEqual(decodedDeleteRequest.entries[1].reading, "あした")
        XCTAssertEqual(decodedDeleteRequest.entries[1].word, "明日")
        XCTAssertEqual(decodedDeleteRequest.entries[1].lcid, 1360)
        XCTAssertEqual(decodedDeleteRequest.entries[1].rcid, 1361)
    }
}
