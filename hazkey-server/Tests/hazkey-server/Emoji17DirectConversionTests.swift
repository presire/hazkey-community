import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// Emoji 17.0直接変換のテスト範囲
///
/// 絵文字候補は一致した正規化済みクエリ長を保持し、prefixCompleteにより確定する
/// 未消費の接尾辞は学習せずに保持する
///
/// フィクスチャ (固定データ) 方針:
/// 全ての辞書URLは、setUpWithErrorで作成する一時ファイルとする
/// テストはシステムインストール先 (systemResourcePath/emoji_all_E17.0.txt) を読まない
/// 既定URLのテストは、ファイル名だけを確認し、内容は確認しない
final class Emoji17DirectConversionTests: XCTestCase {
    private let environmentVariables = [
        "XDG_DATA_HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR",
        "XDG_STATE_HOME",
        "HAZKEY_DICTIONARY",
    ]
    private var originalEnvironment: [String: String?] = [:]
    private var temporaryDirectory: URL?

    private enum SetupError: Error {
        case setFailed(String)
        case missingPath(String)
    }

    // E17限定の目印:
    // とろんぼーん -> trombone 🪊 は、emoji_all_E17.0.txtにあり、emoji_all_E16.0.txtにはない
    private static let sentinelReading = "とろんぼーん"
    private static let sentinelEmoji = "🪊"
    // 保持テスト用のZWJシーケンス (バレエダンサー) と VS16シーケンス (☺️)
    private static let zwjReading = "ばれえ"
    private static let zwjEmoji = "🧑‍🩰"
    private static let vs16Emoji = "☺️"

    override func setUpWithError() throws {
        let root = try TestTempRoot.make()
        for directory in ["data", "config", "cache", "runtime", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config/hazkey-community"), withIntermediateDirectories: true)

        let paths = [
            "XDG_DATA_HOME": "data",
            "XDG_CONFIG_HOME": "config",
            "XDG_CACHE_HOME": "cache",
            "XDG_RUNTIME_DIR": "runtime",
            "XDG_STATE_HOME": "state",
        ]
        for variable in environmentVariables {
            originalEnvironment[variable] = ProcessInfo.processInfo.environment[variable]
            if variable == "HAZKEY_DICTIONARY" {
                let dictionaryPath = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("azooKey_dictionary_storage/Dictionary", isDirectory: true)
                guard setenv(variable, dictionaryPath.path, 1) == 0 else {
                    throw SetupError.setFailed(variable)
                }
                continue
            }
            guard let directory = paths[variable] else {
                throw SetupError.missingPath(variable)
            }
            guard setenv(variable, root.appendingPathComponent(directory).path, 1) == 0 else {
                throw SetupError.setFailed(variable)
            }
        }
        temporaryDirectory = root
    }

    override func tearDownWithError() throws {
        for variable in environmentVariables {
            if let value = originalEnvironment[variable] ?? nil {
                setenv(variable, value, 1)
            } else {
                unsetenv(variable)
            }
        }
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    // MARK: - 固定データヘルパー (一時URLのみ)

    private func writeFixture(_ contents: String, named name: String = "emoji_fixture.txt") throws -> URL {
        let root = try XCTUnwrap(temporaryDirectory)
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func validFixtureURL() throws -> URL {
        // emoji_all_E*.txtと同じTSV形式: 絵文字TABカンマ区切りの読み
        let contents = [
            "\(Self.sentinelEmoji)\t\(Self.sentinelReading),とろんぼーんのえもじ\t",
            "\(Self.zwjEmoji)\t\(Self.zwjReading),ばれえだんさー\t",
            "\(Self.vs16Emoji)\tにっこりほほえみ\t",
        ].joined(separator: "\n") + "\n"
        return try writeFixture(contents)
    }

    private func makeState(fixtureURL: URL?, extendedEmoji: Bool = true) throws -> HazkeyServerState {
        let state = HazkeyServerState(emojiDictionaryURL: fixtureURL)
        state.serverConfig.currentProfile.zenzaiEnable = false
        state.serverConfig.currentProfile.specialConversionMode.extendedEmoji = extendedEmoji
        state.serverConfig.currentProfile.numCandidatesPerPage = 9
        state.serverConfig.currentProfile.numSuggestions = 9
        return state
    }

    private func candidateResult(
        forReading reading: String,
        isSuggest: Bool,
        fixtureURL: URL?,
        extendedEmoji: Bool = true
    ) throws -> Hazkey_Commands_CandidatesResult {
        let state = try makeState(fixtureURL: fixtureURL, extendedEmoji: extendedEmoji)
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let response = state.getCandidates(is_suggest: isSuggest)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return Hazkey_Commands_CandidatesResult()
        }
        return result
    }

    // MARK: - E17は通常変換のみ

    func testE17SentinelAppearsInNormalConversion() throws {
        // 前提: E17限定の目印の読みを含むE17固定データ
        let fixture = try validFixtureURL()

        // 実行: 目印の読みを通常変換する
        let result = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: false, fixtureURL: fixture)

        // 検証: E17絵文字が直接候補として現れる
        XCTAssertTrue(
            result.candidates.map(\.text).contains(Self.sentinelEmoji),
            "E17 sentinel emoji missing: \(result.candidates.map(\.text))")
    }

    func testE17SentinelAbsentInSuggestion() throws {
        // 前提: 同じE17固定データ
        let fixture = try validFixtureURL()

        // 実行: 目印の読みでサジェストを要求する
        let result = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: true, fixtureURL: fixture)

        // 検証: サジェストとライブ変換には絵文字候補が混入しない
        XCTAssertFalse(
            result.candidates.map(\.text).contains(Self.sentinelEmoji),
            "Emoji must not leak into suggestion results")
    }

    // MARK: - 有効・無効設定

    func testDisabledExtendedEmojiSuppressesCandidates() throws {
        // 前提: 有効な固定データだが、設定は明示的に無効
        let fixture = try validFixtureURL()

        // 実行: extendedEmoji = falseで変換する
        let result = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: false,
            fixtureURL: fixture, extendedEmoji: false)

        // 検証: 絵文字候補は注入されない
        XCTAssertFalse(
            result.candidates.map(\.text).contains(Self.sentinelEmoji))
    }

    // MARK: - 完全一致の重複除去

    func testExactDuplicateEmojiAppearsOnce() throws {
        // 前提: 同じ読みを同じ絵文字へ2回対応付ける固定データ
        //      読みはひらがなのみとする
        // TextReplacerは、生のクエリを索引化する一方、検索には"lowercased().toHiragana()"を使用するため、カタカナは一致しない
        // また、inputCharはASCIIをローマ字テーブル経由で処理するため、読み中のASCIIも"toHiragana()"で往復できない
        let contents = "✅\tぴよぴよえもじ\t\n✅\tぴよぴよえもじ\t\n"
        let fixture = try writeFixture(contents)

        // 実行: その読みを変換する
        let result = try candidateResult(
            forReading: "ぴよぴよえもじ", isSuggest: false, fixtureURL: fixture)

        // 検証: 完全文字列の重複除去により1件だけ残る
        XCTAssertEqual(result.candidates.map(\.text).filter { $0 == "✅" }.count, 1)
    }

    // MARK: - ZWJ / VS16の保持

    func testZWJSequencePreservedByteForByte() throws {
        // 前提: ZWJのバレエダンサーシーケンスを持つ固定データ
        let fixture = try validFixtureURL()

        // 実行: その読みを変換する
        let result = try candidateResult(
            forReading: Self.zwjReading, isSuggest: false, fixtureURL: fixture)

        // 検証: ZWJのバイト列は正規化されずに保持される
        let match = result.candidates.map(\.text).first { $0 == Self.zwjEmoji }
        XCTAssertNotNil(match, "ZWJ emoji missing: \(result.candidates.map(\.text))")
        XCTAssertTrue(match?.unicodeScalars.contains(Unicode.Scalar(0x200D)!) ?? false)
        XCTAssertEqual(match, Self.zwjEmoji)
    }

    func testVS16PreservedByteForByte() throws {
        // 前提: VS16シーケンスを持つ固定データ
        let fixture = try validFixtureURL()

        // 実行: その読みを変換する
        let result = try candidateResult(
            forReading: "にっこりほほえみ", isSuggest: false, fixtureURL: fixture)

        // 検証: 異体字セレクタは正規化されずに保持される
        let match = result.candidates.map(\.text).first { $0 == Self.vs16Emoji }
        XCTAssertNotNil(match, "VS16 emoji missing: \(result.candidates.map(\.text))")
        XCTAssertTrue(match?.unicodeScalars.contains(Unicode.Scalar(0xFE0F)!) ?? false)
        XCTAssertEqual(match, Self.vs16Emoji)
    }

    // MARK: - ライブテキストは不変

    func testLiveTextUnchangedByEmojiInjection() throws {
        // 前提: 絵文字を無効にした同じ読み (基準値)
        let fixture = try validFixtureURL()
        let baseline = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: false,
            fixtureURL: fixture, extendedEmoji: false)

        // 実行: 絵文字注入を有効にする
        let injected = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: false,
            fixtureURL: fixture, extendedEmoji: true)

        // 検証: 後処理でliveText / liveTextIndexは変更されない
        XCTAssertEqual(injected.liveText, baseline.liveText)
        XCTAssertEqual(injected.liveTextIndex, baseline.liveTextIndex)
    }

    // MARK: - 接頭辞確定

    func testPrefixCompletionClearsComposingForEmoji() throws {
        // 前提: 完全一致の読み (末尾接尾辞なし) に対する絵文字候補を持つ通常変換
        let state = try makeState(fixtureURL: validFixtureURL())
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in Self.sentinelReading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
        let index = try XCTUnwrap(state.currentCandidateList?.firstIndex(where: {
            if case .fromEmoji(let word, _) = $0 { return word == Self.sentinelEmoji }
            return false
        }))

        // 実行: 絵文字候補を接頭辞確定する
        XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)

        // 検証: 失敗や学習を起こさず、完全一致の読みを全て消費する (組成テキストは空になる)
        XCTAssertEqual(state.composingText.value.toHiragana(), "")
        XCTAssertFalse(state.learningDataNeedsCommit)
    }

    func testPrefixCompletionRetainsSuffixForEmoji() throws {
        // 前提: 絵文字の読みの後ろに接尾辞があり、カーソルは読みの末尾にあるため、要求は接頭辞だけを対象とする
        let suffix = "きょう"
        let fullReading = Self.sentinelReading + suffix
        let state = try makeState(fixtureURL: validFixtureURL())
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in fullReading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        XCTAssertEqual(state.moveCursor(offset: -suffix.count).status, .success)
        let response = state.getCandidates(is_suggest: false)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return
        }
        let index = try XCTUnwrap(state.currentCandidateList?.firstIndex(where: {
            if case .fromEmoji(let word, _) = $0 { return word == Self.sentinelEmoji }
            return false
        }))

        // 検証: 候補は未消費の接尾辞を残りのpreeditとして持つ
        XCTAssertEqual(result.candidates[index].subHiragana, suffix)

        // 実行: 絵文字候補を接頭辞確定する
        XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)

        // 検証: 一致した接頭辞だけを消費し、接尾辞はそのまま残り、学習は行われない
        XCTAssertEqual(state.composingText.value.toHiragana(), suffix)
        XCTAssertFalse(state.learningDataNeedsCommit)
    }

    // MARK: - 非学習動作

    func testEmojiCandidatesAreNotLearned() throws {
        // 前提: 一覧にある絵文字候補
        let state = try makeState(fixtureURL: validFixtureURL())
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in Self.sentinelReading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let response = state.getCandidates(is_suggest: false)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return
        }
        let index = try XCTUnwrap(state.currentCandidateList?.firstIndex(where: {
            if case .fromEmoji(let word, _) = $0 { return word == Self.sentinelEmoji }
            return false
        }))

        // 検証: 削除可能の注釈は付かない
        XCTAssertFalse(result.candidates[index].hasLearningEntry_p)

        // 実行: 絵文字を確定し、その学習データを削除する
        XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)
        XCTAssertFalse(state.learningDataNeedsCommit)
        let deleteResponse = state.deleteCandidateLearningData(candidateIndex: index)

        // 検証: 削除件数0を返す (converter由来ではないケース)
        XCTAssertEqual(deleteResponse.status, .success)
        XCTAssertEqual(deleteResponse.deleteCandidateLearningDataResult.deletedCount, 0)
    }

    // MARK: - 構築のキャッシュ

    func testEmojiProviderIsCachedAcrossRequests() throws {
        // 前提: 有効な固定データに紐付く状態
        let state = try makeState(fixtureURL: validFixtureURL())
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in Self.sentinelReading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }

        // 実行: 再組成せずに候補を2回要求する
        XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
        let first = try XCTUnwrap(state.emojiProvider)
        XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
        let second = try XCTUnwrap(state.emojiProvider)

        // 検証: キャッシュ済みproviderインスタンスを再利用する (リクエストごとのパースはない)
        XCTAssertTrue(first === second)
    }

    func testProviderSearchIsDirectAndUnchanged() throws {
        // 前提: 一時固定データから構築したprovider
        let fixture = try validFixtureURL()
        let provider = try XCTUnwrap(EmojiCandidateProvider(dictionaryURL: fixture))

        // 実行: 目印の読みを検索する
        let hits = provider.emojiCandidates(for: Self.sentinelReading)

        // 検証: 絵文字テキストは変更されず、一致した正規化済みクエリ長を接頭辞確定用に保持して返す
        let match = hits.first(where: { $0.text == Self.sentinelEmoji })
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.query.count, Self.sentinelReading.count)
    }

    // MARK: - 欠落・不正時のフォールバック

    func testMissingAssetFallsBackToNormalConversion() throws {
        // 前提: 存在しない辞書URL
        let root = try XCTUnwrap(temporaryDirectory)
        let missing = root.appendingPathComponent("does-not-exist.txt")

        // 実行: 欠落したアセットで変換する
        let result = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: false, fixtureURL: missing)

        // 検証: 絵文字を注入せず、通常変換は成功する
        XCTAssertFalse(result.candidates.map(\.text).contains(Self.sentinelEmoji))
    }

    func testMalformedAssetFallsBackToNormalConversion() throws {
        // 前提: 絵文字辞書として読み取れないfixture
        let fixture = try writeFixture("this is not\ta valid emoji file\u{0}\u{FF}\n")

        // 実行: 不正なアセットで変換する
        let provider = EmojiCandidateProvider(dictionaryURL: fixture)
        XCTAssertNil(provider)
        let result = try candidateResult(
            forReading: Self.sentinelReading, isSuggest: false, fixtureURL: fixture)

        // 検証: 絵文字を注入せず、通常変換は成功する
        XCTAssertFalse(result.candidates.map(\.text).contains(Self.sentinelEmoji))
    }

    func testDefaultDictionaryURLPointsAtE17Asset() {
        // 既定provider URLはE17アセットを指す
        // テストではシステムパスから内容を読まない
        XCTAssertEqual(
            EmojiCandidateProvider.defaultDictionaryURL.lastPathComponent,
            "emoji_all_E17.0.txt")
    }

    // MARK: - converter予測は無効のまま

    func testBaseConvertOptionsKeepTextReplacerEmpty() {
        // 直接注入は意図的なもの
        // converterの組成後予測は対象外に保つ
        // 空のreplacerは絵文字クエリに答えない (公開シーム。isEmpty自体は、converterパッケージ内にあり、@testableでも参照できない)
        let config = HazkeyServerConfig()
        let options = config.genBaseConvertRequestOptions()
        XCTAssertTrue(
            options.textReplacer.getSearchResult(query: Self.sentinelReading, target: [.emoji]).isEmpty,
            "ConvertRequestOptions.textReplacer must remain .empty")
    }
}
