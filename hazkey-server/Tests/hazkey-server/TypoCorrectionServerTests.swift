import Foundation
import Glibc
import XCTest

@testable import hazkey_server

/// 実サーバ状態を通してタイポ訂正候補を端から端まで検証する統合テスト
///
/// 実際のHazkeyServerStateに対してローマ字かな入力を1文字ずつ投入し、訂正候補のフラグ付け・打鍵時の時間予算・学習と削除・訂正用セッションの確保・preeditとライブ変換の安定性を確認する
final class TypoCorrectionServerTests: XCTestCase {
    /// 各テストの前後で退避と復元を行う環境変数の名前
    ///
    /// XDGの各ディレクトリと辞書パスを一時ディレクトリへ差し替えて、実ユーザの設定や学習データに触れないようにする
    private let environmentVariables = [
        "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR",
        "XDG_STATE_HOME", "HAZKEY_DICTIONARY", "HAZKEY_ADDRESS_DICTIONARY",
        "HAZKEY_ENGINEERING_DICTIONARY",
    ]
    /// テスト開始前の環境変数の値
    ///
    /// nilは未設定だったことを表し、tearDownでunsetenvを選ぶ判断に使う
    private var originalEnvironment: [String: String?] = [:]
    /// 環境変数が指す一時ルートディレクトリ
    ///
    /// tearDownで配下ごと削除するために保持する
    private var temporaryDirectory: URL?

    /// テストごとに環境変数を一時ルートへ差し替える
    ///
    /// 一時ルートの下にdata / config / cache / runtime / stateとhazkey-community設定ディレクトリを作り、辞書はリポジトリ内のazooKey_dictionary_storageを指す
    ///
    /// - Throws: ディレクトリの作成またはsetenvに失敗した場合
    override func setUpWithError() throws {
        let root = try TestTempRoot.make()
        for name in ["data", "config", "cache", "runtime", "state"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("config/hazkey-community"), withIntermediateDirectories: true)
        let dictionary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("azooKey_dictionary_storage/Dictionary", isDirectory: true)
        let overrides = [
            "XDG_DATA_HOME": root.appendingPathComponent("data").path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("runtime").path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "HAZKEY_DICTIONARY": dictionary.path,
            "HAZKEY_ADDRESS_DICTIONARY": "/nonexistent/hazkey-address-dictionary",
            "HAZKEY_ENGINEERING_DICTIONARY": "/nonexistent/hazkey-engineering-dictionary",
        ]
        for variable in environmentVariables {
            originalEnvironment[variable] = ProcessInfo.processInfo.environment[variable]
            guard let value = overrides[variable], setenv(variable, value, 1) == 0 else {
                throw NSError(domain: "TypoCorrectionServerTests", code: 1)
            }
        }
        temporaryDirectory = root
    }

    /// テストごとに変更した環境変数を元の値へ戻し、一時ルートを削除する
    ///
    /// - Throws: 現状は送出しないが、XCTestのtearDown契約に合わせてthrowsを維持する
    override func tearDownWithError() throws {
        for variable in environmentVariables {
            if let value = originalEnvironment[variable] ?? nil {
                setenv(variable, value, 1)
            } else {
                unsetenv(variable)
            }
        }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    /// 指定した読みを入力済みの実サーバ状態を作り、タイポ訂正の設定を適用する
    ///
    /// 実ハズキーサーバの状態機械を通して1文字ずつ入力し、最後に通常変換を1回実行してエンジンを温める
    ///
    /// - Parameters:
    ///   - reading: ローマ字かな入力として1文字ずつ投入する読み
    ///   - enabled: [use_typo_correction] を有効にするかどうか
    /// - Returns: 入力済みで通常変換を1回済ませた状態
    /// - Throws: createComposingTextInstanseまたはinputCharが失敗した場合
    private func state(reading: String, enabled: Bool = true) throws -> HazkeyServerState {
        let state = HazkeyServerState(emojiDictionaryURL: nil)
        state.serverConfig.currentProfile.zenzaiEnable = false
        state.serverConfig.currentProfile.useTypoCorrection = enabled
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in reading {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        // エンジンの最初の冷えた変換はタイポの時間予算を超えることがある
        // そのため、以下の検証で実際の挙動を測る前に温めておく
        XCTAssertEqual(state.getCandidates(is_suggest: false).status, .success)
        return state
    }

    /// 指定したモードで候補を生成し、候補結果を取り出す
    ///
    /// 応答がsuccessでcandidatesペイロードを持つことを検証し、持たない場合はテストを失敗させる
    ///
    /// - Parameters:
    ///   - state: 候補を生成する実サーバ状態
    ///   - suggest: サジェストならtrue、通常変換ならfalse
    /// - Returns: クライアント向けの候補結果
    /// - Throws: 応答ペイロードがcandidatesでない場合はXCTFailで失敗する
    private func candidates(_ state: HazkeyServerState, suggest: Bool) throws -> Hazkey_Commands_CandidatesResult {
        let response = state.getCandidates(is_suggest: suggest)
        XCTAssertEqual(response.status, .success)
        guard case .candidates(let result)? = response.payload else {
            XCTFail("Expected candidates response")
            return .init()
        }
        return result
    }

    /// 最初のタイポ訂正候補の位置を返す
    ///
    /// 見つからない場合は呼び出し元のファイルと行を添えてテストを失敗させる
    ///
    /// - Parameters:
    ///   - result: 検索対象の候補結果
    ///   - file: 失敗を報告するファイル
    ///   - line: 失敗を報告する行
    /// - Returns: isTypoCorrectionが真である最初の候補の位置
    private func correctionIndex(
        _ result: Hazkey_Commands_CandidatesResult, file: StaticString = #filePath, line: UInt = #line
    ) -> Int? {
        guard let index = result.candidates.firstIndex(where: \.isTypoCorrection) else {
            XCTFail("No typo correction candidate: \(result.candidates.map(\.text))", file: file, line: line)
            return nil
        }
        return index
    }

    /// 別の接続で読みを入力し、指定した表記の候補を確定して学習させる
    ///
    /// 学習は接続間で共有されるため、呼び出し元の接続の変換セッションに触れずに学習だけを加えられる
    ///
    /// - Parameters:
    ///   - word: 確定する候補の表記
    ///   - romaji: 入力するローマ字
    ///   - shared: 学習を加える共有リソース
    /// - Throws: 指定した表記の候補が無い場合はXCTUnwrapで失敗する
    private func learn(_ word: String, romaji: String, shared: HazkeySharedResources) throws {
        let learner = HazkeyServerState(shared: shared)
        defer { learner.close() }
        XCTAssertEqual(learner.createComposingTextInstanse().status, .success)
        for character in romaji {
            XCTAssertEqual(learner.inputChar(inputString: String(character)).status, .success)
        }
        let result = try candidates(learner, suggest: false)
        let index = try XCTUnwrap(
            result.candidates.firstIndex { $0.text == word && $0.subHiragana.isEmpty },
            "\(result.candidates.map(\.text))")
        XCTAssertEqual(learner.completePrefix(candidateIndex: index).status, .success)
    }

    /// タイポ訂正候補がサジェストと通常変換の両モードで最良候補の直後に並ぶことを検証する
    ///
    /// 訂正された全体読みの変換が、フラグ付きの2番目の候補として提示されること
    func testCorrectionCandidateFollowsBestCandidateInSuggestAndNormalModes() throws {
        // Given: 実際のローマ字かなマッピング入力に対してタイポ訂正を有効にする
        let state = try state(reading: "shipppaishita")
        defer { state.close() }

        // When: 利用者に見える両モードでサーバの候補を要求する
        for suggest in [true, false] {
            let result = try candidates(state, suggest: suggest)

            // Then: 訂正された全体読みの変換が、フラグ付きの2番目の候補になる
            let index = try XCTUnwrap(correctionIndex(result))
            XCTAssertEqual(index, 1)
            XCTAssertEqual(result.candidates[index].text, "失敗した")
            XCTAssertTrue(result.candidates[index].isTypoCorrection)
        }
    }

    /// 必須のタイポ形状ごとに、最高スコアの訂正が提示されることを検証する
    ///
    /// 通過した最初の案ではなく、スコアが最も高い訂正が選ばれること
    func testBestScoringCorrectionIsOfferedForEachRequiredTypo() throws {
        let cases = [
            ("shippppai", "失敗"), ("su--pa-", "スーパー"), ("su-----pa-", "スーパー"),
            ("arigtou", "ありがとう"), ("argatou", "ありがとう"),
        ]
        for (romaji, expected) in cases {
            // Given: 必須のタイポ形状を1つ含む組成
            let state = try state(reading: romaji)
            defer { state.close() }

            // When: 通常変換の候補を要求する
            let result = try candidates(state, suggest: false)

            // Then: 通過した最初の案ではなく、最高スコアの訂正が提示される
            let index = try XCTUnwrap(correctionIndex(result), romaji)
            XCTAssertEqual(result.candidates[index].text, expected, romaji)
        }
    }

    /// 先頭のローマ字に対して、通過する母音補完が全て提示されることを検証する
    ///
    /// 最高スコアの1件だけでなく、意図になり得る読みが全てフラグ付き訂正として並ぶこと
    func testLeadingRomajiOffersEveryPassingVowelInsertion() throws {
        let cases = [("mchigai", "間違い"), ("mchigaeru", "見違える"), ("mchigaeru", "間違える")]
        for (romaji, expected) in cases {
            // Given: 先頭の子音の後の母音が抜けている
            let state = try state(reading: romaji)
            defer { state.close() }

            // When: 通常変換の候補を要求する
            let result = try candidates(state, suggest: false)

            // Then: 意図した読みが、最高スコアの1件だけでなくフラグ付き訂正として提示される
            let corrections = result.candidates.filter(\.isTypoCorrection).map(\.text)
            XCTAssertTrue(corrections.contains(expected), "\(romaji): \(corrections)")
            XCTAssertEqual(try XCTUnwrap(correctionIndex(result)), 1, romaji)
        }
    }

    /// かな間で抜けた母音が、入力中と文節境界調整の両方で訂正されることを検証する
    ///
    /// 末尾の通常の助詞は未変換のまま残し、訂正は最大3件に収まること
    func testSkippedVowelBetweenKanaIsCorrectedInInputAndBoundaryAdjustment() throws {
        // Given: machigaeruでtの後の母音が抜け、その後に通常の助詞が続く
        let typing = try state(reading: "matgaeru")
        defer { typing.close() }

        // When: 入力中と通常変換で候補を要求する
        for suggest in [true, false] {
            let result = try candidates(typing, suggest: suggest)

            // Then: 意図した読みがフラグ付き訂正として提示され、訂正は最大3件に収まる
            let corrections = result.candidates.filter(\.isTypoCorrection).map(\.text)
            XCTAssertTrue(corrections.contains("間違える"), "suggest=\(suggest): \(corrections)")
            XCTAssertLessThanOrEqual(corrections.count, TypoCorrector.maxVariants)
        }

        // When: 入力中にShift+Left / Shift+Rightで境界を動かす
        let withSuffix = try state(reading: "matgaeruneko")
        defer { withSuffix.close() }
        let movedLeft = withSuffix.adjustClauseBoundary(offset: -2).clauseBoundaryResult.candidates
        let movedRight = withSuffix.adjustClauseBoundary(offset: 1).clauseBoundaryResult.candidates

        // Then: 接頭辞の訂正が提示され、接尾辞は未変換のまま残る
        let correction = try XCTUnwrap(
            movedLeft.candidates.first { $0.isTypoCorrection && $0.text == "間違える" },
            "\(movedLeft.candidates.map(\.text))")
        XCTAssertEqual(correction.subHiragana, "ねこ")
        XCTAssertTrue(movedRight.candidates.contains(where: \.isTypoCorrection))
    }

    /// 文節境界調整が打鍵時の時間予算を無視することを検証する
    ///
    /// 予算超過で主変換から訂正が消えていても、境界を動かした接頭辞では訂正が提示されること
    func testClauseBoundaryAdjustmentIgnoresTheTypingTimeBudget() throws {
        // Given: 新しい接頭辞をニューラル変換する場合のように、全ての主変換が時間予算を超え、訂正案の評価に使える時間も無い
        let state = try state(reading: "mchigaeruneko")
        defer { state.close() }
        state.typoTimeBudget = .zero
        state.typoEvaluationBudget = .zero
        XCTAssertFalse(try candidates(state, suggest: false).candidates.contains(where: \.isTypoCorrection))

        // When: Shift+Leftで境界をタイポ接頭辞の末尾まで動かす
        let moved = state.adjustClauseBoundary(offset: -2)
        XCTAssertEqual(moved.status, .success)
        let result = moved.clauseBoundaryResult.candidates

        // Then: 接頭辞の訂正は提示され、接尾辞は未変換のまま残る
        let correction = try XCTUnwrap(
            result.candidates.first { $0.isTypoCorrection && $0.text == "見違える" },
            "\(result.candidates.map(\.text))")
        XCTAssertEqual(correction.subHiragana, "ねこ")
        XCTAssertEqual(moved.clauseBoundaryResult.hiragana, "mちがえるねこ")

        // When: Shift+Rightで境界を1文字分だけ戻す
        let movedRight = state.adjustClauseBoundary(offset: 1)

        // Then: 新しい接頭辞でも予算は再び無視される
        XCTAssertTrue(movedRight.clauseBoundaryResult.candidates.candidates.contains(where: \.isTypoCorrection))
    }

    /// 訂正候補が組成テキストとライブ変換の表記を書き換えないことを検証する
    ///
    /// 入力文字列・構造的なpreedit・ライブ変換は、訂正OFFの基準状態と一致したままであること
    func testCorrectionCandidateDoesNotRewritePreeditOrLiveText() throws {
        // Given: 組成にタイポが存在する
        let state = try state(reading: "shipppaishita")
        let baseline = try self.state(reading: "shipppaishita", enabled: false)
        defer { state.close() }
        defer { baseline.close() }

        // When: タイポ候補をサジェストとして生成する
        let result = try candidates(state, suggest: true)
        let baselineResult = try candidates(baseline, suggest: true)

        // Then: 入力文字列・構造的なpreedit・ライブ変換は元のまま残る
        XCTAssertEqual(result.candidates[try XCTUnwrap(correctionIndex(result))].text, "失敗した")
        XCTAssertEqual(state.composingText.value.convertTarget.toHiragana(), "しっっぱいした")
        let cursorText = state.getHiraganaWithCursor().textWithCursor
        XCTAssertEqual(cursorText.beforeCursosr + cursorText.onCursor + cursorText.afterCursor, "しっっぱいした")
        XCTAssertEqual(result.liveText, baselineResult.liveText)
    }

    /// 設定OFFの状態とトリガーの無い入力では訂正が提示されないことを検証する
    ///
    /// どちらの結果にもタイポ訂正のフラグ付き候補が含まれないこと
    func testDisabledSettingAndTriggerlessInputDoNotOfferCorrection() throws {
        // Given: 一方は設定OFF、もう一方は認識できるタイポトリガーが無い入力
        let disabled = try state(reading: "shipppaishita", enabled: false)
        let ordinary = try state(reading: "henkansuru")
        defer { disabled.close(); ordinary.close() }

        // When: 両方の実サーバ状態でサジェスト候補を生成する
        let disabledResult = try candidates(disabled, suggest: true)
        let ordinaryResult = try candidates(ordinary, suggest: true)

        // Then: どちらの結果にも訂正のフラグ付き候補が含まれない
        XCTAssertFalse(disabledResult.candidates.contains(where: \.isTypoCorrection))
        XCTAssertFalse(ordinaryResult.candidates.contains(where: \.isTypoCorrection))
    }

    /// サジェストの押し出しがライブ候補の同一性を保つことを検証する
    ///
    /// 上限5件のサジェストで訂正を挿入しても、ライブ候補の表記と位置が保たれ、押し出された候補以外は変わらないこと
    func testSuggestionPushoutPreservesLiveCandidateIdentity() throws {
        // Given: 上限が同じサジェスト状態が、タイポ訂正の有無だけ異なる
        let state = try state(reading: "shipppaishita")
        let baseline = try self.state(reading: "shipppaishita", enabled: false)
        defer { state.close() }
        defer { baseline.close() }
        state.serverConfig.currentProfile.numSuggestions = 5
        state.serverConfig.currentProfile.suggestionListMode = .suggestionListShowPredictiveResults
        baseline.serverConfig.currentProfile.numSuggestions = 5
        baseline.serverConfig.currentProfile.suggestionListMode = .suggestionListShowPredictiveResults

        // When: 両方のサジェスト一覧を生成する
        let before = try candidates(baseline, suggest: true)
        let result = try candidates(state, suggest: true)

        // Then: 挿入によって候補が1件押し出され、ライブ候補の同一性が保たれる
        XCTAssertEqual(before.candidates.count, 5)
        XCTAssertEqual(result.candidates.count, 5)
        XCTAssertNotNil(correctionIndex(result))
        XCTAssertEqual(result.liveText, before.liveText)
        let liveIndex = Int(result.liveTextIndex)
        XCTAssertGreaterThanOrEqual(liveIndex, 0)
        let serverCandidates = try XCTUnwrap(state.currentCandidateList)
        if liveIndex < result.candidates.count {
            XCTAssertEqual(result.candidates[liveIndex].text, result.liveText)
        } else {
            // サジェストの枠が埋まっている場合、ライブ候補はサーバ側の候補リストにだけ残る
            // その場合も、位置はサーバ側リストのライブ候補を指していなければならない
            XCTAssertEqual(serverCandidates.count, liveIndex + 1)
            guard case .fromConverter(let liveCandidate) = serverCandidates[liveIndex] else {
                return XCTFail("server-only live candidate missing from the server list")
            }
            XCTAssertEqual(liveCandidate.text, result.liveText)
        }
        XCTAssertEqual(state.completePrefix(candidateIndex: liveIndex).status, .success)
        XCTAssertEqual(state.composingText.value.convertTarget.toHiragana(), "")
    }

    /// サジェスト枠が1件のときはライブ候補だけでは訂正が抑止され、通常変換では提示されることを検証する
    ///
    /// 1枠サジェストは訂正OFFの基準状態と完全に一致し、通常変換では訂正が挿入されること
    func testSingleLiveSuggestionSuppressesCorrectionButNormalModeShowsIt() throws {
        // Given: 上限が1件のサジェスト状態が、タイポ訂正の有無だけ異なる
        let state = try state(reading: "shipppaishita")
        let baseline = try self.state(reading: "shipppaishita", enabled: false)
        defer { state.close(); baseline.close() }
        state.serverConfig.currentProfile.numSuggestions = 1
        state.serverConfig.currentProfile.suggestionListMode = .suggestionListShowNormalResults
        baseline.serverConfig.currentProfile.numSuggestions = 1
        baseline.serverConfig.currentProfile.suggestionListMode = .suggestionListShowNormalResults

        // When: 1枠のサジェストと通常変換を要求する
        let withoutCorrection = try candidates(baseline, suggest: true)
        let suggestion = try candidates(state, suggest: true)
        let normal = try candidates(state, suggest: false)

        // Then: ライブ候補だけのサジェストは基準状態と完全に一致し、通常変換では訂正が挿入される
        XCTAssertFalse(suggestion.candidates.contains(where: \.isTypoCorrection))
        XCTAssertEqual(suggestion.candidates.map(\.text), withoutCorrection.candidates.map(\.text))
        XCTAssertEqual(suggestion.liveText, withoutCorrection.liveText)
        XCTAssertEqual(suggestion.liveTextIndex, withoutCorrection.liveTextIndex)
        XCTAssertEqual(suggestion.candidates.count, withoutCorrection.candidates.count)
        XCTAssertEqual(normal.candidates[try XCTUnwrap(correctionIndex(normal))].text, "失敗した")
    }

    /// 組成の途中でカーソルがある場合に、接頭辞の訂正が提示され接尾辞が保たれることを検証する
    ///
    /// 候補生成だけでは組成を書き換えず、訂正の確定でタイポ接頭辞だけが消えて接尾辞が変換可能なまま残ること
    func testMidCompositionCursorOffersPrefixCorrectionAndPreservesSuffix() throws {
        // Given: 既知の訂正 (shippppai -> 失敗) の後に、訂正対象にならない別の接尾辞が続く
        let state = try state(reading: "shippppaineko")
        defer { state.close() }
        let original = state.composingText.value.convertTarget.toHiragana()
        XCTAssertEqual(original, "しっっっぱいねこ")
        let moved = state.adjustClauseBoundary(offset: -2)
        XCTAssertEqual(moved.status, .success)
        XCTAssertEqual(moved.clauseBoundaryResult.hiragana, original)
        let cursorBeforeSelection = state.getHiraganaWithCursor().textWithCursor

        // When: 訂正を選ぶ前に、境界の通常変換候補を調べる
        let result = moved.clauseBoundaryResult.candidates
        let index = try XCTUnwrap(correctionIndex(result))

        // Then: 接頭辞だけが訂正され、候補生成は組成を書き換えていない
        XCTAssertEqual(result.candidates[index].text, "失敗")
        XCTAssertEqual(result.candidates[index].subHiragana, "ねこ")
        XCTAssertEqual(state.composingText.value.convertTarget.toHiragana(), original)
        XCTAssertEqual(state.getHiraganaWithCursor().textWithCursor, cursorBeforeSelection)

        // When: 訂正を接頭辞として確定する
        XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)

        // Then: 元のタイポ接頭辞だけが消え、接尾辞は変換可能なまま残る
        XCTAssertEqual(state.composingText.value.convertTarget.toHiragana(), "ねこ")
        let remaining = try candidates(state, suggest: false)
        XCTAssertFalse(remaining.candidates.isEmpty)
        XCTAssertEqual(state.composingText.value.convertTarget.toHiragana(), "ねこ")
    }

    /// 境界を左へ動かしてから右へ戻しても、接頭辞だけが訂正されることを検証する
    ///
    /// 復元した接頭辞が訂正され、訂正対象でない接尾辞を吸収しないこと
    func testBoundaryMovedLeftThenRightStillCorrectsOnlyPrefix() throws {
        // Given: 境界をまずタイポ接頭辞の中へ動かし、その後その末尾へ戻す
        let state = try state(reading: "shippppaineko")
        defer { state.close() }
        XCTAssertEqual(state.adjustClauseBoundary(offset: -3).status, .success)

        // When: Shift+Rightで変換範囲を1文字分だけ広げる
        let movedRight = state.adjustClauseBoundary(offset: 1)
        XCTAssertEqual(movedRight.status, .success)
        let result = movedRight.clauseBoundaryResult.candidates
        let index = try XCTUnwrap(correctionIndex(result))

        // Then: 復元した接頭辞が訂正され、訂正対象でない接尾辞を吸収しない
        XCTAssertEqual(result.candidates[index].text, "失敗")
        XCTAssertEqual(result.candidates[index].subHiragana, "ねこ")
        XCTAssertEqual(movedRight.clauseBoundaryResult.hiragana, "しっっっぱいねこ")
    }

    /// 接尾辞側だけのタイポが接頭辞の訂正へ漏れないことを検証する
    ///
    /// 通常の接頭辞に対して訂正候補が作られないこと
    func testSuffixOnlyTypoDoesNotLeakIntoPrefixCorrection() throws {
        // Given: 接頭辞は通常の読みで、タイポトリガーは境界より後ろにだけ現れる
        let state = try state(reading: "nekoshippppai")
        defer { state.close() }

        // When: Shift+Leftで境界を通常の接頭辞の後ろへ置く
        let result = state.adjustClauseBoundary(offset: -6)
        XCTAssertEqual(result.status, .success)

        // Then: 接尾辞側のタイポは接頭辞の訂正を作らない
        XCTAssertEqual(result.clauseBoundaryResult.hiragana, "ねこしっっっぱい")
        XCTAssertFalse(result.clauseBoundaryResult.candidates.candidates.contains(where: \.isTypoCorrection))
    }

    /// 複数箇所の連打縮約の訂正がまとめて提示されることを検証する
    ///
    /// 複数の連打を含む形状でも、縮約後の表記がフラグ付き候補として提示されること
    func testMultiRunCorrectionsAreOfferedTogether() throws {
        let cases = [
            ("yatttta---man", "ヤッターマン"),
            ("konnnnnnnixyaxyaku", "こんにゃく"),
            ("su--pa---", "スーパー"),
        ]
        for (romaji, expected) in cases {
            // Given: 複数箇所の連打形状を含む組成
            let state = try state(reading: romaji)
            defer { state.close() }

            // When: 通常変換の候補を要求する
            let result = try candidates(state, suggest: false)

            // Then: 複数箇所の訂正がまとめてフラグ付き候補として提示される
            let index = try XCTUnwrap(correctionIndex(result), romaji)
            XCTAssertEqual(result.candidates[index].text, expected, romaji)
            XCTAssertTrue(result.candidates[index].isTypoCorrection, romaji)
        }
    }

    /// 訂正候補の確定が訂正後の読みを学習し、その学習エントリを削除できることを検証する
    ///
    /// 確定後に訂正後の表記が学習履歴に現れ、deleteCandidateLearningDataで削除件数が1以上になること
    func testCorrectionSelectionLearnsCorrectedReadingAndCanBeDeleted() throws {
        // Given: 実際の組成に対して生成された、フラグ付きの訂正候補
        let state = try state(reading: "shipppaishita")
        defer { state.close() }
        let result = try candidates(state, suggest: false)
        let index = try XCTUnwrap(correctionIndex(result))

        // When: その訂正を確定し、その学習エントリを削除する
        XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)
        XCTAssertTrue(state.composingText.value.convertTarget.isEmpty)
        XCTAssertTrue(state.learningDataNeedsCommit)
        XCTAssertEqual(state.saveLearningData().status, .success)
        let corrected = try state.listLearningEntries(query: "シッパイシタ", offset: 0, limit: 200)
        XCTAssertTrue(corrected.entries.contains { $0.word == "失敗した" })
        let deleteState = HazkeyServerState(shared: state.shared)
        defer { deleteState.close() }
        deleteState.serverConfig.currentProfile.zenzaiEnable = false
        XCTAssertEqual(deleteState.createComposingTextInstanse().status, .success)
        for character in "shipppaishita" {
            XCTAssertEqual(deleteState.inputChar(inputString: String(character)).status, .success)
        }
        let retry = try candidates(deleteState, suggest: false)
        let correctionIndex = try XCTUnwrap(correctionIndex(retry))
        let deletion = deleteState.deleteCandidateLearningData(candidateIndex: correctionIndex)
        XCTAssertEqual(deletion.status, .success)
        XCTAssertGreaterThan(deletion.deleteCandidateLearningDataResult.deletedCount, 0)
    }

    /// 訂正用セッションがトリガーのある入力に対してだけ確保されることを検証する
    ///
    /// 設定OFFとトリガー無しではセッション数が0のままで、トリガーありでは確保数が1以上になりcloseで解放されること
    func testCorrectionSessionsAreAllocatedOnlyForTriggeredInput() throws {
        // Given: 設定OFF・トリガー無し・トリガーありの各状態
        let disabled = try state(reading: "shipppaishita", enabled: false)
        defer { disabled.close() }
        let triggerless = try state(reading: "henkansuru")
        defer { triggerless.close() }
        let triggered = try state(reading: "shipppaishita")
        defer { triggered.close() }

        // When: 各状態でサジェスト候補を生成する
        _ = try candidates(disabled, suggest: true)
        _ = try candidates(triggerless, suggest: true)
        _ = try candidates(triggered, suggest: true)

        // Then: 訂正用セッションはトリガーのある入力にだけ確保され、closeで解放される
        XCTAssertEqual(disabled.typoCorrectionSessionCount, 0)
        XCTAssertEqual(triggerless.typoCorrectionSessionCount, 0)
        XCTAssertGreaterThan(triggered.typoCorrectionSessionCount, 0)
        triggered.close()
        XCTAssertEqual(triggered.typoCorrectionSessionCount, 0)
    }

    /// 新しい組成の開始で訂正用セッションの変換結果も破棄されることを検証する
    ///
    /// 前の組成で評価した訂正案と同じ読みでも、その後に学習した表記が訂正候補に使われること
    func testNewCompositionDiscardsCachedCorrectionLattices() throws {
        // Given: 誤字のある入力で訂正案を評価し、訂正用セッションに変換結果が残っている
        // 新しい組成の直後はラティスが冷えて主変換が時間予算を超え得るため、予算は十分に長くする (予算の検証は別のテストが担う)
        let state = try state(reading: "shipppaishita")
        defer { state.close() }
        state.typoTimeBudget = .seconds(10)
        state.typoEvaluationBudget = .seconds(10)
        let before = try candidates(state, suggest: false)
        let beforeIndex = try XCTUnwrap(correctionIndex(before))
        XCTAssertEqual(before.candidates[beforeIndex].text, "失敗した")

        // When: 訂正後の読みに既定とは異なる表記を学習し、同じ誤字を新しい組成として入力する
        try learn("シッパイシタ", romaji: "shippaishita", shared: state.shared)
        XCTAssertEqual(state.createComposingTextInstanse().status, .success)
        for character in "shipppaishita" {
            XCTAssertEqual(state.inputChar(inputString: String(character)).status, .success)
        }
        let after = try candidates(state, suggest: false)

        // Then: 訂正候補には前の組成の変換結果ではなく、学習した表記が使われる
        let afterIndex = try XCTUnwrap(correctionIndex(after))
        XCTAssertEqual(after.candidates[afterIndex].text, "シッパイシタ")
    }

    /// 学習履歴の全消去で訂正用セッションの変換結果も破棄されることを検証する
    ///
    /// 同じ組成のまま候補を再生成しても、消去した学習の表記が訂正候補に残らないこと
    func testClearingAllLearningDiscardsCachedCorrectionLattices() throws {
        // Given: 訂正後の読みに既定とは異なる表記を学習し、その表記が訂正候補に使われている
        // 全消去の直後はラティスが冷えて主変換が時間予算を超え得るため、予算は十分に長くする (予算の検証は別のテストが担う)
        let state = try state(reading: "shipppaishita", enabled: false)
        defer { state.close() }
        state.typoTimeBudget = .seconds(10)
        state.typoEvaluationBudget = .seconds(10)
        try learn("シッパイシタ", romaji: "shippaishita", shared: state.shared)
        state.serverConfig.currentProfile.useTypoCorrection = true
        let learned = try candidates(state, suggest: false)
        let learnedIndex = try XCTUnwrap(correctionIndex(learned))
        XCTAssertEqual(learned.candidates[learnedIndex].text, "シッパイシタ")

        // When: 学習履歴を全て消去し、同じ組成のまま候補を再生成する
        XCTAssertEqual(state.clearProfileLearningData().status, .success)
        let cleared = try candidates(state, suggest: false)

        // Then: 訂正候補は消去した学習の表記を使わない
        let clearedIndex = try XCTUnwrap(correctionIndex(cleared))
        XCTAssertEqual(cleared.candidates[clearedIndex].text, "失敗した")
    }

    /// 打鍵時の訂正案の評価が時間予算で打ち切られることを検証する
    ///
    /// 評価に使える時間が無ければ訂正案の変換も訂正用セッションの確保も行わず、時間があれば同じ入力で訂正が提示されること
    func testTypingTimeCorrectionStopsEvaluatingWhenTheEvaluationBudgetIsExhausted() throws {
        // Given: 主変換は時間予算に収まるが、訂正案の評価に使える時間が残っていない
        let state = try state(reading: "shipppaishita", enabled: false)
        defer { state.close() }
        state.serverConfig.currentProfile.useTypoCorrection = true
        state.typoTimeBudget = .seconds(10)
        state.typoEvaluationBudget = .zero

        // When: 打鍵時の候補を生成する
        let exhausted = try candidates(state, suggest: false)

        // Then: 訂正案は1件も評価されず、訂正用セッションも確保されない
        XCTAssertFalse(exhausted.candidates.contains(where: \.isTypoCorrection))
        XCTAssertEqual(state.typoCorrectionSessionCount, 0)

        // When: 評価に使える時間を戻して候補を再生成する
        state.typoEvaluationBudget = .seconds(10)
        let restored = try candidates(state, suggest: false)

        // Then: 同じ入力で訂正が提示される
        XCTAssertNotNil(correctionIndex(restored))
    }

    /// 打鍵時の訂正案の評価が、1件目を評価した後で時間予算に達した時点で打ち切られることを検証する
    ///
    /// 予算の判定は訂正案ごとに行うため、1件目の開始時に予算内なら1件目だけを評価し、評価した範囲の訂正を提示すること
    func testTypingTimeCorrectionEvaluatesUntilTheBudgetRunsOutMidway() throws {
        // Given: 訂正案が2件以上ある入力で、評価の開始時と1件目の開始時は予算内、2件目の開始時は予算超過になる時刻を返す
        let state = try state(reading: "shipppaishita", enabled: false)
        defer { state.close() }
        let reading = state.composingText.value.toHiragana()
        let variants = TypoCorrector.variants(
            of: state.composingText.value, triggers: TypoCorrector.triggers(in: reading))
        XCTAssertGreaterThanOrEqual(variants.count, 2)
        XCTAssertEqual(variants.first?.reading, "しっぱいした")
        state.serverConfig.currentProfile.useTypoCorrection = true
        state.typoTimeBudget = .seconds(10)
        state.typoEvaluationBudget = .milliseconds(500)
        let origin = ContinuousClock.now
        var elapsed: [Duration] = [.zero, .zero, .seconds(1)]
        state.typoClock = { origin + (elapsed.count > 1 ? elapsed.removeFirst() : elapsed[0]) }

        // When: 打鍵時の候補を生成する
        let result = try candidates(state, suggest: false)

        // Then: 訂正用セッションは1件目の分だけ確保され、1件目の訂正案から訂正が提示される
        XCTAssertEqual(state.typoCorrectionSessionCount, 1)
        XCTAssertEqual(result.candidates.filter(\.isTypoCorrection).map(\.text), ["失敗した"])
    }

    /// タイポ訂正を切り替えても主候補の並びが安定していることを検証する
    ///
    /// 訂正ONの候補から挿入された訂正を除いた並びが、訂正OFFの候補の並びと一致すること
    func testMainCandidatesAreStableWhenCorrectionIsToggled() throws {
        // Given: タイポ訂正をOFFとONにした等価な実サーバ状態
        let off = try state(reading: "shipppaishita", enabled: false)
        let on = try state(reading: "shipppaishita", enabled: true)
        defer { off.close(); on.close() }

        // When: 両方で通常変換の候補を生成する
        let without = try candidates(off, suggest: false)
        let with = try candidates(on, suggest: false)

        // Then: 挿入された訂正を除外した候補列は、変換エンジン由来の候補列として一致する
        XCTAssertEqual(
            without.candidates.map(\.text),
            with.candidates.filter { !$0.isTypoCorrection }.map(\.text))
    }

    /// 重なった複数の連打 (ゃゃゃ と っっっ) がまとめて訂正され、部分的な訂正が提示されないことを検証する
    ///
    /// 打鍵方法 (xya / lya / xtu / ltu / 同一キー連打) によらず、ちゃゃゃっっっと に対して チャット が
    /// 最良候補の直後に提示され、ゃ や っ が残ったままの訂正は並ばないこと
    func testOverlappingRunsOfferCompleteCorrectionOnly() throws {
        for romaji in ["chaxyaxyaxtuxtuxtuto", "chaxyaxyatttto", "chalyalyaltultultuto"] {
            // Given: 読み ちゃゃゃっっっと になる組成
            let state = try state(reading: romaji)
            defer { state.close() }
            XCTAssertEqual(state.composingText.value.convertTarget.toHiragana(), "ちゃゃゃっっっと", romaji)

            for suggest in [true, false] {
                // When: 入力中と通常変換で候補を要求する
                let result = try candidates(state, suggest: suggest)

                // Then: チャット がフラグ付きで2番目に並び、連打が残る訂正は並ばない
                let corrections = result.candidates.filter(\.isTypoCorrection).map(\.text)
                let index = try XCTUnwrap(correctionIndex(result), "\(romaji) suggest=\(suggest)")
                XCTAssertEqual(index, 1, "\(romaji) suggest=\(suggest)")
                XCTAssertEqual(result.candidates[index].text, "チャット", "\(romaji) suggest=\(suggest)")
                XCTAssertFalse(
                    corrections.contains { $0.contains("ゃ") || $0.contains("っ") || $0.contains("ャャ") || $0.contains("ッッ") },
                    "\(romaji) suggest=\(suggest): \(corrections)")
            }
        }
    }

    /// 入力中に Shift+Left / Shift+Right で文節境界を動かしても、重なった連打の訂正が提示されることを検証する
    ///
    /// 接頭辞 ちゃゃゃっっっと に対して チャット が提示され、確定すると接尾辞 です が組成に残ること
    func testOverlappingRunsAreCorrectedAfterClauseBoundaryAdjustment() throws {
        // Given: 訂正対象の接頭辞の後に、通常の接尾辞が続く
        let state = try state(reading: "chaxyaxyaxtuxtuxtutodesu")
        defer { state.close() }
        XCTAssertEqual(state.composingText.value.convertTarget.toHiragana(), "ちゃゃゃっっっとです")

        // When: Shift+Left で境界を接頭辞の末尾へ動かす
        let moved = state.adjustClauseBoundary(offset: -2)
        XCTAssertEqual(moved.status, .success)
        let result = moved.clauseBoundaryResult.candidates

        // Then: 接頭辞の訂正 チャット が提示され、接尾辞は未変換のまま残る
        let index = try XCTUnwrap(
            result.candidates.firstIndex { $0.isTypoCorrection && $0.text == "チャット" },
            "\(result.candidates.map(\.text))")
        XCTAssertEqual(result.candidates[index].subHiragana, "です")

        // When: 訂正を確定する
        XCTAssertEqual(state.completePrefix(candidateIndex: index).status, .success)

        // Then: 元の接頭辞だけが消え、接尾辞が組成に残る
        XCTAssertEqual(state.composingText.value.convertTarget.toHiragana(), "です")

        // Given: 同一キー連打の促音で、境界を左へ動かしてから右へ戻す
        let roundTrip = try self.state(reading: "chaxyaxyatttto")
        defer { roundTrip.close() }
        XCTAssertEqual(roundTrip.adjustClauseBoundary(offset: -1).status, .success)

        // When: Shift+Right で読み全体を変換範囲へ戻す
        let movedRight = roundTrip.adjustClauseBoundary(offset: 1)

        // Then: 読み全体の訂正 チャット が提示される
        XCTAssertTrue(
            movedRight.clauseBoundaryResult.candidates.candidates.contains { $0.isTypoCorrection && $0.text == "チャット" },
            "\(movedRight.clauseBoundaryResult.candidates.candidates.map(\.text))")
    }

    /// 隣接キーの打ち間違いと ん の打ち忘れが、最良候補の直後に訂正として提示されることを検証する
    func testAdjacentKeyAndMissingNCorrectionsFollowBestCandidate() throws {
        let cases = [
            ("arigatpu", "ありがとう"), ("sayonsra", "さよなら"), ("shitsumkn", "質問"),
            ("kinyoubi", "金曜日"), ("konyaku", "婚約"), ("hanyou", "汎用"),
        ]
        for (romaji, expected) in cases {
            // Given: 隣接キーの打ち間違い、または ん の打ち忘れを1つ含む組成
            let state = try state(reading: romaji)
            defer { state.close() }

            // When: 通常変換の候補を要求する
            let result = try candidates(state, suggest: false)

            // Then: 意図した表記がフラグ付きで2番目に並ぶ
            let index = try XCTUnwrap(correctionIndex(result), romaji)
            XCTAssertEqual(index, 1, romaji)
            XCTAssertEqual(result.candidates[index].text, expected, romaji)
        }
    }

    /// 最良の訂正より大きく劣る訂正が、雑音として並ばないことを検証する
    ///
    /// さよんsら では さよなら だけが提示され、差米ら や さよんすら は並ばないこと
    func testFarWeakerCorrectionsAreNotOffered() throws {
        let state = try state(reading: "sayonsra")
        defer { state.close() }

        let corrections = try candidates(state, suggest: false).candidates.filter(\.isTypoCorrection).map(\.text)

        XCTAssertEqual(corrections, ["さよなら"])
    }

    /// 正しい語である にゅ・にょ の読みには、ん を補う訂正が提示されないことを検証する
    ///
    /// 記入 (きにゅう)・加入 (かにゅう)・屎尿 (しにょう) は、補った読みの方が高くならないこと
    func testValidNyaReadingsDoNotOfferMissingNCorrection() throws {
        for romaji in ["kinyuu", "kanyuu", "shinyou", "konnyaku", "nyuuryoku"] {
            let state = try state(reading: romaji)
            defer { state.close() }

            let result = try candidates(state, suggest: false)

            XCTAssertFalse(
                result.candidates.contains(where: \.isTypoCorrection),
                "\(romaji): \(result.candidates.filter(\.isTypoCorrection).map(\.text))")
        }
    }

    /// Shift+Left で文節境界を動かした接頭辞でも、ん の打ち忘れが訂正されることを検証する
    func testMissingNIsCorrectedAfterClauseBoundaryAdjustment() throws {
        // Given: ん を打ち忘れた接頭辞の後に、通常の接尾辞が続く
        let state = try state(reading: "kinyoubidesu")
        defer { state.close() }
        XCTAssertEqual(state.composingText.value.convertTarget.toHiragana(), "きにょうびです")

        // When: Shift+Left で境界を接頭辞の末尾へ動かす
        let result = state.adjustClauseBoundary(offset: -2).clauseBoundaryResult.candidates

        // Then: 金曜日 が訂正として提示され、接尾辞は未変換のまま残る
        let correction = try XCTUnwrap(
            result.candidates.first { $0.isTypoCorrection && $0.text == "金曜日" },
            "\(result.candidates.map(\.text))")
        XCTAssertEqual(correction.subHiragana, "です")
    }
}
