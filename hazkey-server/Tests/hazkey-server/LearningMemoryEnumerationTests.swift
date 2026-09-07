import Foundation
import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

final class LearningMemoryEnumerationTests: XCTestCase {
    private func makeConverter() throws -> (converter: KanaKanjiConverter, memoryURL: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-learning-memory-tests-\(UUID().uuidString)", isDirectory: true)
        let memoryURL = root.appendingPathComponent("memory", isDirectory: true)
        let sharedURL = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let converter = KanaKanjiConverter(
            dictionaryURL: URL(fileURLWithPath: systemResourcePath)
                .appendingPathComponent("Dictionary", isDirectory: true))
        let options = ConvertRequestOptions(
            N_best: 1,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .none,
            learningType: .inputAndOutput,
            maxMemoryCount: 64,
            memoryDirectoryURL: memoryURL,
            sharedContainerURL: sharedURL,
            textReplacer: .empty,
            specialCandidateProviders: [],
            zenzaiMode: .off,
            typoCorrectionMode: .disabled,
            metadata: nil
        )
        let composingText = ComposingText(
            convertTargetCursorPosition: 1,
            input: [.init(character: "ア", inputStyle: .direct)],
            convertTarget: "ア"
        )
        _ = converter.requestCandidates(composingText, options: options)
        return (converter, memoryURL)
    }

    private func seed(_ elements: [DicdataElement], in converter: KanaKanjiConverter) {
        for element in elements {
            converter.updateLearningData(
                .init(
                    text: element.word,
                    value: element.value(),
                    composingCount: .inputCount(1),
                    lastMid: element.mid,
                    data: [element]
                )
            )
            converter.stopComposition()
        }
        converter.commitUpdateLearningData()
    }

    func testEntriesReturnPersistedRowsAndPagination() throws {
        let (converter, _) = try makeConverter()
        let elements = [
            DicdataElement(word: "亜", ruby: "ア", lcid: 10, rcid: 11, mid: 1, value: -5),
            DicdataElement(word: "伊", ruby: "イ", lcid: 12, rcid: 13, mid: 1, value: -5),
            DicdataElement(word: "宇", ruby: "ウ", lcid: 14, rcid: 15, mid: 1, value: -5),
        ]

        seed(elements, in: converter)

        let firstPage = try converter.learningMemoryEntries(limit: 2)

        XCTAssertEqual(firstPage.totalCount, 3)
        XCTAssertEqual(firstPage.entries.count, 2)
        XCTAssertEqual(firstPage.nextOffset, 2)
        XCTAssertEqual(
            Set(firstPage.entries.map { "\($0.data.ruby)|\($0.data.word)" }),
            Set(["\(elements[0].ruby)|\(elements[0].word)", "\(elements[1].ruby)|\(elements[1].word)"])
        )
        XCTAssertTrue(firstPage.entries.allSatisfy { $0.count == 1 && $0.lastUsed <= Date() })

        let secondPage = try converter.learningMemoryEntries(offset: 2, limit: 2)

        XCTAssertEqual(secondPage.totalCount, 3)
        XCTAssertEqual(secondPage.entries.map(\.data.word), ["宇"])
        XCTAssertNil(secondPage.nextOffset)
    }

    func testForgetLearningMemoryRemovesOnlyRequestedEntry() throws {
        let (converter, _) = try makeConverter()
        let target = DicdataElement(word: "亜", ruby: "ア", lcid: 10, rcid: 11, mid: 1, value: -5)
        let survivor = DicdataElement(word: "伊", ruby: "イ", lcid: 12, rcid: 13, mid: 1, value: -5)
        seed([target, survivor], in: converter)

        try converter.forgetLearningMemory(
            reading: target.ruby,
            word: target.word,
            lcid: target.lcid,
            rcid: target.rcid
        )

        let page = try converter.learningMemoryEntries()

        XCTAssertEqual(page.totalCount, 1)
        XCTAssertEqual(page.entries.map(\.data.word), [survivor.word])
    }

    func testForgetLearningMemoryMatchesReadingWordAndCIDsExactly() throws {
        let (converter, _) = try makeConverter()
        let target = DicdataElement(word: "同", ruby: "ア", lcid: 10, rcid: 11, mid: 1, value: -5)
        let sameWord = DicdataElement(word: "同", ruby: "イ", lcid: 10, rcid: 11, mid: 1, value: -5)
        let sameReadingAndWord = DicdataElement(word: "同", ruby: "ア", lcid: 12, rcid: 13, mid: 1, value: -5)
        seed([target, sameWord, sameReadingAndWord], in: converter)

        try converter.forgetLearningMemory(
            reading: target.ruby,
            word: target.word,
            lcid: target.lcid,
            rcid: target.rcid
        )

        let remaining = try converter.learningMemoryEntries().entries.map(\.data)

        XCTAssertEqual(remaining.count, 2)
        XCTAssertFalse(remaining.contains { $0.ruby == target.ruby && $0.word == target.word && $0.lcid == target.lcid && $0.rcid == target.rcid })
        XCTAssertTrue(remaining.contains { $0.ruby == sameWord.ruby && $0.word == sameWord.word && $0.lcid == sameWord.lcid && $0.rcid == sameWord.rcid })
        XCTAssertTrue(remaining.contains { $0.ruby == sameReadingAndWord.ruby && $0.word == sameReadingAndWord.word && $0.lcid == sameReadingAndWord.lcid && $0.rcid == sameReadingAndWord.rcid })
    }

    func testEntriesReturnEmptyPageForEmptyDirectory() throws {
        let (converter, _) = try makeConverter()

        let page = try converter.learningMemoryEntries()

        XCTAssertEqual(page.entries.count, 0)
        XCTAssertEqual(page.totalCount, 0)
        XCTAssertNil(page.nextOffset)
    }

    func testEntriesThrowPausedSnapshotError() throws {
        let (converter, memoryURL) = try makeConverter()
        try Data().write(to: memoryURL.appendingPathComponent(".pause"))

        XCTAssertThrowsError(try converter.learningMemoryEntries()) { error in
            XCTAssertEqual(error as? LearningMemoryEnumerationError, .pausedSnapshot)
        }
    }
}
