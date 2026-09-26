import Foundation
import KanaKanjiConverterModule
import SwiftUtils

/// 表示候補ごとに保持するエントリ
/// 確定時に変換エンジンの結果とユーザ辞書の注入候補を区別する
enum DisplayedCandidate {
    case fromConverter(Candidate)
    /// レガシー: エンジン注入方式への移行後は生成されない
    /// エンジンに注入されたユーザ辞書エントリは、現在".fromConverter"として届く
    case fromUserDict(word: String)
    /// RelativeDateProviderが注入する相対日付候補
    /// 確定時は、".fromUserDict"と同様に扱う (組成テキストを消去し、学習しない) が、明確さと将来の拡張のため別ケースとして保持する
    case fromDateProvider(word: String)
    /// KanaNumberProviderが注入する特殊数値候補 (下付き/上付き/丸囲み/ローマ数字等)
    /// 確定時は、".fromDateProvider"と同様に扱う (組成テキストを消去し、学習しない) が、明確さのため別ケースとして保持する
    case fromKanaNumberProvider(word: String)
    /// EmojiCandidateProviderが注入するEmoji 17.0直接変換候補
    /// 確定時は、prefixCompleteにより一致した正規化クエリのprefix (composingCount) だけを消費し、後続のsuffixは組成に残す
    /// 学習は行わない。
    /// 明確さと削除処理の振り分けのため、別ケースとして保持する
    case fromEmoji(word: String, composingCount: ComposingCount)
}

private enum LearningHistoryError: Error {
    case invalidOffset
    case unknownEntry
    case unsupportedCID
}

private struct LearningHistoryKey: Hashable {
    let reading: String
    let word: String
    let lcid: UInt32
    let rcid: UInt32
}

func katakanaNormalized(_ text: String) -> String {
    var normalized = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if (0x3041 ... 0x3096).contains(scalar.value),
            let katakanaScalar = Unicode.Scalar(scalar.value + 0x60)
        {
            normalized.append(katakanaScalar)
        } else {
            normalized.append(scalar)
        }
    }
    return String(normalized)
}

func learningHistoryMatches(query: String, reading: String, word: String) -> Bool {
    let normalizedQuery = katakanaNormalized(query)
    return normalizedQuery.isEmpty
        || katakanaNormalized(reading).contains(normalizedQuery)
        || katakanaNormalized(word).contains(normalizedQuery)
}

/// 変換候補が学習メモリに保存されうる2種類の読み
/// トライの完全一致キーに合わせてカタカナ正規化する
///
/// "prefixReading"は、候補位置まで切り詰めた入力読み ("min(rubyCount, requestHiraganaPreeditLen)") で、通常変換はこの読みで保存される
/// "fullRuby"は、候補全体のrubyで、予測候補はこの読みで保存される
/// 予測は入力済み範囲より先まで伸びるため、切り詰めた読みでは別のトライノードを指し、一致しない
/// 候補にdataが無い場合 (キャッシュ済み予測経路) は空とし、その場合は"prefixReading"のみを使用する
struct CandidateLearningReadings {
    let prefixReading: String
    let fullRuby: String
}

/// CID違いをまたいで候補の学習エントリを識別する (reading, word) 表層キー
/// 組成テキストのひらがな読みが学習メモリ内のカタカナrubyに一致するよう、readingをカタカナ正規化する
/// 「削除可能」注釈と削除ハンドラで共有し、削除可能と表示された候補を必ず削除できるようにする
struct LearningSurfaceKey: Hashable {
    let reading: String
    let word: String

    init(reading: String, word: String) {
        self.reading = katakanaNormalized(reading)
        self.word = word
    }
}

/// 全クライアント接続で共有するサーバ全体のリソース
///
/// KanaKanjiConverterインスタンス (辞書、Zenzaiモデル、学習メモリ、メモ化キャッシュ) は重いため、プロセス全体で共有する
/// 変換エンジン内では組成ごとの状態 (ラティス、確定済みデータ、Zenzai/予測キャッシュ) のみをConversionSessionIDで管理する
/// 各ソケットクライアントには、変換セッションと独自の組成テキスト・候補リストを持つHazkeyServerStateを割り当てる
class HazkeySharedResources {
    let serverConfig: HazkeyServerConfig
    let converter: KanaKanjiConverter
    let userDictionary: UserDictionary = UserDictionary()
    /// キャッシュ済みの不変な絵文字プロバイダ
    /// プロセスごとに一度だけ構築し、その後は更新しない
    let emojiProvider: EmojiCandidateProvider?

    var keymap: Keymap
    var currentTableName: String
    var baseConvertRequestOptions: ConvertRequestOptions
    var learningDataNeedsCommit = false
    var userDictInjected = false

    /// allLearningMemoryEntries()が1回の走査で列挙する行数の上限
    /// 保存エントリの正式な上限であるHazkeyServerConfig.genBaseConvertRequestOptions()に渡すmaxMemoryCountと一致させること
    static let learningEnumerationLimit = 65_536

    /// 注釈の照会は打鍵ごとに実行されるため、回復不能な障害をそのまま記録するとキーごとにログが出てしまう
    private var lastLearningLookupFailureLog: ContinuousClock.Instant?
    private static let learningLookupFailureLogInterval: Duration = .seconds(60)

    private var lastLearningCommitFailureLog: ContinuousClock.Instant?
    private static let learningCommitFailureLogInterval: Duration = .seconds(60)

    /// 「削除可」注釈と削除ハンドラが使うポイント照会
    /// nilの場合は本番経路 (converter.persistedLearningMemoryKeys(exactReadings:)) を使用する
    /// テストでは失敗するクロージャに置き換え、未検査パースでトラップする可能性のある実シャードを破損させずに縮退経路を検証する
    var learningSurfaceKeyLookup: (([String]) throws -> [PersistedLearningMemoryKey])?

    /// 接続中の全セッションID
    /// 学習削除時は要求元だけでなく全セッションの変換キャッシュを無効化し、削除済みエントリが他クライアントの候補に再出現しないようにする
    private var liveConversionSessionIDs: Set<KanaKanjiConverter.ConversionSessionID> = []

    static let addressDictionarySourceID = "address"
    static let engineeringDictionarySourceID = "engineering"

    /// 宣言順は固定: addressが先、engineeringが後
    static func supplementalDictionarySources(
        for config: HazkeyServerConfig
    ) -> [SupplementalDictionarySource] {
        [
            SupplementalDictionarySource(
                id: addressDictionarySourceID, directoryURL: config.addressDictionaryPath),
            SupplementalDictionarySource(
                id: engineeringDictionarySourceID, directoryURL: config.engineeringDictionaryPath),
        ]
    }

    /// ソースリストが拒否されても変換を停止させない
    /// システム辞書のみへフォールバックし、その場合は両トグルを無効な操作とする
    static func makeConverter(
        dictionaryURL: URL, supplementalDictionaries: [SupplementalDictionarySource]
    ) -> KanaKanjiConverter {
        do {
            return try KanaKanjiConverter(
                dictionaryURL: dictionaryURL, supplementalDictionaries: supplementalDictionaries)
        } catch {
            NSLog("Supplemental dictionaries rejected (\(error)); continuing without them")
            return KanaKanjiConverter(dictionaryURL: dictionaryURL)
        }
    }

    convenience init() {
        self.init(emojiDictionaryURL: nil)
    }

    /// Parameter emojiDictionaryURL: テスト用に注入する辞書URL
    ///                               nilの場合は、本番用E17アセットを使用する
    init(emojiDictionaryURL: URL?) {
        self.serverConfig = HazkeyServerConfig()
        self.emojiProvider = EmojiCandidateProvider(
            dictionaryURL: emojiDictionaryURL ?? EmojiCandidateProvider.defaultDictionaryURL)

        self.converter = Self.makeConverter(
            dictionaryURL: serverConfig.dictionaryPath,
            supplementalDictionaries: Self.supplementalDictionarySources(for: serverConfig))

        // キーマップとテーブルを初期化
        self.keymap = serverConfig.loadKeymap()
        self.currentTableName = UUID().uuidString
        serverConfig.loadInputTable(tableName: currentTableName)

        // ユーザ状態ディレクトリ (履歴データ) を作成
        do {
            let memoryDirectory = serverConfig.memoryDirectory()
            if !FileManager.default.fileExists(atPath: memoryDirectory.path) {
                let oldPath = HazkeyServerConfig.getDataDirectory().appendingPathComponent(
                    "memory", isDirectory: true)
                if !serverConfig.currentProfile.useProfileIndependentHistoryEffective,
                    FileManager.default.fileExists(atPath: oldPath.path)
                {
                    // v0.2.0の保存パスからの移動対応
                    try FileManager.default.createDirectory(
                        at: HazkeyServerConfig.getStateDirectory(),
                        withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: oldPath, to: memoryDirectory)
                } else {
                    try serverConfig.createMemoryDirectoryIfNeeded()
                }
            }
        } catch {
            NSLog("Failed to create user memory directory: \(error.localizedDescription)")
        }

        // ユーザキャッシュディレクトリ (ユーザ辞書) を作成
        do {
            try FileManager.default.createDirectory(
                at: HazkeyServerConfig.getCacheDirectory().appendingPathComponent(
                    "shared", isDirectory: true), withIntermediateDirectories: true)
        } catch {
            NSLog("Failed to create user cache directory: \(error.localizedDescription)")
        }

        // 基本変換オプションを初期化
        self.baseConvertRequestOptions = serverConfig.genBaseConvertRequestOptions()
        syncConverterAddressDictionary()
        var learningInitializationOptions = baseConvertRequestOptions
        learningInitializationOptions.zenzaiMode = .off
        _ = converter.requestCandidates(
            .init(
                convertTargetCursorPosition: 1,
                input: [.init(character: "ア", inputStyle: .direct)],
                convertTarget: "ア"
            ),
            options: learningInitializationOptions
        )
    }

    /// サーバ全体のキャッシュ無効化対象として、接続セッションを登録する
    func registerConversionSession(_ id: KanaKanjiConverter.ConversionSessionID) {
        liveConversionSessionIDs.insert(id)
    }

    /// 切断済み接続のセッション登録を解除する
    func unregisterConversionSession(_ id: KanaKanjiConverter.ConversionSessionID) {
        liveConversionSessionIDs.remove(id)
    }

}

// MARK: - 共有設定と学習

extension HazkeySharedResources {
    /// キーマップ、入力テーブル、基本オプション、メモリディレクトリを再読み込みする
    /// 組成状態は接続ごとに保持されるため、ここでは変更しない
    /// 呼び出し後に各HazkeyServerStateが自身の組成をリセットする
    func reinitializeConfiguration() {
        // 呼び出し後に自身の組成をリセットするのは要求元接続だけで、他の接続中セッションは入力途中の組成を維持する
        // InputStyleManager.registerInputStyle(table:for:) (KanaKanjiConverterModule) は、
        // 新しい".tableName(UUID)"をキーとするエントリを追加するだけで、以前の登録名を削除しないため安全
        // したがって、古い".tableName(...)"が付いたComposingText要素も引き続き解決できる
        //
        // 許容する残差: 1つの入力途中の組成で、設定変更前のキーは旧マッピング、変更後のキーは新しいキーマップ / テーブルを使用する
        self.keymap = serverConfig.loadKeymap()

        let newTableName = UUID().uuidString
        serverConfig.loadInputTable(tableName: newTableName)
        self.currentTableName = newTableName

        self.baseConvertRequestOptions = serverConfig.genBaseConvertRequestOptions()
        do {
            try serverConfig.createMemoryDirectoryIfNeeded()
        } catch {
            NSLog("Failed to create user memory directory: \(error.localizedDescription)")
        }
        syncConverterLearningConfig()
        syncConverterAddressDictionary()
        // ホットパス側のユーザ辞書再読込はスロットルされるため、設定適用時はスロットルを迂回して強制再読込し、辞書編集を取りこぼさない
        // userDictInjectedを倒して次回の候補生成で (変更後の) エントリを再注入させる
        userDictionary.reloadIfNeeded(force: true)
        userDictInjected = false
    }

    /// [変換]タブの住所辞書・工学用語辞書トグルを反映する
    /// 両補助ソースは変換エンジン構築時に登録済みのため、OFFにする際はフラグを切り替えるだけでよく、再構築やアセット再読み込みは不要
    func syncConverterAddressDictionary() {
        let profile = serverConfig.currentProfile
        converter.setSupplementalDictionaryEnabled(
            profile.useAddressDictionaryEffective, for: Self.addressDictionarySourceID)
        converter.setSupplementalDictionaryEnabled(
            profile.useEngineeringDictionaryEffective, for: Self.engineeringDictionarySourceID)
    }

    /// 変換エンジンは、requestCandidates(_:options:)内でmemoryDirectoryURLを遅延適用する
    /// 設定ダイアログは変換を行わないため、学習履歴の列挙・削除は次の打鍵まで前プロファイルのディレクトリを読み続けてしまうため、ここで先行適用する
    func syncConverterLearningConfig() {
        converter.updateLearningConfig(
            LearningConfig(
                learningType: baseConvertRequestOptions.learningType,
                maxMemoryCount: baseConvertRequestOptions.maxMemoryCount,
                memoryURL: baseConvertRequestOptions.memoryDirectoryURL))
    }

    /// 保留中の学習データを永続化する
    /// コミット失敗時は、learningDataNeedsCommitを維持して、.failedを返す
    /// 変換エンジンは一時メモリ上の保留データを保持するため、次の契機 (次のsave_learning_data RPC、切断、設定変更) で再試行される
    /// ここでフラグを消すと、ディスクに到達していない学習データを通知なく破棄してしまう
    func saveLearningData() -> Hazkey_ResponseEnvelope {
        guard learningDataNeedsCommit else {
            return Hazkey_ResponseEnvelope.with { $0.status = .success }
        }
        do {
            try converter.commitUpdateLearningData()
        } catch {
            reportLearningCommitFailure(error)
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Failed to persist learning data: \(error)"
            }
        }
        learningDataNeedsCommit = false
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    func reloadZenzaiModel() -> Hazkey_ResponseEnvelope {
        serverConfig.reloadZenzaiModel()

        guard serverConfig.zenzaiModelPath != nil,
            serverConfig.zenzaiAvailable,
            serverConfig.currentProfile.zenzaiEnable
        else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .success
            }
        }

        var options = baseConvertRequestOptions
        options.N_best = 1
        options.zenzaiMode = serverConfig.genZenzaiMode(
            leftContext: "",
            requestRichCandidates: HazkeyServerConfig.requestRichCandidates(
                for: serverConfig.currentProfile, isSuggestion: false))
        guard let modelPath = serverConfig.zenzaiModelPath else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .success
            }
        }

        let warmupSessionID = converter.createSession()
        defer {
            converter.removeSession(warmupSessionID)
        }
        var warmupText = ComposingText()
        warmupText.insertAtCursorPosition("あ", inputStyle: .direct)

        do {
            _ = try converter.withSession(warmupSessionID) {
                converter.requestCandidates(warmupText, options: options)
            }
        } catch {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Zenzai model warmup failed: \(error)"
            }
        }

        let expectedStatus = "load \(modelPath.resolvingSymlinksInPath().absoluteString)"
        guard converter.zenzStatus == expectedStatus else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Zenzai model warmup failed: \(converter.zenzStatus)"
            }
        }
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    func clearProfileLearningData() -> Hazkey_ResponseEnvelope {
        // ディレクトリだけを削除しても変換エンジンの未コミット一時メモリ、キャッシュ済みmemory LOUDS、dirtyフラグは残る
        // そのため次のコミットで保留エントリが、消去したばかりのディレクトリへ書き戻される
        // どちらの分岐でも変換エンジンの状態とフラグをリセットする
        converter.resetMemory()
        learningDataNeedsCommit = false
        if serverConfig.currentProfile.useProfileIndependentHistoryEffective {
            let memoryDirectory = serverConfig.memoryDirectory()
            do {
                if FileManager.default.fileExists(atPath: memoryDirectory.path) {
                    try FileManager.default.removeItem(at: memoryDirectory)
                }
                try serverConfig.createMemoryDirectoryIfNeeded()
            } catch {
                NSLog("Failed to clear isolated history: \(error.localizedDescription)")
                return Hazkey_ResponseEnvelope.with {
                    $0.status = .failed
                    $0.errorMessage = "Failed to clear profile history."
                }
            }
        }
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    /// 学習履歴を (reading, word) 表層キーごとに1行へ統合する
    /// 学習メモリは (ruby, word, lcid, rcid) ごとに1行を保存するため、同じ表層でも複数のCID違いの行になりうる (例: 1回の確定による文節バイグラムと全文エントリ)
    /// ダイアログでは表層ごとに統合した1行を表示し、削除時は候補削除ホットキーと同じく全バリアントを削除するため、クライアントにはlcid / rcidを公開しない
    func listLearningEntries(
        query: String,
        offset: UInt32,
        limit: UInt32
    ) throws -> (entries: [Hazkey_Config_LearningHistoryEntry], totalCount: Int) {
        guard offset <= Self.learningEnumerationLimit else {
            throw LearningHistoryError.invalidOffset
        }
        let pageLimit = min(max(Int(limit), 1), 200)
        var surfaceOrder: [LearningSurfaceKey] = []
        var mergedSurfaces: [LearningSurfaceKey: (reading: String, word: String, count: Int, lastUsed: Date)] = [:]
        for entry in try allLearningMemoryEntries()
        where learningHistoryMatches(query: query, reading: entry.data.ruby, word: entry.data.word) {
            let key = LearningSurfaceKey(reading: entry.data.ruby, word: entry.data.word)
            if mergedSurfaces[key] == nil {
                surfaceOrder.append(key)
                mergedSurfaces[key] = (entry.data.ruby, entry.data.word, Int(entry.count), entry.lastUsed)
            } else {
                mergedSurfaces[key]!.count += Int(entry.count)
                if mergedSurfaces[key]!.lastUsed < entry.lastUsed {
                    mergedSurfaces[key]!.lastUsed = entry.lastUsed
                }
            }
        }
        let pageStart = min(Int(offset), surfaceOrder.count)
        let pageEnd = min(pageStart + pageLimit, surfaceOrder.count)
        let entries = surfaceOrder[pageStart..<pageEnd].map { key in
            Hazkey_Config_LearningHistoryEntry.with {
                let surface = mergedSurfaces[key]!
                $0.reading = surface.reading
                $0.word = surface.word
                $0.count = UInt32(clamping: surface.count)
                $0.lastUsedUnixDay = UInt32(clamping: max(0, Int(surface.lastUsed.timeIntervalSince1970 / 86_400)))
            }
        }
        return (entries, surfaceOrder.count)
    }

    func forgetLearningEntries(
        _ keys: [(reading: String, word: String, lcid: UInt32, rcid: UInt32)]
    ) throws -> UInt32 {
        var uniqueKeys: [LearningHistoryKey] = []
        var seenKeys: Set<LearningHistoryKey> = []
        for key in keys {
            let historyKey = LearningHistoryKey(
                reading: key.reading, word: key.word, lcid: key.lcid, rcid: key.rcid)
            if seenKeys.insert(historyKey).inserted {
                uniqueKeys.append(historyKey)
            }
        }

        // エントリは自身のreadingにのみ保存されるため、要求されたreadingだけをポイント照会すれば全件走査と同等
        let existingKeys = Set(
            try persistedLearningMemoryKeys(
                exactReadings: Array(Set(uniqueKeys.map(\.reading)))
            ).map {
                LearningHistoryKey(
                    reading: $0.reading,
                    word: $0.word,
                    lcid: UInt32(clamping: $0.lcid),
                    rcid: UInt32(clamping: $0.rcid))
            })
        guard uniqueKeys.allSatisfy(existingKeys.contains) else {
            throw LearningHistoryError.unknownEntry
        }

        for key in uniqueKeys {
            guard let lcid = Int(exactly: key.lcid), let rcid = Int(exactly: key.rcid) else {
                throw LearningHistoryError.unsupportedCID
            }
            try converter.forgetLearningMemory(
                reading: key.reading, word: key.word, lcid: lcid, rcid: rcid)
        }
        // 削除済みエントリを以降の変換候補に再出現させてはならない
        // 組成テキストが変わらない場合、変換エンジンは各セッションのラティス (およびZenzaiのdraft/メモ化制約) を再利用するため、
        // 古いキャッシュから削除済みエントリが候補リストに復活しうる
        //
        // 全接続中セッションをリセットして、キャッシュされた変換状態だけを破棄する
        // 接続ごとのHazkeyServerStateが持つ組成テキストとディスク上の学習メモリには影響しない
        for id in liveConversionSessionIDs {
            do { try converter.withSession(id) { converter.stopComposition() } }
            catch { NSLog("[hazkey] Failed to reset conversion session \(id): \(error)") }
        }
        converter.purgeZenzaiMemoizationCache()
        return UInt32(uniqueKeys.count)
    }

    /// CIDにかかわらず各 (reading, word) 表層キーに一致する学習エントリを全て削除する
    /// 候補削除ホットキー (deleteCandidateLearningData) と同じ動作
    ///
    /// listLearningEntriesがCID違いを統合した行を表示する設定ダイアログから使用する
    /// 保存エントリがない表層はスキップするため、処理中に削除済みの行がバッチ全体を失敗させない
    /// 返す件数は実際に削除した完全一致エントリ数
    func forgetLearningSurfaces(_ surfaces: [(reading: String, word: String)]) throws -> UInt32 {
        var requestedSurfaces: Set<LearningSurfaceKey> = []
        var resolvedKeys: [(reading: String, word: String, lcid: UInt32, rcid: UInt32)] = []
        for surface in surfaces {
            let key = LearningSurfaceKey(reading: surface.reading, word: surface.word)
            guard requestedSurfaces.insert(key).inserted else { continue }
            resolvedKeys.append(contentsOf: try matchingLearningEntryKeys(reading: surface.reading, word: surface.word))
        }
        guard !resolvedKeys.isEmpty else { return 0 }
        return try forgetLearningEntries(resolvedKeys)
    }

    // internal (privateではない): 接続ごとのHazkeyServerStateが候補注釈と削除対象の照合に使用する
    func allLearningMemoryEntries() throws -> [LearningMemoryEntry] {
        try converter.allLearningMemoryEntries(limit: Self.learningEnumerationLimit).entries
    }

    private func persistedLearningMemoryKeys(
        exactReadings readings: [String]
    ) throws -> [PersistedLearningMemoryKey] {
        if let learningSurfaceKeyLookup {
            return try learningSurfaceKeyLookup(readings)
        }
        return try converter.persistedLearningMemoryKeys(exactReadings: readings)
    }

    /// readingsの下に保存された学習エントリの表層キー
    /// 「削除可」とする変換候補の注釈に使用する
    /// 読みはトライの完全一致キーであるため、事前にカタカナ正規化しておくこと
    func learningSurfaceKeys(forReadings readings: [String]) throws -> Set<LearningSurfaceKey> {
        Set(
            try persistedLearningMemoryKeys(exactReadings: readings).map {
                LearningSurfaceKey(reading: $0.reading, word: $0.word)
            })
    }

    /// CIDにかかわらず候補の (reading, word) に一致する保存済み学習エントリ全てを、forgetLearningEntries用のキーとして返す
    /// 注釈と同じポイント照会から導出するため、削除可能と表示された候補を必ず削除できる
    func matchingLearningEntryKeys(
        reading: String,
        word: String
    ) throws -> [(reading: String, word: String, lcid: UInt32, rcid: UInt32)] {
        try matchingLearningEntryKeys(readings: [reading], word: word)
    }

    /// 候補がいずれかの読みで保存された場合も上記と同様に照合する (通常変換は入力prefix、予測はfull ruby)
    /// 全ての読みを1回の照会にまとめる
    /// 削除時に読みごとにリクエストしてはならない
    func matchingLearningEntryKeys(
        readings: [String],
        word: String
    ) throws -> [(reading: String, word: String, lcid: UInt32, rcid: UInt32)] {
        var targets: Set<LearningSurfaceKey> = []
        for reading in readings where !reading.isEmpty {
            targets.insert(LearningSurfaceKey(reading: reading, word: word))
        }
        guard !targets.isEmpty else { return [] }

        var seenKeys: Set<LearningHistoryKey> = []
        var matches: [(reading: String, word: String, lcid: UInt32, rcid: UInt32)] = []
        for key in try persistedLearningMemoryKeys(exactReadings: targets.map(\.reading))
        where targets.contains(LearningSurfaceKey(reading: key.reading, word: key.word)) {
            let historyKey = LearningHistoryKey(
                reading: key.reading, word: key.word,
                lcid: UInt32(clamping: key.lcid), rcid: UInt32(clamping: key.rcid))
            guard seenKeys.insert(historyKey).inserted else { continue }
            matches.append(
                (
                    reading: historyKey.reading, word: historyKey.word,
                    lcid: historyKey.lcid, rcid: historyKey.rcid
                ))
        }
        return matches
    }

    func reportLearningLookupFailure(_ error: Error) {
        let now = ContinuousClock.now
        if let lastLearningLookupFailureLog,
            now - lastLearningLookupFailureLog < Self.learningLookupFailureLogInterval
        {
            return
        }
        lastLearningLookupFailureLog = now
        NSLog("Failed to look up learning memory for annotations: \(error)")
    }

    /// dirtyフラグが立っている間はコミットの契機ごとに再試行するため、ディスク障害が続くとコミットごとにログが出てしまう
    func reportLearningCommitFailure(_ error: Error) {
        let now = ContinuousClock.now
        if let lastLearningCommitFailureLog,
            now - lastLearningCommitFailureLog < Self.learningCommitFailureLogInterval
        {
            return
        }
        lastLearningCommitFailureLog = now
        NSLog("Failed to persist learning memory: \(error)")
    }
}

// MARK: - 接続ごとの組成セッション

/// 1つのソケットクライアントに結び付いたIME組成セッション
///
/// HazkeyServerは、接続を受け入れるたびにHazkeyServerStateを1つ生成し、切断時に破棄する
/// 重い変換エンジン、設定、ユーザ辞書、絵文字プロバイダはサーバ全体のsharedオブジェクトに置く
/// このオブジェクトが所有するのは組成ごとの状態 (組成テキスト、候補リスト、Shift/サブモードフラグ、Zenzai左文脈) と、
/// 共有変換エンジン内のセッション単位の状態 (ラティス、確定済みデータ、Zenzai/予測キャッシュ) を選択するKanaKanjiConverter.ConversionSessionIDのみ
///
/// 組成状態に触れる変換エンジン呼び出しは全てwithConversionSession内で行い、同時接続のクライアント同士が互いの未確定入力を参照しないようにする
/// 学習メモリはサーバ全体で共有する
class HazkeyServerState {
    let shared: HazkeySharedResources
    let conversionSessionID: KanaKanjiConverter.ConversionSessionID

    var composingText: ComposingTextBox = ComposingTextBox()
    var currentCandidateList: [DisplayedCandidate]?
    /// currentCandidateListのモード (サジェストまたは変換)
    /// 候補の学習データ削除後は同じモードでリストを再構築する
    /// サジェストモードのリストを非予測リストとして再構築するとライブ変換状態が壊れる
    /// makeCandidatesResultの呼び出しごとに記録し、nilでないcurrentCandidateListと常に同期させる
    var currentCandidateListIsSuggest = false

    var isShiftPressedAlone = false
    var shiftPressedAt: ContinuousClock.Instant?
    var isSubInputMode = false
    /// [Shift]キーの押下・解放をタップとみなす最長時間
    /// これより長い押下は長押しとして扱い、サブ入力モードを切り替えない
    private static let shiftTapMaxDuration: Duration = .milliseconds(500)
    var zenzaiLeftContext = ""

    private var isClosed = false

    // MARK: - 共有リソースへの転送アクセサ

    // 保存先をsharedに移した後も、既存のstate.xxx呼び出し箇所 (ProtocolHandler、テスト) を変更せずにコンパイルできるようにする
    var serverConfig: HazkeyServerConfig { shared.serverConfig }
    var converter: KanaKanjiConverter { shared.converter }
    var userDictionary: UserDictionary { shared.userDictionary }
    var emojiProvider: EmojiCandidateProvider? { shared.emojiProvider }
    var baseConvertRequestOptions: ConvertRequestOptions {
        get { shared.baseConvertRequestOptions }
        set { shared.baseConvertRequestOptions = newValue }
    }
    var keymap: Keymap {
        get { shared.keymap }
        set { shared.keymap = newValue }
    }
    var currentTableName: String {
        get { shared.currentTableName }
        set { shared.currentTableName = newValue }
    }
    var learningDataNeedsCommit: Bool {
        get { shared.learningDataNeedsCommit }
        set { shared.learningDataNeedsCommit = newValue }
    }

    convenience init() {
        self.init(emojiDictionaryURL: nil)
    }

    /// Parameter emojiDictionaryURL: テスト用に注入する辞書URL
    ///                               nilの場合は、本番用E17アセットを使用する
    convenience init(emojiDictionaryURL: URL?) {
        self.init(shared: HazkeySharedResources(emojiDictionaryURL: emojiDictionaryURL))
    }

    init(shared: HazkeySharedResources) {
        self.shared = shared
        self.conversionSessionID = shared.converter.createSession()
        shared.registerConversionSession(conversionSessionID)
    }

    /// この接続の変換セッションを解放する
    /// 冪等であり、切断処理と後続のfd再利用時のcloseが重なって2回呼ばれても安全
    func close() {
        guard !isClosed else { return }
        isClosed = true
        shared.unregisterConversionSession(conversionSessionID)
        converter.removeSession(conversionSessionID)
    }

    /// この接続の変換セッションを有効にして、"body"を実行する
    /// 変換エンジンはサーバ全体で共有され、組成ごとの状態 (ラティス、確定済みデータ、Zenzaiキャッシュ、lastData) はセッションをキーとして管理されるため、
    /// 組成を扱う呼び出しでは先にこの接続のセッションを選択する
    private func withConversionSession<T>(_ body: () throws -> T) -> T? {
        do { return try converter.withSession(conversionSessionID, operation: body) }
        catch { NSLog("[hazkey] Conversion session unavailable: \(error)"); return nil }
    }

    /// 共有設定を再初期化した後、この接続の組成状態をリセットする
    func reinitializeConfiguration() {
        NSLog("Reinitializing state configuration...")
        shared.reinitializeConfiguration()

        self.composingText = ComposingTextBox()
        self.currentCandidateList = nil
        self.isSubInputMode = false
        self.isShiftPressedAlone = false
        self.shiftPressedAt = nil
        self.zenzaiLeftContext = ""

        NSLog("State configuration reinitialized successfully")
    }

    // MARK: - 共有学習処理への転送

    // "ProtocolHandler"とテストが引き続き、"state.*"を呼べるようにする薄い転送メソッド
    func clearProfileLearningData() -> Hazkey_ResponseEnvelope {
        shared.clearProfileLearningData()
    }

    func listLearningEntries(
        query: String,
        offset: UInt32,
        limit: UInt32
    ) throws -> (entries: [Hazkey_Config_LearningHistoryEntry], totalCount: Int) {
        try shared.listLearningEntries(query: query, offset: offset, limit: limit)
    }

    func forgetLearningSurfaces(_ surfaces: [(reading: String, word: String)]) throws -> UInt32 {
        try shared.forgetLearningSurfaces(surfaces)
    }

    func forgetLearningEntries(
        _ keys: [(reading: String, word: String, lcid: UInt32, rcid: UInt32)]
    ) throws -> UInt32 {
        try shared.forgetLearningEntries(keys)
    }

    func setContext(surroundingText: String, anchorIndex: Int) -> Hazkey_ResponseEnvelope {
        let clamped = max(0, min(anchorIndex, surroundingText.count))
        if clamped != anchorIndex { NSLog("[hazkey] setContext: anchor clamped \(anchorIndex)->\(clamped) for length \(surroundingText.count)") }
        zenzaiLeftContext = String(surroundingText.prefix(clamped))
        // Zenzaiモードは"makeCandidatesResult"で、この接続の"zenzaiLeftContext"からリクエストごとに計算する
        // その間に、"baseConvertRequestOptions.zenzaiMode"を読む箇所はないため、ここに保存しても使用されない
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    /// ComposingText

    func createComposingTextInstanse() -> Hazkey_ResponseEnvelope {
        composingText = ComposingTextBox()
        currentCandidateList = nil
        zenzaiLeftContext = ""
        isSubInputMode = false
        isShiftPressedAlone = false
        shiftPressedAt = nil
        // 新しい組成の開始時にこの接続の変換セッションを破棄し、同じ入力でも前の組成のラティスを再利用して新たに学習した候補が隠れないようにする
        // 1つの組成内での逐次変換ではセッションを引き続き再利用する
        _ = withConversionSession { converter.stopComposition() }
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    func inputChar(inputString: String) -> Hazkey_ResponseEnvelope {
        guard let inputChar = inputString.first else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "failed to get first unicode character"
            }
        }
        isSubInputMode =
            isSubInputMode
            || (isShiftPressedAlone
                && serverConfig.getSubModeEntryPointChars().contains(inputChar))
        isShiftPressedAlone = false
        shiftPressedAt = nil
        if isSubInputMode {
            composingText.value.insertAtCursorPosition(String(inputChar), inputStyle: .direct)
        } else {
            let piece: InputPiece
            if let (intentionChar, overrideInputChar) = keymap[inputChar] {
                piece = .key(
                    intention: intentionChar, input: overrideInputChar ?? inputChar, modifiers: [])
            } else {
                piece = .character(inputChar)
            }

            composingText.value.insertAtCursorPosition([
                ComposingText.InputElement(
                    piece: piece,
                    inputStyle: .mapped(id: .tableName(currentTableName)))
            ])
        }
        return Hazkey_ResponseEnvelope.with { $0.status = .success }
    }

    func processModifierEvent(
        modifier: Hazkey_Commands_ModifierEvent.ModifierType,
        event: Hazkey_Commands_ModifierEvent.EventType
    ) -> Hazkey_ResponseEnvelope {
        switch modifier {
        case .shift:
            switch event {
            case .press:
                isShiftPressedAlone = true
                shiftPressedAt = ContinuousClock.now
            case .release:
                if isShiftPressedAlone {
                    if let start = shiftPressedAt {
                        if ContinuousClock.now - start < Self.shiftTapMaxDuration {
                            isSubInputMode.toggle()
                        }
                    } else {
                        isSubInputMode.toggle()
                    }
                    isShiftPressedAlone = false
                    shiftPressedAt = nil
                }
            case .cancel:
                // [Shift]が別のキー (修飾キーまたは文字キー) と組み合わされた状態で離された
                // サブ入力 (直接入力) モードは切り替えない
                isShiftPressedAlone = false
                shiftPressedAt = nil
            case .unspecified, .UNRECOGNIZED(_):
                NSLog("Unexpected event type")
                return Hazkey_ResponseEnvelope.with {
                    $0.status = .failed
                    $0.errorMessage = "Unexpected event type"
                }
            }
        case .unspecified, .UNRECOGNIZED(_):
            NSLog("Unexpected modifier type")
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Unexpected modifier type"
            }
        }
        return Hazkey_ResponseEnvelope.with { $0.status = .success }
    }

    func getCurrentInputMode() -> Hazkey_ResponseEnvelope {
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
            $0.currentInputModeInfo = Hazkey_Commands_CurrentInputModeInfo.with {
                $0.inputMode = isSubInputMode ? .direct : .normal
            }
        }
    }

    func saveLearningData() -> Hazkey_ResponseEnvelope {
        shared.saveLearningData()
    }

    func reloadZenzaiModel() -> Hazkey_ResponseEnvelope {
        shared.reloadZenzaiModel()
    }

    func deleteLeft() -> Hazkey_ResponseEnvelope {
        composingText.value.deleteBackwardFromCursorPosition(count: 1)
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    func deleteRight() -> Hazkey_ResponseEnvelope {
        composingText.value.deleteForwardFromCursorPosition(count: 1)
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    func completePrefix(candidateIndex: Int) -> Hazkey_ResponseEnvelope {
        // 範囲を先に確認する
        // Swiftの配列添字は範囲外でトラップするため、不正なクライアント添字でサーバをクラッシュさせない
        guard let list = currentCandidateList, list.indices.contains(candidateIndex) else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Candidate index \(candidateIndex) not found."
            }
        }
        let entry = list[candidateIndex]
        switch entry {
        case .fromConverter(let completedCandidate):
            composingText.value.prefixComplete(composingCount: completedCandidate.composingCount)
            let learnsFromCandidate = !completedCandidate.data.contains {
                $0.metadata.contains(.isFromUserDictionary)
            }
            _ = withConversionSession {
                converter.setCompletedData(completedCandidate)
                if learnsFromCandidate { converter.updateLearningData(completedCandidate) }
            }
            // 学習メモリはサーバ全体で共有するため、学習データを更新しなかった確定でdirtyフラグを消してはならない
            // 他の接続にある永続化待ちデータが失われる
            if learnsFromCandidate { learningDataNeedsCommit = true }
        case .fromUserDict:
            // ユーザ辞書エントリは常に読み全体に一致するため、組成テキストを消去するだけでよい
            // 変換エンジンの学習ストアには追加しない
            composingText = ComposingTextBox()
        case .fromDateProvider:
            // 日付プロバイダ候補は相対日付トリガーワード (きょう/きのう/...) の読み全体に一致し、計算した日付文字列を生成する
            // 確定時は、".fromUserDict"と同様に、組成テキストを消去し学習ストアには追加しない
            composingText = ComposingTextBox()
        case .fromKanaNumberProvider:
            // かな数字の特殊候補はかな数詞の読み全体に一致する
            // 確定時は ".fromDateProvider"と同様に、組成テキストを消去し学習ストアには追加しない
            composingText = ComposingTextBox()
        case .fromEmoji(_, let composingCount):
            // 絵文字直接変換候補は一致した正規化クエリのprefixだけを消費し、後続suffixは保持する
            // 変換エンジンの確定 / 学習APIには触れないため、共有dirtyフラグは変更しない (他の接続に永続化待ちの学習がある可能性がある)
            composingText.value.prefixComplete(composingCount: composingCount)
        }
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    /// 予測候補を先頭の固定表記として受け入れる (upstream ad714fe / #357)
    /// completePrefixと異なり確定は行わず、候補の残りrubyを組成テキストに追加し、受け入れた表記を以降のZenzai変換の先頭制約とする
    ///　まだ確定していないため学習データは更新しない
    func acceptPrediction(candidateIndex: Int) -> Hazkey_ResponseEnvelope {
        // 範囲を先に確認する
        //　Swiftの配列添字 (およびそのoptional chaining) は範囲外でnilを返さずトラップするため、不正なクライアント添字でサーバをクラッシュさせない
        guard let list = currentCandidateList, list.indices.contains(candidateIndex) else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Candidate index \(candidateIndex) not found."
            }
        }
        guard case .fromConverter(let candidate) = list[candidateIndex] else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Candidate index \(candidateIndex) is not a converter candidate."
            }
        }
        var composing = composingText.value
        let accepted = withConversionSession {
            converter.acceptPredictionCandidate(candidate, composingText: &composing)
        } ?? false
        guard accepted else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Candidate \(candidate.text) is not an applicable prediction."
            }
        }
        composingText.value = composing
        currentCandidateList = nil
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    func moveCursor(offset: Int) -> Hazkey_ResponseEnvelope {
        _ = composingText.value.moveCursorFromCursorPosition(count: offset)
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    func adjustClauseBoundary(offset: Int) -> Hazkey_ResponseEnvelope {
        isShiftPressedAlone = false
        shiftPressedAt = nil
        if composingText.value.isEmpty {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .success
                $0.clauseBoundaryResult = Hazkey_Commands_ClauseBoundaryResult()
            }
        }

        let minCursorPosition = 1
        let maxBackwardOffset =
            minCursorPosition - composingText.value.convertTargetCursorPosition
        let maxForwardOffset =
            composingText.value.convertTarget.count
            - composingText.value.convertTargetCursorPosition
        let clampedOffset = max(min(offset, maxForwardOffset), maxBackwardOffset)
        _ = composingText.value.moveCursorFromCursorPosition(count: clampedOffset)

        let (candidatesResult, serverCandidates) = makeCandidatesResult(
            is_suggest: false)
        currentCandidateList = serverCandidates

        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
            $0.clauseBoundaryResult = Hazkey_Commands_ClauseBoundaryResult.with {
                $0.candidates = candidatesResult
                $0.hiragana = composingText.value.toHiragana()
            }
        }
    }

    /// ComposingText -> Characters

    /// 構造APIであり表示設定は適用しない
    /// auxTextModeによるAUXの表示・非表示は、
    /// フロントエンド側 (hazkey-frontend-common/composing_cursor_view.h - hazkey::frontend::shouldShowAuxText) が判断する
    /// ここで空文字列を返すと、preeditのキャレット位置まで設定に従属してしまうため、常に実際の3分割を返す
    func getHiraganaWithCursor() -> Hazkey_ResponseEnvelope {
        func safeSubstring(_ text: String, start: Int, end: Int) -> String {
            guard start >= 0, end >= 0, start < text.count, end <= text.count, start < end else {
                return ""
            }

            let startIndex = text.index(text.startIndex, offsetBy: start)
            let endIndex = text.index(text.startIndex, offsetBy: end)

            return String(text[startIndex..<endIndex])
        }

        let hiragana = composingText.value.toHiragana()
        let cursorPos = composingText.value.convertTargetCursorPosition

        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
            $0.textWithCursor = Hazkey_Commands_TextWithCursor.with {
                $0.beforeCursosr = safeSubstring(hiragana, start: 0, end: cursorPos)
                $0.onCursor = safeSubstring(hiragana, start: cursorPos, end: cursorPos + 1)
                $0.afterCursor = safeSubstring(hiragana, start: cursorPos + 1, end: hiragana.count)
            }
        }
    }

    func getComposingString(
        charType: Hazkey_Commands_GetComposingString.CharType,
        currentPreedit: String
    ) -> Hazkey_ResponseEnvelope {
        let result: String
        switch charType {
        case .hiragana:
            result = composingText.value.toHiragana()
        case .katakanaFull:
            result = composingText.value.toKatakana(true)
        case .katakanaHalf:
            result = composingText.value.toKatakana(false)
        case .alphabetFull:
            result = cycleAlphabetCase(
                composingText.value.toAlphabet(true), preedit: currentPreedit)
        case .alphabetHalf:
            result = cycleAlphabetCase(
                composingText.value.toAlphabet(false), preedit: currentPreedit)
        case .UNRECOGNIZED:
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "unrecognized charType: \(charType.rawValue)"
            }
        }
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
            $0.text = result
        }
    }

    /// 候補

    func ensureCompositionSeparatorForConversion() {
        guard composingText.value.isAtEndIndex else {
            return
        }
        if composingText.value.input.last?.piece == .compositionSeparator {
            return
        }
        composingText.value.insertAtCursorPosition([
            ComposingText.InputElement(
                piece: .compositionSeparator,
                inputStyle: .mapped(id: .tableName(currentTableName)))
        ])
    }

    func candidateRequestText(is_suggest: Bool) -> ComposingText {
        let usePrefixTarget = !is_suggest && !composingText.value.isAtEndIndex
        return usePrefixTarget
            ? composingText.value.prefixToCursorPosition()
            : composingText.value
    }

    /// 永続化済み学習メモリへの一括ポイント照会により、変換候補の"has_learning_entry"を設定する
    ///
    /// 各候補の両方の読みを1回の照会にまとめ、いずれかが一致すれば注釈を付ける
    /// 表示候補数にかかわらず、リクエストあたりの呼び出しは1回
    ///
    /// - Important: "converter.requestCandidates(...)"の後にのみ呼び出すこと
    ///              変換エンジンはその呼び出し内で有効プロファイルのmemoryDirectoryURLを遅延適用するため、
    ///              プロファイル切替直後に先行照会すると前プロファイルのディレクトリを読む
    /// - Note: 照会失敗時は全ての候補に注釈を付けない
    ///         ポイント照会導入前と同じ保守的な縮退動作
    private func annotateLearningEntries(
        readings: [CandidateLearningReadings],
        into clientCandidates: inout [Hazkey_Commands_CandidatesResult.Candidate]
    ) {
        var lookupReadings: Set<String> = []
        for entry in readings {
            if !entry.prefixReading.isEmpty { lookupReadings.insert(entry.prefixReading) }
            if !entry.fullRuby.isEmpty { lookupReadings.insert(entry.fullRuby) }
        }
        guard !lookupReadings.isEmpty else { return }
        let learnedSurfaces: Set<LearningSurfaceKey>
        do {
            learnedSurfaces = try shared.learningSurfaceKeys(forReadings: Array(lookupReadings))
        } catch {
            shared.reportLearningLookupFailure(error)
            return
        }
        guard !learnedSurfaces.isEmpty else { return }
        for index in clientCandidates.indices where index < readings.count {
            let word = clientCandidates[index].text
            let entry = readings[index]
            let isLearned =
                (!entry.prefixReading.isEmpty
                    && learnedSurfaces.contains(
                        LearningSurfaceKey(reading: entry.prefixReading, word: word)))
                || (!entry.fullRuby.isEmpty
                    && learnedSurfaces.contains(
                        LearningSurfaceKey(reading: entry.fullRuby, word: word)))
            clientCandidates[index].hasLearningEntry_p = isLearned
        }
    }

    private func makeCandidatesResult(
        is_suggest: Bool
    ) -> (Hazkey_Commands_CandidatesResult, [DisplayedCandidate]) {
        self.currentCandidateListIsSuggest = is_suggest
        let perfProbe = PerfProbe.shared
        let candidateStartedAt = perfProbe?.now()
        var userDictionaryStartedAt = candidateStartedAt
        var userDictionaryFinishedAt = candidateStartedAt
        var zenzaiInferenceNanoseconds: UInt64?
        // 既にレスポンスへ出力した表記
        // 変換エンジンは、predictionResultsとmainResultsの各配列内では個別に重複排除するが、両配列間では同じ表記が重なることがある
        // (ユーザ辞書の単語が自身の最良ノードの予測としても現れるなど)
        // そのため連結後のリストでは後続の重複を除外する
        var appendedTexts: Set<String> = []

        // 以下で出力する全変換候補のカタカナ正規化済み読み
        // clientCandidatesと位置を対応させる
        // 「削除可能」注釈は、変換エンジンの応答後にこれらを使用した1回の一括ポイント照会で解決する - "annotateLearningEntries"を参照
        var annotationReadings: [CandidateLearningReadings] = []

        func canAppend(
            isSuggest: Bool,
            currentCount: Int,
            limit: Int
        ) -> Bool {
            return !isSuggest || currentCount < limit
        }

        func appendCandidate(
            _ candidate: Candidate,
            fullHiraganaPreedit: String,
            requestHiraganaPreeditLen: Int,
            serverCandidates: inout [DisplayedCandidate],
            clientCandidates: inout [Hazkey_Commands_CandidatesResult.Candidate]
        ) {
            appendedTexts.insert(candidate.text)

            var clientCandidate = Hazkey_Commands_CandidatesResult.Candidate()
            clientCandidate.text = candidate.text

            let endIndex = min(candidate.rubyCount, requestHiraganaPreeditLen)
            clientCandidate.subHiragana = String(fullHiraganaPreedit.dropFirst(endIndex))
            annotationReadings.append(
                candidate.learningReadings(
                    truncatedTo: String(fullHiraganaPreedit.prefix(endIndex))))

            clientCandidates.append(clientCandidate)
            serverCandidates.append(.fromConverter(candidate))
        }

        var options = baseConvertRequestOptions
        let N_best = {
            if is_suggest
                && serverConfig.currentProfile.suggestionListMode
                    == Hazkey_Config_Profile.SuggestionListMode.suggestionListDisabled
            {
                // 自動変換用
                return 1
            } else if is_suggest {
                return Int(serverConfig.currentProfile.numSuggestions)
            } else {
                return Int(serverConfig.currentProfile.numCandidatesPerPage)
            }
        }()

        options.N_best = N_best

        let usePrediction: Bool =
            is_suggest
            && serverConfig.currentProfile.suggestionListMode
                == Hazkey_Config_Profile.SuggestionListMode.suggestionListShowPredictiveResults

        options.requireJapanesePrediction = usePrediction ? .manualMix : .disabled
        options.zenzaiMode = serverConfig.genZenzaiMode(
            leftContext: zenzaiLeftContext,
            requestRichCandidates: HazkeyServerConfig.requestRichCandidates(
                for: serverConfig.currentProfile, isSuggestion: is_suggest)
        )
        let zenzai: String = if case .off = options.zenzaiMode { "off" } else { "on" }
        userDictionaryStartedAt = perfProbe?.now()
        defer {
            if let candidateStartedAt, let userDictionaryStartedAt, let userDictionaryFinishedAt {
                perfProbe?.recordCandidateStages(
                    userDictionaryStartedAt: userDictionaryStartedAt,
                    userDictionaryFinishedAt: userDictionaryFinishedAt,
                    candidateStartedAt: candidateStartedAt,
                    zenzai: zenzai,
                    zenzaiInferenceNanoseconds: zenzaiInferenceNanoseconds)
            }
        }

        let copiedComposingText = candidateRequestText(is_suggest: is_suggest)

        // ユーザ辞書を変換エンジンに注入し、各エントリが指定品詞 (CID) の接続コスト順位付けに参加するようにする
        // 注入自体はインスタンス単位 (全接続で共有) の処理なので、変換セッション外で実行する
        if serverConfig.currentProfile.useUserDictionaryEffective {
            let reloaded = userDictionary.reloadIfNeeded()
            if reloaded || !shared.userDictInjected {
                converter.importDynamicUserDictionary(userDictionary.toDicdataElements())
                shared.userDictInjected = true
                NSLog("[hazkey] Injected \(userDictionary.count) user dictionary entries into engine")
            }
        } else if shared.userDictInjected {
            converter.importDynamicUserDictionary([])  // OFF時に消去
            shared.userDictInjected = false
        }
        userDictionaryFinishedAt = perfProbe?.now()

        var candidatesResult = Hazkey_Commands_CandidatesResult()
        if zenzai == "on" {
            _ = ZenzInferencePerf.shared.consumeElapsedNanoseconds()
        }
        guard
            let converted = withConversionSession({
                converter.requestCandidates(copiedComposingText, options: options)
            })
        else {
            // セッションは接続終了時にのみ削除され、単一スレッドのサーバループが終了済みセッションで変換することもないが、念のためトラップせず空リストを返す
            var emptyResult = Hazkey_Commands_CandidatesResult()
            emptyResult.liveTextIndex = -1
            return (emptyResult, [])
        }
        if zenzai == "on" {
            zenzaiInferenceNanoseconds = ZenzInferencePerf.shared.consumeElapsedNanoseconds()
        }
        let fullHiraganaPreedit = composingText.value.toHiragana()
        let hiraganaPreedit = copiedComposingText.toHiragana()
        let hiraganaPreeditLen = hiraganaPreedit.count
        var serverCandidates: [DisplayedCandidate] = []
        var clientCandidates: [Hazkey_Commands_CandidatesResult.Candidate] = []

        // prediction=disabledの場合、predictionResultsは空
        for candidate in converted.predictionResults {
            guard
                canAppend(
                    isSuggest: is_suggest, currentCount: serverCandidates.count, limit: N_best)
            else { break }

            appendCandidate(
                candidate,
                fullHiraganaPreedit: fullHiraganaPreedit,
                requestHiraganaPreeditLen: hiraganaPreeditLen,
                serverCandidates: &serverCandidates,
                clientCandidates: &clientCandidates)
        }

        candidatesResult.liveTextIndex = -1
        for candidate in converted.mainResults {
            let isExactMatch = candidate.rubyCount == hiraganaPreedit.count
            let limitReached = !canAppend(
                isSuggest: is_suggest, currentCount: serverCandidates.count, limit: N_best)

            // live textを検索
            if candidatesResult.liveText.isEmpty && isExactMatch {
                candidatesResult.liveText = candidate.text
                // 既に追加したエントリと重複する (同じ表記が学習済み予測/先行結果として出力済み)
                // 同じ表記を二重追加せず、先行エントリを維持してlive textをそこへ関連付ける
                if let keptIndex = serverCandidates.firstIndex(where: { entry in
                    if case .fromConverter(let kept) = entry { return kept.text == candidate.text }
                    return false
                }) {
                    candidatesResult.liveTextIndex = Int32(keptIndex)
                    if limitReached { break }
                    continue
                }
                candidatesResult.liveTextIndex = Int32(serverCandidates.count)
                if is_suggest && serverCandidates.count >= N_best {
                    serverCandidates.append(.fromConverter(candidate))
                    break
                }
            }

            if limitReached && !candidatesResult.liveText.isEmpty { break }

            if appendedTexts.contains(candidate.text) {
                // ソース間の重複 (学習済み予測とユーザ辞書の衝突)
                // 先行エントリがこの表記をすでに表すため、重複分をスキップする
                continue
            }

            appendCandidate(
                candidate,
                fullHiraganaPreedit: fullHiraganaPreedit,
                requestHiraganaPreeditLen: hiraganaPreeditLen,
                serverCandidates: &serverCandidates,
                clientCandidates: &clientCandidates
            )
        }

        // ここで「削除可能」注釈を解決する
        // 変換候補は全て出力済みであり、以下の注入処理は任意の位置にエントリを挿入して、annotationReadingsとの位置対応を崩すため
        annotateLearningEntries(readings: annotationReadings, into: &clientCandidates)

        // === Emoji 17.0 直接候補の注入 ===
        // extended_emoji設定が有効な通常変換 (is_suggest == false) のみ
        // 変換エンジンの主候補の後、日付/数値の後処理の前に追加する
        // appendedTextsと文字列完全一致で重複排除し、liveText/liveTextIndexは変更せず、学習注釈も付けない
        // テキストはバイト列のまま保持する
        if !is_suggest, serverConfig.currentProfile.extendedEmojiEffective,
            let emojiProvider
        {
            let emojiItems = emojiProvider.emojiCandidates(for: hiraganaPreedit)
            if !emojiItems.isEmpty {
                for item in emojiItems {
                    guard !appendedTexts.contains(item.text) else { continue }
                    appendedTexts.insert(item.text)
                    // 一致した正規化クエリの長さを、残りpreeditと同じ候補のprefix確定の両方に使用する
                    let matchedCount = item.query.count
                    let remaining = String(
                        fullHiraganaPreedit.dropFirst(min(matchedCount, fullHiraganaPreedit.count)))
                    var clientCandidate = Hazkey_Commands_CandidatesResult.Candidate()
                    clientCandidate.text = item.text
                    clientCandidate.subHiragana = remaining
                    serverCandidates.append(
                        .fromEmoji(
                            word: item.text, composingCount: .inputCount(matchedCount)))
                    clientCandidates.append(clientCandidate)
                }
            }
        }

        // === 相対日付候補の注入 (後処理) ===
        // 組成中のひらがなが相対日付トリガーワード (きょう、きのうなど) に完全一致し、かつ変換エンジンが漢字表現 (今日、昨日など) を返した場合、
        // 書式化した日付文字列 (yyyy年M月d日、yyyy-MM-ddなど) を注入する
        // completePrefixとのindex対応のためserverCandidatesに、wireシリアライズのためclientCandidatesにも、漢字表現の直後に候補を挿入する
        //
        // フォールバック (synthesizeKanjiWhenMissing):
        // 変換エンジンが漢字アンカーを出さず (例: さきおとつい → 一昨昨日がない)、トリガーが明示的に有効化している場合は、合成アンカーと日付文字列を両リストの末尾に追加する
        // 挿入は行わず、liveTextIndexも変更しない
        if serverConfig.currentProfile.useRelativeDateEffective {
            if let trigger = RelativeDateProvider.detectTrigger(
                composingHiragana: hiraganaPreedit)
            {
                // serverCandidates内の漢字表現のindexを検索する
                // 漢字形が存在する場合のみ注入し、「漢字表現が有る時だけ挿入」というユーザ設定に従う
                let kanjiIndex = serverCandidates.firstIndex(where: { dc in
                    if case .fromConverter(let c) = dc { return c.text == trigger.kanji }
                    return false
                })

                if let kanjiIndex = kanjiIndex {
                    // 通常経路: 変換エンジンのアンカーが見つかったため、漢字表現の直後に日付文字列を挿入する
                    let dateStrings = RelativeDateProvider.generateDateStrings(for: trigger)
                    var insertedCount = 0
                    for dateStr in dateStrings {
                        // サジェストモードでは、N_bestの上限を守る
                        guard canAppend(
                            isSuggest: is_suggest,
                            currentCount: serverCandidates.count,
                            limit: N_best
                        ) else { break }

                        var clientCandidate = Hazkey_Commands_CandidatesResult.Candidate()
                        clientCandidate.text = dateStr
                        // 日付候補は読み全体を消費するため、subHiraganaは残りpreedit (トリガー完全一致なら空) とする
                        clientCandidate.subHiragana = String(
                            fullHiraganaPreedit.dropFirst(hiraganaPreeditLen))

                        let insertAt = kanjiIndex + 1 + insertedCount
                        serverCandidates.insert(.fromDateProvider(word: dateStr), at: insertAt)
                        clientCandidates.insert(clientCandidate, at: insertAt)
                        insertedCount += 1
                    }
                } else if trigger.synthesizeKanjiWhenMissing {
                    // フォールバック経路: 変換エンジンが漢字アンカーを返さず、このトリガーが合成を有効化している
                    // 合成アンカーと日付文字列を末尾に追加する
                    // liveTextIndexを変更せず、既存エントリより前にも挿入しない
                    //
                    // 上限はserverCandidates.countではなく、表示枠であるclientCandidates.countで確認する
                    // サジェストモードではlive候補がserverCandidatesにのみ存在して非表示の場合があり、serverCandidatesを使うと表示枠を誤って消費する
                    if canAppend(
                        isSuggest: is_suggest,
                        currentCount: clientCandidates.count,
                        limit: N_best
                    ) {
                        // 合成漢字アンカー (確定時はfromDateProviderとして扱う)
                        var anchorClientCandidate = Hazkey_Commands_CandidatesResult.Candidate()
                        anchorClientCandidate.text = trigger.kanji
                        anchorClientCandidate.subHiragana = String(
                            fullHiraganaPreedit.dropFirst(hiraganaPreeditLen))
                        serverCandidates.append(.fromDateProvider(word: trigger.kanji))
                        clientCandidates.append(anchorClientCandidate)

                        // 合成アンカーに続く日付文字列
                        let dateStrings = RelativeDateProvider.generateDateStrings(for: trigger)
                        for dateStr in dateStrings {
                            guard canAppend(
                                isSuggest: is_suggest,
                                currentCount: clientCandidates.count,
                                limit: N_best
                            ) else { break }

                            var clientCandidate = Hazkey_Commands_CandidatesResult.Candidate()
                            clientCandidate.text = dateStr
                            clientCandidate.subHiragana = String(
                                fullHiraganaPreedit.dropFirst(hiraganaPreeditLen))
                            serverCandidates.append(.fromDateProvider(word: dateStr))
                            clientCandidates.append(clientCandidate)
                        }
                    }
                }
            }
        }

        // === かな数字の特殊候補を注入 (後処理) ===
        // 変換エンジンは、"CIDData.数"により日本語数詞候補を識別する
        // エンジンが返すASCII十進候補を確定値とし、サーバ層ではその値を承認済みの字形群に対応付けるだけとする
        if !is_suggest && !KanaNumberProvider.isAsciiDecimal(hiraganaPreedit) {
            let numberAnchorIndices = serverCandidates.indices.filter { idx in
                guard case .fromConverter(let c) = serverCandidates[idx] else { return false }
                return c.rubyCount == hiraganaPreeditLen
                    && c.data.contains { $0.lcid == CIDData.数.cid && $0.rcid == CIDData.数.cid }
            }
            let decimalAnchor = numberAnchorIndices.compactMap { idx -> (index: Int, digits: String)? in
                guard case .fromConverter(let c) = serverCandidates[idx] else { return nil }
                guard KanaNumberProvider.isAsciiDecimal(c.text) else { return nil }
                return (idx, c.text)
            }.first

            if let decimalAnchor {
                let existingTexts = Set(
                    serverCandidates.compactMap { dc -> String? in
                        guard case .fromConverter(let c) = dc else { return nil }
                        return c.text
                    })
                let generatedTexts = KanaNumberProvider.generateCandidates(
                    forDecimalDigits: decimalAnchor.digits)
                    .filter { !existingTexts.contains($0) }
                if !generatedTexts.isEmpty
                    && canAppend(
                        isSuggest: is_suggest, currentCount: serverCandidates.count, limit: N_best)
                {
                    let insertAt = decimalAnchor.index + 1
                    for (offset, text) in generatedTexts.enumerated() {
                        var clientCandidate = Hazkey_Commands_CandidatesResult.Candidate()
                        clientCandidate.text = text
                        clientCandidate.subHiragana = String(
                            fullHiraganaPreedit.dropFirst(hiraganaPreeditLen))
                        serverCandidates.insert(
                            .fromKanaNumberProvider(word: text), at: insertAt + offset)
                        clientCandidates.insert(clientCandidate, at: insertAt + offset)
                    }

                    if Int32(insertAt) <= candidatesResult.liveTextIndex {
                        candidatesResult.liveTextIndex += Int32(generatedTexts.count)
                    }
                }
            }
        }

        candidatesResult.candidates = clientCandidates

        if serverConfig.currentProfile.autoConvertMode
            == Hazkey_Config_Profile.AutoConvertMode.autoConvertForMultipleChars
        {
            let minChars = serverConfig.currentProfile.autoConvertMinChars > 0
                ? Int(serverConfig.currentProfile.autoConvertMinChars) : 2
            if hiraganaPreedit.count < minChars {
                candidatesResult.liveText = ""
                candidatesResult.liveTextIndex = -1
            }
        } else if serverConfig.currentProfile.autoConvertMode
            == Hazkey_Config_Profile.AutoConvertMode.autoConvertDisabled
        {
            candidatesResult.liveText = ""
            candidatesResult.liveTextIndex = -1
        }

        candidatesResult.pageSize = {
            if is_suggest
                && serverConfig.currentProfile.suggestionListMode
                    == Hazkey_Config_Profile.SuggestionListMode.suggestionListDisabled
            {
                return 0
            } else if is_suggest {
                return serverConfig.currentProfile.numSuggestions
            } else {
                return serverConfig.currentProfile.numCandidatesPerPage
            }
        }()

        return (candidatesResult, serverCandidates)
    }

    // TODO: エラーメッセージを返す
    func getCandidates(is_suggest: Bool) -> Hazkey_ResponseEnvelope {
        if !is_suggest {
            ensureCompositionSeparatorForConversion()
        }
        let (candidatesResult, serverCandidates) = makeCandidatesResult(is_suggest: is_suggest)
        self.currentCandidateList = serverCandidates

        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
            $0.candidates = candidatesResult
        }
    }

    /// フォーカス中の候補に対応する学習メモリエントリを削除し、記憶しているモードで候補リストを再構築する
    ///
    /// CID違いをまたいで (reading, word) の表層ペアで照合する
    /// 「削除可能」注釈と同じ規則なので、削除可能と表示された候補を必ず削除できる
    /// forgetLearningMemoryは直ちにディスクへ永続化し、変換エンジンのメモリキャッシュをリセットするため、再構築したリストに削除が反映される
    func deleteCandidateLearningData(candidateIndex: Int) -> Hazkey_ResponseEnvelope {
        // 範囲を先に確認する
        // Swiftの配列添字は範囲外でトラップするため、不正なクライアント添字でサーバをクラッシュさせない
        guard let list = currentCandidateList, list.indices.contains(candidateIndex) else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Candidate index \(candidateIndex) not found."
            }
        }
        // 学習エントリを持てるのは変換エンジン候補のみ
        // レガシーユーザ辞書/日付/かな数字/絵文字注入候補には学習データがないため、エラーではなく「削除なし」として返す
        guard case .fromConverter(let candidate) = list[candidateIndex] else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .success
                $0.deleteCandidateLearningDataResult = Hazkey_Commands_DeleteCandidateLearningDataResult.with {
                    $0.deletedCount = 0
                }
            }
        }

        // appendCandidateと同じ式で候補の読みを算出する
        let fullHiraganaPreedit = composingText.value.toHiragana()
        let requestHiraganaPreeditLen = candidateRequestText(
            is_suggest: currentCandidateListIsSuggest
        ).toHiragana().count
        let readings = candidate.learningReadings(
            truncatedTo: String(
                fullHiraganaPreedit.prefix(min(candidate.rubyCount, requestHiraganaPreeditLen))))

        // CID違いをまたいで (reading, word) に一致するものを全て集める
        // 一致なし (未学習) は、正常な「削除なし」の結果であり、エラーではない
        let matchingKeys: [(reading: String, word: String, lcid: UInt32, rcid: UInt32)]
        do {
            matchingKeys = try shared.matchingLearningEntryKeys(
                readings: [readings.prefixReading, readings.fullRuby], word: candidate.text)
        } catch {
            NSLog("Failed to enumerate learning memory for deletion: \(error)")
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Failed to enumerate learning memory: \(error)"
            }
        }
        guard !matchingKeys.isEmpty else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .success
                $0.deleteCandidateLearningDataResult = Hazkey_Commands_DeleteCandidateLearningDataResult.with {
                    $0.deletedCount = 0
                }
            }
        }

        let deletedCount: UInt32
        do {
            deletedCount = try forgetLearningEntries(matchingKeys)
        } catch {
            NSLog("Failed to forget learning entries: \(error)")
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Failed to forget learning entries: \(error)"
            }
        }

        // 削除前と同じモードで候補リストを再構築する
        let (candidatesResult, serverCandidates) = makeCandidatesResult(
            is_suggest: currentCandidateListIsSuggest)
        currentCandidateList = serverCandidates

        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
            $0.deleteCandidateLearningDataResult = Hazkey_Commands_DeleteCandidateLearningDataResult.with {
                $0.deletedCount = deletedCount
                $0.candidates = candidatesResult
                $0.hiragana = composingText.value.toHiragana()
            }
        }
    }

}

extension Candidate {
    /// 候補の学習メモリキーを一元的に導出する
    /// 注釈と削除ハンドラで共有し、削除可能と表示された候補を必ず削除できるようにする
    func learningReadings(truncatedTo typedPrefix: String) -> CandidateLearningReadings {
        CandidateLearningReadings(
            prefixReading: katakanaNormalized(typedPrefix),
            fullRuby: katakanaNormalized(data.map(\.ruby).joined()))
    }
}

extension Hazkey_Config_Profile {
    /// プロファイルごとのユーザ辞書設定の有効値
    /// 既存動作を維持するため、レガシー設定または未設定時はtrueを既定値とする
    var useUserDictionaryEffective: Bool {
        hasUseUserDictionary ? useUserDictionary : true
    }

    /// 相対日付候補設定の有効値
    /// 既存動作を維持するため、レガシー設定または未設定時はtrueを既定値とする
    var useRelativeDateEffective: Bool {
        let mode = specialConversionMode
        return mode.hasRelativeDate ? mode.relativeDate : true
    }
}
