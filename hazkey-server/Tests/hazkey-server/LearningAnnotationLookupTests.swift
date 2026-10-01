import Foundation
import Glibc
import KanaKanjiConverterModule
import SwiftProtobuf
import XCTest

@testable import hazkey_server

/// 「削除可能」候補注釈 (GitHub Issue #1) を支える読みキー単位のポイント照会と、同時に修正した隣接する学習メモリの正しさに関する2件のバグ
final class LearningAnnotationLookupTests: XCTestCase {
    /// 一時ディレクトリをXDGの設定・状態ディレクトリとして差し替えてテスト本体を実行する
    ///
    /// [XDG_CONFIG_HOME] と [XDG_STATE_HOME] を一時領域へ向ける
    /// 実行後は元の値を復元し、一時ディレクトリを削除する
    ///
    /// - Parameter body: 一時ルートURLを受け取り、テスト本体を実行するクロージャ
    /// - Returns: bodyが返した値
    /// - Throws: ディレクトリ作成やbodyが投げたエラー
    private func withTemporaryXDG<T>(_ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hazkey-annotation-lookup-tests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        let originalConfigDirectory = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let originalStateDirectory = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        setenv("XDG_CONFIG_HOME", configDirectory.path, 1)
        setenv("XDG_STATE_HOME", stateDirectory.path, 1)
        defer {
            if let originalConfigDirectory {
                setenv("XDG_CONFIG_HOME", originalConfigDirectory, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
            if let originalStateDirectory {
                setenv("XDG_STATE_HOME", originalStateDirectory, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
            try? FileManager.default.removeItem(at: root)
        }
        return try body(root)
    }

    /// リクエストをサーバのプロトコル処理へ通し、応答エンベロープを返す
    ///
    /// - Parameters:
    ///   - request: 送信するリクエストエンベロープ
    ///   - state: 処理を実行する接続セッション
    /// - Returns: サーバが返した応答エンベロープ
    /// - Throws: リクエストまたは応答のシリアライズに失敗した場合のエラー
    private func send(
        _ request: Hazkey_RequestEnvelope,
        to state: HazkeyServerState
    ) throws -> Hazkey_ResponseEnvelope {
        try Hazkey_ResponseEnvelope(
            serializedBytes: ProtocolHandler(state: state).processProto(data: request.serializedData()))
    }

    /// 学習メモリへ学習エントリを登録して永続化する
    ///
    /// 各要素を学習データとして取り込み、組成を停止してからコミットする
    ///
    /// - Parameters:
    ///   - elements: 登録する学習エントリ
    ///   - state: 学習メモリを共有する接続セッション
    private func seed(_ elements: [DicdataElement], in state: HazkeyServerState) {
        for element in elements {
            state.converter.updateLearningData(
                .init(
                    text: element.word,
                    value: element.value(),
                    composingCount: .inputCount(element.ruby.count),
                    lastMid: element.mid,
                    data: [element]))
            state.converter.stopComposition()
        }
        XCTAssertNoThrow(try state.converter.commitUpdateLearningData())
    }

    @discardableResult
    /// 指定した読みを1文字ずつ入力して候補取得を実行し、候補結果を返す
    ///
    /// 組成テキストを作り直してから、[getCandidates] を送信する
    ///
    /// - Parameters:
    ///   - hiragana: 入力するひらがな読み
    ///   - state: 入力と候補取得を行う接続セッション
    ///   - isSuggest: サジェストとして取得する場合はtrue、通常変換の場合はfalse
    /// - Returns: サーバが返した候補結果
    /// - Throws: 送信や応答の解析に失敗した場合のエラー
    private func candidates(
        for hiragana: String,
        in state: HazkeyServerState,
        isSuggest: Bool = false
    ) throws -> Hazkey_Commands_CandidatesResult {
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in hiragana {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let response = try send(
            .with {
                $0.getCandidates = Hazkey_Commands_GetCandidates.with { $0.isSuggest = isSuggest }
            },
            to: state)
        XCTAssertEqual(response.status, .success)
        return response.candidates
    }

    /// 候補結果から指定した表記の候補を探し、削除可能の注釈の有無を返す
    ///
    /// - Parameters:
    ///   - word: 探す候補の表記
    ///   - result: 候補結果
    /// - Returns: 該当候補の注釈 (見つからない場合はnil)
    private func annotated(_ word: String, in result: Hazkey_Commands_CandidatesResult) -> Bool? {
        result.candidates.first { $0.text == word }?.hasLearningEntry_p
    }

    /// 履歴をプロファイル独立にするテスト用プロファイルを作る
    ///
    /// [useProfileIndependentHistory] を有効にし、名前とIDに指定値を使う
    ///
    /// - Parameter id: プロファイルの名前とID
    /// - Returns: 既定設定を基にしたプロファイル
    private func profile(id: String) -> Hazkey_Config_Profile {
        var profile = HazkeyServerConfig.genDefaultConfig()
        profile.profileName = id
        profile.profileID = id
        profile.useProfileIndependentHistory = true
        return profile
    }

    /// 指定した順序のプロファイル一覧で設定を切り替える
    ///
    /// 一覧の先頭が現在のプロファイルになる
    ///
    /// - Parameters:
    ///   - profiles: 適用するプロファイル一覧
    ///   - state: 設定を適用する接続セッション
    /// - Throws: 送信や応答の解析に失敗した場合のエラー
    private func switchProfiles(
        _ profiles: [Hazkey_Config_Profile],
        in state: HazkeyServerState
    ) throws {
        let response = try send(
            .with { $0.setConfig = Hazkey_Config_SetConfig.with { $0.profiles = profiles } },
            to: state)
        XCTAssertEqual(response.status, .success)
    }

    /// 学習履歴の総件数を取得する
    ///
    /// - Parameter state: 履歴を照会する接続セッション
    /// - Returns: 学習履歴の総件数
    /// - Throws: 送信や応答の解析に失敗した場合のエラー
    private func historyCount(in state: HazkeyServerState) throws -> UInt32 {
        let response = try send(
            .with {
                $0.getLearningHistory = Hazkey_Config_GetLearningHistory.with {
                    $0.query = ""
                    $0.offset = 0
                    $0.limit = 200
                }
            }, to: state)
        XCTAssertEqual(response.status, .success)
        return response.getLearningHistoryResult.totalCount
    }

    /// emoji_all_E*.txtのTSV形式: 絵文字 TAB カンマ区切りのひらがな読み
    /// TABバリエーション
    private func writeEmojiFixture(_ contents: String, named name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// - Parameter emojiFixtureURL:
    ///   常にfixtureを渡す
    ///   nilは本番のE17アセットへフォールバックするが、ここには存在せず、このテストが依存する絵文字注入が無効になる
    private func annotationState(emojiFixtureURL: URL?) -> HazkeyServerState {
        let state = HazkeyServerState(emojiDictionaryURL: emojiFixtureURL)
        state.serverConfig.currentProfile.zenzaiEnable = false
        return state
    }

    /// 変換エンジン由来の候補だけが注釈の対象で、注入候補は未注釈であることを検証する
    ///
    /// wireの候補とサーバ側の候補リストが同数・同順であり、注入候補の表記が一致して注釈を持たないことを確認する
    ///
    /// - Parameters:
    ///   - result: クライアントへ返した候補結果
    ///   - state: サーバ側の候補リストを持つ接続セッション
    ///   - file: 失敗を報告するソースファイル
    ///   - line: 失敗を報告する行
    /// - Throws: サーバ側の候補リストが取得できない場合のエラー
    private func assertOnlyConverterCandidatesAreAnnotated(
        _ result: Hazkey_Commands_CandidatesResult,
        in state: HazkeyServerState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let displayed = try XCTUnwrap(state.currentCandidateList, file: file, line: line)
        XCTAssertEqual(result.candidates.count, displayed.count, file: file, line: line)
        for (index, entry) in displayed.enumerated() where index < result.candidates.count {
            let wire = result.candidates[index]
            switch entry {
            case .fromConverter(let candidate):
                XCTAssertEqual(wire.text, candidate.text, file: file, line: line)
            case .fromTypoCorrection(let candidate, _, _):
                XCTAssertEqual(wire.text, candidate.text, file: file, line: line)
            case .fromUserDict(let word):
                XCTAssertEqual(wire.text, word, file: file, line: line)
                XCTAssertFalse(wire.hasLearningEntry_p, file: file, line: line)
            case .fromDateProvider(let word, _):
                XCTAssertEqual(wire.text, word, file: file, line: line)
                XCTAssertFalse(wire.hasLearningEntry_p, file: file, line: line)
            case .fromKanaNumberProvider(let word, _):
                XCTAssertEqual(wire.text, word, file: file, line: line)
                XCTAssertFalse(wire.hasLearningEntry_p, file: file, line: line)
            case .fromEmoji(let word, _):
                XCTAssertEqual(wire.text, word, file: file, line: line)
                XCTAssertFalse(wire.hasLearningEntry_p, file: file, line: line)
            }
        }
    }

    /// サーバ側の候補リストから、述語に一致する候補の件数を数える
    ///
    /// - Parameters:
    ///   - state: 候補リストを持つ接続セッション
    ///   - predicate: 数える対象を判定する述語
    /// - Returns: 述語に一致した候補の件数
    private func injectionCount(
        in state: HazkeyServerState,
        matching predicate: (DisplayedCandidate) -> Bool
    ) -> Int {
        (state.currentCandidateList ?? []).count(where: predicate)
    }

    // MARK: - R1: 学習済み予測候補

    /// 予測候補の永続エントリは予測部分まで含む完全rubyの下に保存されるため、
    /// 入力prefixに切り詰めた読みでは注釈も削除も当たらない
    func testLearnedPredictionCandidateIsAnnotatedAndDeletable() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            state.serverConfig.currentProfile.zenzaiEnable = false

            let reading = "きょう"
            try candidates(for: reading, in: state, isSuggest: true)
            let displayed = try XCTUnwrap(state.currentCandidateList)
            let target = try XCTUnwrap(
                displayed.compactMap { entry -> (text: String, ruby: String)? in
                    guard case .fromConverter(let candidate) = entry, !candidate.data.isEmpty else {
                        return nil
                    }
                    let fullRuby = candidate.data.map(\.ruby).joined()
                    guard fullRuby.count > reading.count else { return nil }
                    return (candidate.text, fullRuby)
                }.first)

            seed(
                [.init(word: target.text, ruby: target.ruby, lcid: 10, rcid: 11, mid: 1, value: -5)],
                in: state)

            let result = try candidates(for: reading, in: state, isSuggest: true)
            let index = try XCTUnwrap(result.candidates.firstIndex { $0.text == target.text })
            XCTAssertTrue(result.candidates[index].hasLearningEntry_p)

            let response = try send(
                .with {
                    $0.deleteCandidateLearningData = Hazkey_Commands_DeleteCandidateLearningData
                        .with { $0.index = Int32(index) }
                }, to: state)
            XCTAssertEqual(response.status, .success)
            XCTAssertGreaterThan(response.deleteCandidateLearningDataResult.deletedCount, 0)

            let requeried = try candidates(for: reading, in: state, isSuggest: true)
            XCTAssertEqual(
                requeried.candidates.first { $0.text == target.text }?.hasLearningEntry_p ?? false,
                false)
        }
    }

    // MARK: - ポイント照会の意味論

    /// 永続trieは、カタカナrubyを保存するため、ひらがな読みとの突き合わせはカタカナ正規化を経由しなければならない
    func testPersistedTrieStoresKatakanaRubyAndAnnotatesHiraganaReading() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)

            let entries = try state.listLearningEntries(query: "", offset: 0, limit: 10).entries
            XCTAssertEqual(entries.map(\.reading), ["キョウ"])

            let result = try candidates(for: "きょう", in: state)
            XCTAssertEqual(annotated("今日", in: result), true)
            XCTAssertTrue(result.candidates.contains { !$0.hasLearningEntry_p })
        }
    }

    /// 注釈は、列挙API (全走査) ではなくポイント照会で解決される
    /// 列挙はmemory.memorymetadataを必ず読むが、ポイント照会はLOUDSと該当シャードしか読まないため、
    /// metadataを消すと履歴は空になり注釈だけが残る
    /// 全走査方式へ戻すと最後のアサートが落ちる
    func testPointLookupDoesNotDependOnEnumerationMetadata() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)

            XCTAssertGreaterThan(try historyCount(in: state), 0)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), true)

            let metadataURL = state.serverConfig.memoryDirectory()
                .appendingPathComponent("memory.memorymetadata", isDirectory: false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
            try FileManager.default.removeItem(at: metadataURL)

            XCTAssertEqual(try historyCount(in: state), 0)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), true)
        }
    }

    // MARK: - 注入候補との整列

    /// 注釈は絵文字・相対日付・かな数字の注入より前に確定する
    /// 相対日付は候補列の中間にinsertするため、注入が先に走ると以降の候補が別の読みで判定される
    func testInjectedCandidatesDoNotDisturbAnnotationAlignment() throws {
        try withTemporaryXDG { root in
            let fixture = try writeEmojiFixture(
                "🌞\tきょう,きょうのひ\t\n", named: "emoji_fixture.txt", in: root)
            let state = annotationState(emojiFixtureURL: fixture)
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)

            let result = try candidates(for: "きょう", in: state)

            XCTAssertGreaterThan(
                injectionCount(in: state) { if case .fromDateProvider = $0 { return true } else { return false } },
                0)
            XCTAssertGreaterThan(
                injectionCount(in: state) { if case .fromEmoji = $0 { return true } else { return false } },
                0)
            XCTAssertEqual(annotated("今日", in: result), true)
            try assertOnlyConverterCandidatesAreAnnotated(result, in: state)
        }
    }

    /// かな数字の注入が注釈の整列を崩さないことを検証する
    ///
    /// 漢数字由来の候補が注入されても、変換エンジン由来の候補は注釈の位置を保つ
    func testKanaNumberInjectionDoesNotDisturbAnnotationAlignment() throws {
        try withTemporaryXDG { root in
            let fixture = try writeEmojiFixture(
                "🔟\tじゅう\t\n", named: "emoji_fixture.txt", in: root)
            let state = annotationState(emojiFixtureURL: fixture)

            let result = try candidates(for: "じゅう", in: state)

            XCTAssertTrue(result.candidates.contains { $0.text == "10" })
            let generated = Set(KanaNumberProvider.generateCandidates(forDecimalDigits: "10"))
            XCTAssertFalse(generated.isEmpty)
            XCTAssertGreaterThan(
                injectionCount(in: state) { entry in
                    guard case .fromKanaNumberProvider(let word, _) = entry else { return false }
                    return generated.contains(word)
                },
                0)
            try assertOnlyConverterCandidatesAreAnnotated(result, in: state)
        }
    }

    // MARK: - 削除の往復確認

    /// [削除可]と表示された候補は実際に削除でき、削除後に取り直した候補では注釈が消える
    /// 既存の削除テストは応答に載る再構築済みペイロードまでしか見ないので、再照会の経路はここでしか固定されない
    func testAnnotatedCandidateDeleteRoundTripRemovesAnnotationOnRequery() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)

            let result = try candidates(for: "きょう", in: state)
            let index = try XCTUnwrap(result.candidates.firstIndex { $0.text == "今日" })
            XCTAssertTrue(result.candidates[index].hasLearningEntry_p)

            let response = try send(
                .with {
                    $0.deleteCandidateLearningData = Hazkey_Commands_DeleteCandidateLearningData
                        .with { $0.index = Int32(index) }
                }, to: state)

            XCTAssertEqual(response.status, .success)
            XCTAssertGreaterThan(response.deleteCandidateLearningDataResult.deletedCount, 0)
            XCTAssertEqual(try historyCount(in: state), 0)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), false)
        }
    }

    /// 学習していない読みの候補には注釈が付かないことを検証する
    ///
    /// 履歴が空の状態で取得した候補は、いずれも未注釈である
    func testUnlearnedReadingIsNeverAnnotated() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()

            let result = try candidates(for: "きょう", in: state)
            XCTAssertFalse(result.candidates.isEmpty)
            XCTAssertTrue(result.candidates.allSatisfy { !$0.hasLearningEntry_p })
        }
    }

    /// .pauseがある間はスナップショットが不整合なので、注釈は付けずに縮退する (候補取得自体は成功させる)
    func testPausedSnapshotLeavesCandidatesUnannotated() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), true)

            let pauseURL = state.serverConfig.memoryDirectory()
                .appendingPathComponent(".pause", isDirectory: false)
            XCTAssertTrue(FileManager.default.createFile(atPath: pauseURL.path, contents: Data()))
            defer { try? FileManager.default.removeItem(at: pauseURL) }

            let result = try candidates(for: "きょう", in: state)
            XCTAssertFalse(result.candidates.isEmpty)
            XCTAssertTrue(result.candidates.allSatisfy { !$0.hasLearningEntry_p })
        }
    }

    /// .pause以外の照会失敗 (破損シャード) でも、候補取得そのものは成功し、全候補が未注釈へ縮退する
    /// 実シャードをゴミで壊すと、変換経路が境界検証のないparseへ到達し得るため、照会シームにmalformedShardを注入する
    func testCorruptedShardLeavesCandidatesUnannotated() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), true)

            state.shared.learningSurfaceKeyLookup = { _ in
                throw LearningMemoryEnumerationError.malformedShard
            }
            defer { state.shared.learningSurfaceKeyLookup = nil }

            let result = try candidates(for: "きょう", in: state)
            XCTAssertFalse(result.candidates.isEmpty)
            XCTAssertTrue(result.candidates.allSatisfy { !$0.hasLearningEntry_p })
        }
    }

    /// 共有リソースを使う複数セッションが同じ注釈を観測することを検証する
    ///
    /// 一方のセッションで学習したエントリは、他方のセッションの候補にも同じように注釈される
    func testConcurrentSessionsObserveConsistentAnnotations() throws {
        try withTemporaryXDG { _ in
            let shared = HazkeySharedResources()
            let first = HazkeyServerState(shared: shared)
            let second = HazkeyServerState(shared: shared)
            defer {
                first.close()
                second.close()
            }
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: first)

            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: first)), true)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: second)), true)
        }
    }

    // MARK: - バグD: プロファイル切替時のmemory LOUDSキャッシュ無効化

    /// プロファイル切替直後の注釈は、切替後プロファイルのmemoryディレクトリを反映する
    /// バグD未修正だと旧プロファイルのキャッシュ済みtrieで解決してしまう
    func testAnnotationFollowsProfileMemoryDirectoryAfterSwitch() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            let profileA = profile(id: "A")
            let profileB = profile(id: "B")

            try switchProfiles([profileA, profileB], in: state)
            try candidates(for: "きょう", in: state)
            seed([.init(word: "今日", ruby: "キョウ", lcid: 10, rcid: 11, mid: 1, value: -5)], in: state)

            try switchProfiles([profileB, profileA], in: state)
            try candidates(for: "きょう", in: state)
            seed([.init(word: "鏡", ruby: "カガミ", lcid: 12, rcid: 13, mid: 1, value: -5)], in: state)

            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), false)
            XCTAssertEqual(annotated("鏡", in: try candidates(for: "かがみ", in: state)), true)

            try switchProfiles([profileA, profileB], in: state)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), true)
            XCTAssertEqual(annotated("鏡", in: try candidates(for: "かがみ", in: state)), false)
        }
    }

    // MARK: - バグB: 履歴を消去した後に復活するものがあってはならない

    /// プロファイル独立履歴を消去した後に候補が復活しないことを検証する
    ///
    /// 確定で作った未永続化の学習は消去でdirtyフラグごと落ち、保存後も履歴と注釈が残らない
    func testClearProfileIndependentHistoryLeavesNothingToResurrect() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            try switchProfiles([profile(id: "A")], in: state)
            try candidates(for: "きょう", in: state)

            let result = try candidates(for: "きょう", in: state)
            let index = try XCTUnwrap(result.candidates.firstIndex { $0.text == "今日" })
            XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)
            XCTAssertTrue(state.learningDataNeedsCommit)

            XCTAssertEqual(state.clearProfileLearningData().status, .success)
            XCTAssertFalse(state.learningDataNeedsCommit)

            XCTAssertEqual(try send(.with { $0.saveLearningData = Hazkey_Commands_SaveLearningData() }, to: state).status, .success)
            XCTAssertEqual(try historyCount(in: state), 0)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), false)
        }
    }

    // MARK: - バグC: 保留中の学習がプロファイル切替をまたいで漏れてはならない

    /// 保留中の学習が別プロファイルのディレクトリへ漏れないことを検証する
    ///
    /// 切替をまたいだ未永続化の学習は切替先へ持ち越されず、切替元へ戻すと再び観測できる
    func testPendingLearningDoesNotLeakIntoNewProfileDirectory() throws {
        try withTemporaryXDG { _ in
            let state = HazkeyServerState()
            let profileA = profile(id: "A")
            let profileB = profile(id: "B")
            try switchProfiles([profileA, profileB], in: state)
            try candidates(for: "きょう", in: state)

            let result = try candidates(for: "きょう", in: state)
            let index = try XCTUnwrap(result.candidates.firstIndex { $0.text == "今日" })
            XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)
            XCTAssertTrue(state.learningDataNeedsCommit)

            try switchProfiles([profileB, profileA], in: state)
            XCTAssertEqual(try send(.with { $0.saveLearningData = Hazkey_Commands_SaveLearningData() }, to: state).status, .success)

            XCTAssertEqual(try historyCount(in: state), 0)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), false)

            try switchProfiles([profileA, profileB], in: state)
            XCTAssertGreaterThan(try historyCount(in: state), 0)
            XCTAssertEqual(annotated("今日", in: try candidates(for: "きょう", in: state)), true)
        }
    }
}
