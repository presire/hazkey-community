import Foundation
import KanaKanjiConverterModule
import SwiftUtils

/// 候補リストの各位置に対応するサーバ側の候補エントリ
///
/// クライアントへ送る候補 (Hazkey_Commands_CandidatesResult.Candidate) と同じ位置に並べ、確定・予測受入・学習削除の際に候補の出所を判別する
///
/// 確定処理はHazkeyServerState.completePrefix(candidateIndex:)がこの値で振り分ける
enum DisplayedCandidate {
    /// 変換エンジン (KanaKanjiConverter) が返した候補で、確定時に学習データを更新する
    case fromConverter(Candidate)
    /// 誤字の訂正エンジンが生成した訂正候補
    ///
    /// 打ち間違いを読み替えて得た候補であり、元の入力の読みとは異なる読みを持つ
    ///
    /// 確定では元の入力の先頭 (originalPrefixCount文字) だけを消費し、残りの読みは組成に残す
    ///
    /// 学習は候補の出所に従い、ユーザ辞書由来のデータを含む場合は学習しない (fromConverterと同じ規則)
    ///
    /// - Parameters:
    ///   - candidate: 変換エンジンが返した訂正後の候補
    ///   - correctedReading: カタカナに正規化した訂正後の読み (学習の注釈と削除で使う)
    ///   - originalPrefixCount: 確定で消費する元の入力の先頭文字数
    case fromTypoCorrection(candidate: Candidate, correctedReading: String, originalPrefixCount: Int)
    /// 旧方式のユーザ辞書候補 (現在は生成されない)
    ///
    /// ユーザ辞書はimportDynamicUserDictionaryでエンジンに注入する方式へ移行したため、ユーザ辞書の単語は現在fromConverterとして届く
    case fromUserDict(word: String)
    /// RelativeDateProviderが注入する相対日付候補
    ///
    /// 確定時はカーソルまでの読み (composingCount) のみを消費して、右側の読みは組成に残す
    ///
    /// 学習は行わず、共有の学習dirtyフラグも変更しない
    case fromDateProvider(word: String, composingCount: ComposingCount)
    /// KanaNumberProviderが注入する特殊数値候補 (下付き・上付き・丸囲み・ローマ数字等)
    ///
    /// 確定時はカーソルまでの読み (composingCount) のみを消費して、右側の読みは組成に残す
    ///
    /// 学習は行わず、共有の学習dirtyフラグも変更しない
    case fromKanaNumberProvider(word: String, composingCount: ComposingCount)
    /// EmojiCandidateProviderが注入するEmoji 17.0直接変換候補
    ///
    /// 確定時は一致した正規化クエリのprefix (composingCount) のみを消費して、後続の読みは組成に残す
    ///
    /// 学習は行わず、学習削除では削除件数0として扱う
    case fromEmoji(word: String, composingCount: ComposingCount)
}

/// 学習履歴の列挙・削除で発生するエラー
private enum LearningHistoryError: Error {
    /// 列挙の開始位置が列挙上限 (HazkeySharedResources.learningEnumerationLimit) を超えている
    case invalidOffset
    /// 削除対象のエントリが学習メモリに保存されていない
    case unknownEntry
    /// CID (品詞ID) の値が変換エンジンのInt型で表現できない
    case unsupportedCID
}

/// 学習メモリの1エントリを完全に識別するキー
///
/// 学習メモリは読み・表記・左右の品詞ID (CID) の組ごとに1行を保存するため、重複排除と存在確認にこの4要素を使う
private struct LearningHistoryKey: Hashable {
    /// 学習エントリの読み (カタカナ)
    let reading: String
    /// 学習エントリの表記
    let word: String
    /// 左文脈の品詞ID (CID)
    let lcid: UInt32
    /// 右文脈の品詞ID (CID)
    let rcid: UInt32
}

/// ひらがなをカタカナへ変換する
///
/// 学習メモリの読みはカタカナで保存されるため、照合前に組成テキストのひらがな読みを正規化する
///
/// ひらがな (U+3041〜U+3096) 以外の文字はそのまま残す
///
/// - Parameter text: 変換する文字列
/// - Returns: ひらがなをカタカナに置き換えた文字列
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

/// 学習履歴のエントリが検索クエリに一致するかどうかを判定する
///
/// クエリ・読み・表記をカタカナに正規化して部分一致で比較するため、ひらがなとカタカナのどちらで検索しても一致する
///
/// - Parameters:
///   - query: 設定画面の学習履歴ダイアログで入力された検索文字列
///   - reading: 学習エントリの読み
///   - word: 学習エントリの表記
/// - Returns: クエリが空、または読みか表記にクエリが含まれる場合はtrue
func learningHistoryMatches(query: String, reading: String, word: String) -> Bool {
    let normalizedQuery = katakanaNormalized(query)
    return normalizedQuery.isEmpty
        || katakanaNormalized(reading).contains(normalizedQuery)
        || katakanaNormalized(word).contains(normalizedQuery)
}

/// 変換候補が学習メモリに保存されうる2種類の読み
///
/// 学習メモリのトライは読みの完全一致で引くため、どちらもカタカナに正規化して保持する
///
/// 予測候補は入力済みの範囲より先まで読みが伸びるため、切り詰めた読みでは別のトライノードを指して一致しない
/// そのため、注釈と削除では両方の読みで照会する
struct CandidateLearningReadings {
    /// 候補の位置まで切り詰めた入力読み (通常変換の候補はこの読みで保存される)
    let prefixReading: String
    /// 候補全体の読み (予測候補はこの読みで保存される)
    ///
    /// 候補にdataが無い場合は空
    let fullRuby: String
}

/// 品詞ID (CID) の違いをまたいで学習エントリを識別する、読みと表記の組のキー
///
/// 組成テキストのひらがな読みが学習メモリ内のカタカナの読みに一致するよう、読みをカタカナに正規化する
///
/// 削除可能の注釈と学習削除の処理で同じキーを使用するため、削除可能と表示された候補は必ず削除できる
struct LearningSurfaceKey: Hashable {
    /// カタカナに正規化した読み
    let reading: String
    /// 表記
    let word: String

    /// 読みをカタカナに正規化してキーを生成する
    ///
    /// - Parameters:
    ///   - reading: 読み (ひらがなでもカタカナでもよい)
    ///   - word: 表記
    init(reading: String, word: String) {
        self.reading = katakanaNormalized(reading)
        self.word = word
    }
}

/// 全クライアント接続で共有するサーバ全体のリソース
///
/// 変換エンジン (辞書・Zenzaiモデル・学習メモリ・メモ化キャッシュ) は重いため、プロセス全体で1つを共有する
///
/// 変換エンジン内では、組成ごとの状態 (ラティス・確定済みデータ・Zenzaiキャッシュ・予測キャッシュ) のみを変換セッションIDで分離する
///
/// 各ソケット接続には、変換セッションと独自の組成テキスト・候補リストを持つHazkeyServerStateを割り当てる
///
/// - Note: Fcitx 5とIBusを同時に有効化した場合も、ユーザ辞書・学習メモリ・Zenzaiモデルはこのオブジェクトで共有される
class HazkeySharedResources {
    // MARK: 設定と変換エンジン

    /// 設定ファイル (config.json) の読み書きとZenzaiの初期化を担う設定管理
    let serverConfig: HazkeyServerConfig
    /// 全接続で共有するかな漢字変換エンジン
    let converter: KanaKanjiConverter
    /// 変換要求の基本オプション (設定の適用時に作り直す)
    var baseConvertRequestOptions: ConvertRequestOptions

    // MARK: 入力テーブル

    /// 文字キーの入力をローマ字かな変換の意図文字へ対応付けるキーマップ
    var keymap: Keymap
    /// 現在の入力テーブルの登録名 (設定の適用ごとに新しいUUIDで登録し直す)
    var currentTableName: String

    // MARK: 辞書と特殊候補

    /// ユーザ辞書 (user_dictionary.tsv)
    let userDictionary: UserDictionary = UserDictionary()
    /// ユーザ辞書を変換エンジンへ注入済みかどうか (falseにすると次の候補生成時に再注入する)
    var userDictInjected = false
    /// Emoji 17.0直接変換の候補プロバイダ (プロセスごとに1度だけ構築し、以後は更新しない)
    let emojiProvider: EmojiCandidateProvider?
    /// 住所辞書の補助辞書ソースID
    static let addressDictionarySourceID = "address"
    /// 工学辞書の補助辞書ソースID
    static let engineeringDictionarySourceID = "engineering"

    // MARK: 学習データ

    /// 永続化していない学習データがあるかどうか (全接続で共有するdirtyフラグ)
    var learningDataNeedsCommit = false
    /// allLearningMemoryEntries()が1回の走査で列挙する行数の上限
    ///
    /// - Important: HazkeyServerConfig.genBaseConvertRequestOptions()が指定するmaxMemoryCount (保存エントリ数の上限) と同じ値を維持すること
    static let learningEnumerationLimit = 65_536
    /// 削除可能の注釈と学習削除で使う、読みによるポイント照会の差し替え口 (テスト専用)
    ///
    /// nilの場合は、本番経路 (converter.persistedLearningMemoryKeys(exactReadings:)) を使用する
    ///
    /// テストでは失敗するクロージャに差し替え、実際のシャードを破損させずに照会失敗時の縮退動作を検証する
    var learningSurfaceKeyLookup: (([String]) throws -> [PersistedLearningMemoryKey])?

    // MARK: 接続セッション

    /// 接続中の全変換セッションID
    ///
    /// 学習削除時は要求元だけでなく全セッションの変換キャッシュを無効化して、削除済みエントリが他のクライアントの候補に再び現れないようにする
    private var liveConversionSessionIDs: Set<KanaKanjiConverter.ConversionSessionID> = []

    // MARK: ログの間引き

    /// 学習メモリ照会の失敗を最後にログへ出力した時刻
    ///
    /// 注釈の照会は打鍵ごとに実行されるため、回復不能な障害をそのまま記録するとキー入力ごとにログが出てしまう
    private var lastLearningLookupFailureLog: ContinuousClock.Instant?
    /// 学習メモリ照会の失敗ログを出力する最短間隔
    private static let learningLookupFailureLogInterval: Duration = .seconds(60)
    /// 学習データの保存失敗を最後にログへ出力した時刻
    private var lastLearningCommitFailureLog: ContinuousClock.Instant?
    /// 学習データの保存失敗ログを出力する最短間隔
    private static let learningCommitFailureLogInterval: Duration = .seconds(60)

    /// 変換エンジンに登録する補助辞書ソースの一覧を返す
    ///
    /// 宣言順は固定で、住所辞書 (address) が先、工学辞書 (engineering) が後になる
    ///
    /// - Parameter config: 各辞書のディレクトリパスを提供する設定
    /// - Returns: 変換エンジンの初期化に渡す補助辞書ソースの配列
    /// - Note: ディレクトリが存在しない辞書はdirectoryURLがnilになり、変換エンジン側でその辞書だけが無効になる
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

    /// 補助辞書付きの変換エンジンを生成する
    ///
    /// 補助辞書ソースの一覧が拒否されても変換を停止させず、システム辞書だけの変換エンジンへ縮退する
    ///
    /// - Parameters:
    ///   - dictionaryURL: システム辞書のディレクトリ
    ///   - supplementalDictionaries: 登録する補助辞書ソース (住所辞書・工学辞書)
    /// - Returns: 生成した変換エンジン
    /// - Note: 縮退した場合、住所辞書と工学辞書の切り替えは何も効果を持たない
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

    /// 本番用の絵文字辞書 (Emoji 17.0) で共有リソースを生成する
    convenience init() {
        self.init(emojiDictionaryURL: nil)
    }

    /// 共有リソースを生成して、変換エンジン・入力テーブル・学習メモリを初期化する
    ///
    /// 学習メモリのディレクトリが無い場合は作成して、v0.2.0の保存場所にデータがあれば移動する
    ///
    /// 最後にダミーの変換を1回実行して、変換エンジンに学習設定を読み込ませる
    ///
    /// - Parameter emojiDictionaryURL: テスト用に注入する絵文字辞書 (nilの場合は本番用のEmoji 17.0辞書を使用する)
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

    /// 接続の変換セッションを、学習削除時のキャッシュ無効化対象として登録する
    ///
    /// - Parameter id: 登録する変換セッションID
    func registerConversionSession(_ id: KanaKanjiConverter.ConversionSessionID) {
        liveConversionSessionIDs.insert(id)
    }

    /// 切断した接続の変換セッションを、キャッシュ無効化対象から外す
    ///
    /// - Parameter id: 登録を解除する変換セッションID
    func unregisterConversionSession(_ id: KanaKanjiConverter.ConversionSessionID) {
        liveConversionSessionIDs.remove(id)
    }

}

// MARK: - 共有設定と学習

/// 共有リソースの設定反映と学習データの管理をまとめた拡張
///
/// 設定の再読み込み・ニューラル変換モデルの再読み込みと、学習メモリの列挙・削除・永続化を提供する
extension HazkeySharedResources {
    /// 設定の変更を共有リソースへ反映する
    ///
    /// キーマップ・入力テーブル・基本オプション・学習メモリのディレクトリを読み込み直して、補助辞書の切り替えとユーザ辞書の再読み込みを行う
    ///
    /// 組成状態は接続ごとに保持されるため、ここでは変更しない
    ///
    /// - Note: 呼び出し後に組成をリセットするのは要求元の接続だけで、他の接続は入力途中の組成を維持する
    func reinitializeConfiguration() {
        // 呼び出し後に自身の組成をリセットするのは要求元接続だけで、他の接続中セッションは入力途中の組成を維持する
        //
        // InputStyleManager.registerInputStyle(table:for:) (KanaKanjiConverterModule) は、
        // 新しい".tableName(UUID)"をキーとするエントリを追加するだけで、以前の登録名を削除しないため安全である
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
        // ホットパス側のユーザ辞書の再読み込みはスロットルされるため、設定適用時はスロットルを迂回して強制再読み込みして、辞書編集を取りこぼさない
        // userDictInjectedを倒して次回の候補生成で (変更後の) エントリを再注入させる
        userDictionary.reloadIfNeeded(force: true)
        userDictInjected = false
    }

    /// [変換]タブの住所辞書・工学辞書の有効 / 無効を変換エンジンへ反映する
    ///
    /// 両辞書は変換エンジンの構築時に登録済みのため、フラグを切り替えるだけでよく、再構築や辞書の再読み込みは不要
    ///
    /// - Note: フラグが実際に変わった場合のみ、変換エンジンが全セッションの変換キャッシュとZenzaiのメモ化キャッシュを破棄する
    func syncConverterAddressDictionary() {
        let profile = serverConfig.currentProfile
        converter.setSupplementalDictionaryEnabled(
            profile.useAddressDictionaryEffective, for: Self.addressDictionarySourceID)
        converter.setSupplementalDictionaryEnabled(
            profile.useEngineeringDictionaryEffective, for: Self.engineeringDictionarySourceID)
    }

    /// 学習設定 (学習の種類・保存件数の上限・保存先ディレクトリ) を変換エンジンへ即時に反映する
    ///
    /// 変換エンジンは、学習メモリの保存先を変換要求 (requestCandidates(_:options:)) の中で遅延して適用する
    ///
    /// 設定ダイアログは変換を行わないため、ここで先に適用しないと、次の打鍵まで学習履歴の列挙・削除が前のプロファイルのディレクトリを読み続ける
    func syncConverterLearningConfig() {
        converter.updateLearningConfig(
            LearningConfig(
                learningType: baseConvertRequestOptions.learningType,
                maxMemoryCount: baseConvertRequestOptions.maxMemoryCount,
                memoryURL: baseConvertRequestOptions.memoryDirectoryURL))
    }

    /// 保留中の学習データを永続化する
    ///
    /// 永続化する学習データが無い場合は、何もせずに成功を返す
    ///
    /// - Returns: 成功時は.success、保存に失敗した場合は.failedとエラーメッセージを含むレスポンス
    /// - Important: 保存に失敗した場合は、learningDataNeedsCommitを維持して、次の契機 (save_learning_data RPC・切断・設定変更) で再試行する
    ///
    ///   ここでフラグを消すと、ディスクに書き込まれていない学習データを通知なく破棄してしまう
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

    /// Zenzaiモデルを読み込み直して、ウォームアップを行う
    ///
    /// 一時的な変換セッションで「あ」を1回変換し、モデルの読込とVulkanバックエンドの初期化を最初の打鍵より前に済ませる
    ///
    /// Zenzaiが無効、またはモデルが無い場合は、ウォームアップせずに成功を返す
    ///
    /// - Returns: 成功時は.success、モデルを読み込めなかった場合は.failedとエラーメッセージを含むレスポンス
    /// - Note: サーバの起動直後・設定の適用後・[ニューラル変換モデル管理]画面のreload_zenzai_model RPCから呼ばれる
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

    /// 現在のプロファイルの学習データを消去する
    ///
    /// 変換エンジンの学習メモリとdirtyフラグ、全接続の変換セッションのキャッシュをリセットして、[プロファイル非依存の入力履歴]が無効の場合は、プロファイル専用の学習ディレクトリも作り直す
    ///
    /// - Returns: 成功時は.success、ディレクトリの削除・作成に失敗した場合は、.failedを含むレスポンス
    func clearProfileLearningData() -> Hazkey_ResponseEnvelope {
        // ディレクトリだけを削除しても変換エンジンの未コミット一時メモリ、キャッシュ済みmemory LOUDS、dirtyフラグは残る
        // そのため次のコミットで保留エントリが、消去したばかりのディレクトリへ書き戻される
        // どちらの分岐でも変換エンジンの状態とフラグをリセットする
        converter.resetMemory()
        learningDataNeedsCommit = false
        // 学習メモリを消去しても、各セッションのラティス (およびZenzaiのdraft/メモ化制約) は消去前の学習エントリを含んだまま再利用される
        // 個別の削除 (forgetLearningEntries(_:)) と同じく、全接続中セッションの変換キャッシュを破棄する
        for id in liveConversionSessionIDs {
            do { try converter.withSession(id) { converter.stopComposition() } }
            catch { NSLog("[hazkey] Failed to reset conversion session \(id): \(error)") }
        }
        converter.purgeZenzaiMemoizationCache()
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

    /// 学習履歴を読みと表記の組ごとに1行へまとめて、ページ単位で返す
    ///
    /// 学習メモリは読み・表記・左右の品詞ID (CID) の組ごとに1行を保存するため、同じ表記でもCIDの異なる複数行になりうる
    /// (例: 1回の確定による文節のエントリと全文のエントリ)
    ///
    /// まとめた行は使用回数を合算し、最終使用日は最も新しい値を使う
    ///
    /// - Parameters:
    ///   - query: 検索文字列 (空の場合は全件)
    ///   - offset: ページの開始位置
    ///   - limit: 1ページの行数 (1〜200に丸める)
    /// - Returns: ページ内の行と、検索に一致した行の総数
    /// - Throws: offsetが列挙上限を超える場合は、LearningHistoryError.invalidOffset、学習メモリの読込に失敗した場合は変換エンジンのエラー
    /// - Note: 削除時は候補の学習削除ホットキーと同じく全てのCIDのエントリを削除するため、クライアントにはCIDを公開しない
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

    /// 指定した学習エントリを削除し、全接続の変換キャッシュを無効化する
    ///
    /// 削除前に全てのキーが学習メモリに存在することを確認し、一つでも無ければ何も削除しない
    ///
    /// - Parameter keys: 削除するエントリの読み・表記・左右の品詞ID (重複は1件にまとめる)
    /// - Returns: 削除したエントリ数
    /// - Throws: 存在しないキーが含まれる場合はLearningHistoryError.unknownEntry、
    ///   CIDがIntで表せない場合はLearningHistoryError.unsupportedCID、照会・削除に失敗した場合は変換エンジンのエラー
    /// - Note: 変換エンジンの削除は直ちにディスクへ反映され、各接続の組成テキストは変更しない
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

    /// 読みと表記が一致する学習エントリを、品詞ID (CID) にかかわらず全て削除する
    ///
    /// 候補の学習削除ホットキー (deleteCandidateLearningData) と同じ動作で、設定画面の学習履歴ダイアログから使用する
    ///
    /// 保存エントリが無い読みと表記は読み飛ばすため、処理中に削除済みの行があっても一括削除全体は失敗しない
    ///
    /// - Parameter surfaces: 削除する読みと表記の組
    /// - Returns: 実際に削除したエントリ数 (CID違いを個別に数える)
    /// - Throws: 学習メモリの照会・削除に失敗した場合はそのエラー
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

    /// 学習メモリに保存されたエントリを列挙する
    ///
    /// 変換エンジンの単一走査APIを1回だけ呼び、learningEnumerationLimit件までを返す
    ///
    /// - Returns: 学習メモリのエントリ (読み・表記・品詞ID・使用回数・最終使用日時)
    /// - Throws: 学習メモリの読込に失敗した場合は変換エンジンのエラー
    /// - Note: 接続ごとのHazkeyServerStateやテストからも使うため、privateにはしない
    func allLearningMemoryEntries() throws -> [LearningMemoryEntry] {
        try converter.allLearningMemoryEntries(limit: Self.learningEnumerationLimit).entries
    }

    /// 指定した読みに保存された学習エントリのキーを、読みのポイント照会で取得する
    ///
    /// テスト用の差し替え口 (learningSurfaceKeyLookup) が設定されていればそちらを使う
    ///
    /// - Parameter readings: 照会する読み (カタカナに正規化済みであること)
    /// - Returns: 一致したエントリの読み・表記・左右の品詞ID
    /// - Throws: 学習メモリのシャードが破損・欠落している場合や、学習が一時停止中の場合は変換エンジンのエラー
    private func persistedLearningMemoryKeys(
        exactReadings readings: [String]
    ) throws -> [PersistedLearningMemoryKey] {
        if let learningSurfaceKeyLookup {
            return try learningSurfaceKeyLookup(readings)
        }
        return try converter.persistedLearningMemoryKeys(exactReadings: readings)
    }

    /// 指定した読みに保存された学習エントリを、読みと表記の組のキーで返す
    ///
    /// 変換候補に削除可能の注釈 (has_learning_entry) を付けるために使う
    ///
    /// - Parameter readings: 照会する読み
    /// - Returns: 学習済みの読みと表記の組
    /// - Throws: 学習メモリの照会に失敗した場合は変換エンジンのエラー
    /// - Precondition: 読みはトライの完全一致で引くため、事前にカタカナに正規化しておくこと
    func learningSurfaceKeys(forReadings readings: [String]) throws -> Set<LearningSurfaceKey> {
        Set(
            try persistedLearningMemoryKeys(exactReadings: readings).map {
                LearningSurfaceKey(reading: $0.reading, word: $0.word)
            })
    }

    /// 読みと表記が一致する保存済みの学習エントリを、品詞ID (CID) にかかわらず全て返す
    ///
    /// 注釈と同じポイント照会から導くため、削除可能と表示された候補は必ず削除できる
    ///
    /// - Parameters:
    ///   - reading: 候補の読み
    ///   - word: 候補の表記
    /// - Returns: forgetLearningEntries(_:)に渡す削除対象のキー
    /// - Throws: 学習メモリの照会に失敗した場合は変換エンジンのエラー
    func matchingLearningEntryKeys(
        reading: String,
        word: String
    ) throws -> [(reading: String, word: String, lcid: UInt32, rcid: UInt32)] {
        try matchingLearningEntryKeys(readings: [reading], word: word)
    }

    /// 複数の読みのいずれかと表記が一致する保存済みの学習エントリを、品詞ID (CID) にかかわらず全て返す
    ///
    /// 通常変換の候補は切り詰めた入力読み、予測候補は候補全体の読みで保存されるため、両方の読みで照合する
    ///
    /// 同じエントリは1件にまとめる
    ///
    /// - Parameters:
    ///   - readings: 候補の読み (空文字列は無視する)
    ///   - word: 候補の表記
    /// - Returns: forgetLearningEntries(_:)に渡す削除対象のキー
    /// - Throws: 学習メモリの照会に失敗した場合は変換エンジンのエラー
    /// - Important: 全ての読みを1回の照会にまとめること (読みごとに照会してはならない)
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

    /// 学習メモリ照会の失敗をログへ出力する
    ///
    /// 注釈の照会は打鍵ごとに実行されるため、60秒に1回までに間引く
    ///
    /// - Parameter error: 照会で発生したエラー
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

    /// 学習データの保存失敗をログへ出力する
    ///
    /// dirtyフラグが立っている間は保存の契機ごとに再試行するため、ディスク障害が続いてもログが増え続けないよう、60秒に1回までに間引く
    ///
    /// - Parameter error: 保存で発生したエラー
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

/// 1つのソケット接続に結び付いた、入力中の組成セッション
///
/// HazkeyServerは、接続を受け入れるたびにこのオブジェクトを1つ生成して、切断時に破棄する
///
/// 重い変換エンジン・設定・ユーザ辞書・絵文字プロバイダは、サーバ全体の共有リソース (HazkeySharedResources) に置く
///
/// このオブジェクトが持つのは、組成ごとの状態 (組成テキスト・候補リスト・[Shift]キーと直接入力モードの状態・Zenzaiの左文脈) と、
/// 共有の変換エンジン内でこの接続の状態を選ぶ変換セッションIDだけである
///
/// 組成状態に触れる変換エンジンの呼び出しは全てwithConversionSession内で行い、同時に接続したクライアント同士が互いの未確定の入力を参照しないようにする
///
/// - Note: 学習メモリはサーバ全体で共有する
class HazkeyServerState {
    // MARK: 共有リソースと変換セッション

    /// 全接続で共有するサーバ全体のリソース
    let shared: HazkeySharedResources
    /// 共有の変換エンジン内で、この接続の組成状態を選ぶ変換セッションID
    let conversionSessionID: KanaKanjiConverter.ConversionSessionID
    /// 変換セッションを解放済みかどうか (close()を冪等にするために使う)
    private var isClosed = false
    /// 誤字の訂正案を1件ずつ独立に評価するための変換セッションID
    ///
    /// 訂正案は元の入力と読みが異なるため、主変換のセッション状態 (ラティスやニューラル変換キャッシュ) を汚さないよう別セッションで評価する
    ///
    /// 訂正案の数だけ遅延して確保し、この接続の切断時にまとめて解放する
    private var typoCorrectionSessionIDs: [KanaKanjiConverter.ConversionSessionID] = []
    /// 訂正を適用しない元の読みを一度だけ評価するための変換セッションID
    ///
    /// 訂正案は常にニューラル変換なしで評価するため、ニューラル変換が有効なときは同じ条件で測った基準値が必要になる
    ///
    /// 基準値は接続ごとに一度求めればよいため、必要になった時点で1つだけ確保する
    private var typoBaselineSessionID: KanaKanjiConverter.ConversionSessionID?
    /// 区切り全文要求で読みを超えたために除外した候補の累計件数 (テストから観測する)
    var droppedAlignmentCandidateCount = 0
    /// 読み超過候補の除外をログへ出力済みかどうか (1接続につき1回だけ出す)
    private var hasReportedOversizedAlignmentCandidates = false

    /// テスト用: この接続が生成した訂正候補用セッションの数
    ///
    /// 設定OFF・トリガー無しの入力でセッションが生成されないことを検証する
    var typoCorrectionSessionCount: Int {
        typoCorrectionSessionIDs.count + (typoBaselineSessionID == nil ? 0 : 1)
    }

    /// 主変換がこの時間を超えた打鍵では誤字の訂正を省略する (テストでは短くして予算超過を再現する)
    var typoTimeBudget: Duration = .milliseconds(TypoCorrector.typoTimeBudget)
    /// 打鍵時に訂正案の評価へ使える時間で、超えたら残りの訂正案を評価しない (テストでは短くして評価の打ち切りを再現する)
    var typoEvaluationBudget: Duration = .milliseconds(TypoCorrector.typoTimeBudget)
    /// 訂正案の評価の打ち切りに使う現在時刻 (テストでは差し替えて、評価の途中で予算を超える時刻列を再現する)
    var typoClock: () -> ContinuousClock.Instant = { ContinuousClock.now }

    // MARK: 組成テキストと候補リスト

    /// 入力中の組成テキスト
    var composingText: ComposingTextBox = ComposingTextBox()
    /// 最後にクライアントへ返した候補リスト (確定・予測受入・学習削除で候補の位置から引く)
    var currentCandidateList: [DisplayedCandidate]?
    /// currentCandidateListがサジェストと変換のどちらで作られたか
    ///
    /// 候補の学習削除後は同じモードで候補リストを作り直す (サジェストの候補リストを変換の候補リストとして作り直すと、ライブ変換の状態が壊れる)
    ///
    /// makeCandidatesResultを呼ぶたびに記録して、currentCandidateListと常に一致させる
    var currentCandidateListIsSuggest = false
    /// Zenzaiの左文脈 (カーソルより前にある周辺テキスト)
    var zenzaiLeftContext = ""
    /// Zenzaiの右文脈 (カーソルより後にある周辺テキスト。先頭rightContextMaxCharacters文字まで)
    var zenzaiRightContext = ""
    /// 右文脈として保持する最大文字数 (キャラクター単位)
    static let rightContextMaxCharacters = 40
    /// 計測用: 変換要求の結果を左右する入力 (学習データと辞書の状態は含まない)
    private struct CandidateRequestSignature: Equatable {
        let composingText: ComposingText
        let isSuggest: Bool
        let leftContext: String
        let rightContext: String
        let configRevision: UInt64
    }
    /// 計測用: 前回の変換要求の内容 (HAZKEY_PERF_EVIDENCE 設定時のみ記録し、同じ内容の要求を数える)
    private var previousCandidateRequest: CandidateRequestSignature?
    /// 計測用: 最後に受け取った周辺テキスト (HAZKEY_PERF_EVIDENCE 設定時のみ記録し、重複したsetContextを数える。文脈を消すときに破棄する)
    private var lastSurroundingContext: (text: String, anchorIndex: Int)?

    // MARK: [Shift]キーと直接入力モード

    /// [Shift]キーが単独で押されているかどうか (他のキーが入力されるとfalseになる)
    var isShiftPressedAlone = false
    /// [Shift]キーを押した時刻 (長押しの判定に使う)
    var shiftPressedAt: ContinuousClock.Instant?
    /// 直接入力 (サブ入力) モードかどうか (trueの場合はローマ字かな変換せずに文字をそのまま挿入する)
    var isSubInputMode = false
    /// [Shift]キーの押下から解放までをタップとみなす最長時間
    ///
    /// これより長い押下は長押しとして扱い、直接入力モードを切り替えない
    private static let shiftTapMaxDuration: Duration = .milliseconds(500)

    // MARK: - 共有リソースへの転送アクセサ

    // 保存先をsharedに移した後も、既存のstate.xxx呼び出し箇所 (ProtocolHandler、テスト) を変更せずにコンパイルできるようにする

    /// 共有の設定管理 (shared.serverConfigへの転送)
    var serverConfig: HazkeyServerConfig { shared.serverConfig }
    /// 共有の変換エンジン (shared.converterへの転送)
    var converter: KanaKanjiConverter { shared.converter }
    /// 変換要求の基本オプション (shared.baseConvertRequestOptionsへの転送)
    var baseConvertRequestOptions: ConvertRequestOptions {
        get { shared.baseConvertRequestOptions }
        set { shared.baseConvertRequestOptions = newValue }
    }
    /// キーマップ (shared.keymapへの転送)
    var keymap: Keymap {
        get { shared.keymap }
        set { shared.keymap = newValue }
    }
    /// 現在の入力テーブルの登録名 (shared.currentTableNameへの転送)
    var currentTableName: String {
        get { shared.currentTableName }
        set { shared.currentTableName = newValue }
    }
    /// ユーザ辞書 (shared.userDictionaryへの転送)
    var userDictionary: UserDictionary { shared.userDictionary }
    /// Emoji 17.0直接変換の候補プロバイダ (shared.emojiProviderへの転送)
    var emojiProvider: EmojiCandidateProvider? { shared.emojiProvider }
    /// 永続化していない学習データがあるかどうか (shared.learningDataNeedsCommitへの転送)
    var learningDataNeedsCommit: Bool {
        get { shared.learningDataNeedsCommit }
        set { shared.learningDataNeedsCommit = newValue }
    }

    /// 共有リソースを新しく生成して、接続セッションを生成する (主にテスト用)
    convenience init() {
        self.init(emojiDictionaryURL: nil)
    }

    /// 指定した絵文字辞書で共有リソースを新しく生成して、接続セッションを生成する (主にテスト用)
    ///
    /// - Parameter emojiDictionaryURL: テスト用に注入する絵文字辞書 (nilの場合は本番用のEmoji 17.0辞書を使う)
    convenience init(emojiDictionaryURL: URL?) {
        self.init(shared: HazkeySharedResources(emojiDictionaryURL: emojiDictionaryURL))
    }

    /// 共有リソース上に接続セッションを生成して、変換セッションを登録する
    ///
    /// - Parameter shared: 全接続で共有するサーバ全体のリソース
    init(shared: HazkeySharedResources) {
        self.shared = shared
        self.conversionSessionID = shared.converter.createSession()
        shared.registerConversionSession(conversionSessionID)
    }

    /// この接続の変換セッションを解放する
    ///
    /// - Note: 冪等であり、切断処理とファイル記述子の再利用時の解放が重なって2回呼ばれても安全
    func close() {
        guard !isClosed else { return }
        isClosed = true
        shared.unregisterConversionSession(conversionSessionID)
        converter.removeSession(conversionSessionID)
        // 訂正用の補助セッションも主セッションと同様に解放する
        // 解放漏れがあると変換エンジン内部にセッション状態が残り続ける
        for id in typoCorrectionSessionIDs {
            shared.unregisterConversionSession(id)
            converter.removeSession(id)
        }
        typoCorrectionSessionIDs.removeAll()
        if let id = typoBaselineSessionID {
            shared.unregisterConversionSession(id)
            converter.removeSession(id)
            typoBaselineSessionID = nil
        }
    }

    /// この接続の変換セッションを選んで処理を実行する
    ///
    /// 変換エンジンはサーバ全体で共有され、組成ごとの状態 (ラティス・確定済みデータ・Zenzaiキャッシュ・前回の入力) は、変換セッションごとに管理される
    ///
    /// そのため、組成を扱う呼び出しは必ずこのメソッドを経由する
    ///
    /// - Parameter body: 変換セッションを選んだ状態で実行する処理
    /// - Returns: 処理の戻り値 (変換セッションが使えない場合はnil)
    private func withConversionSession<T>(_ body: () throws -> T) -> T? {
        do { return try converter.withSession(conversionSessionID, operation: body) }
        catch { NSLog("[hazkey] Conversion session unavailable: \(error)"); return nil }
    }

    /// 設定の変更を共有リソースへ反映した後、この接続の組成状態をリセットする
    ///
    /// - Note: 他の接続の組成状態はリセットしない
    func reinitializeConfiguration() {
        NSLog("Reinitializing state configuration...")
        shared.reinitializeConfiguration()

        self.composingText = ComposingTextBox()
        self.currentCandidateList = nil
        self.isSubInputMode = false
        self.isShiftPressedAlone = false
        self.shiftPressedAt = nil
        self.zenzaiLeftContext = ""
        self.zenzaiRightContext = ""
        self.lastSurroundingContext = nil

        NSLog("State configuration reinitialized successfully")
    }

    // MARK: - 共有学習処理への転送

    // ProtocolHandlerとテストが引き続きstate.*を呼べるようにする薄い転送メソッド

    /// 現在のプロファイルの学習データを消去する
    ///
    /// - Returns: 成功時は.success、失敗時は.failedを含むレスポンス
    /// - Note: HazkeySharedResources.clearProfileLearningData()へ転送する
    func clearProfileLearningData() -> Hazkey_ResponseEnvelope {
        shared.clearProfileLearningData()
    }

    /// 学習履歴を読みと表記の組ごとに1行へまとめて、ページ単位で返す
    ///
    /// - Parameters:
    ///   - query: 検索文字列 (空の場合は全件)
    ///   - offset: ページの開始位置
    ///   - limit: 1ページの行数
    /// - Returns: ページ内の行と、検索に一致した行の総数
    /// - Throws: HazkeySharedResources.listLearningEntries(query:offset:limit:) が投げるエラー
    /// - Note: HazkeySharedResources.listLearningEntries(query:offset:limit:) へ転送する
    func listLearningEntries(
        query: String,
        offset: UInt32,
        limit: UInt32
    ) throws -> (entries: [Hazkey_Config_LearningHistoryEntry], totalCount: Int) {
        try shared.listLearningEntries(query: query, offset: offset, limit: limit)
    }

    /// 読みと表記が一致する学習エントリを、品詞ID (CID) にかかわらず全て削除する
    ///
    /// - Parameter surfaces: 削除する読みと表記の組
    /// - Returns: 実際に削除したエントリ数
    /// - Throws: HazkeySharedResources.forgetLearningSurfaces(_:) が投げるエラー
    /// - Note: HazkeySharedResources.forgetLearningSurfaces(_:) へ転送する
    func forgetLearningSurfaces(_ surfaces: [(reading: String, word: String)]) throws -> UInt32 {
        try shared.forgetLearningSurfaces(surfaces)
    }

    /// 指定した学習エントリを削除し、全接続の変換キャッシュを無効化する
    ///
    /// - Parameter keys: 削除するエントリの読み・表記・左右の品詞ID
    /// - Returns: 削除したエントリ数
    /// - Throws: HazkeySharedResources.forgetLearningEntries(_:) が投げるエラー
    /// - Note: HazkeySharedResources.forgetLearningEntries(_:) へ転送する
    func forgetLearningEntries(
        _ keys: [(reading: String, word: String, lcid: UInt32, rcid: UInt32)]
    ) throws -> UInt32 {
        try shared.forgetLearningEntries(keys)
    }

    /// アプリケーションの周辺テキストから、Zenzaiの左右の文脈を設定する
    ///
    /// カーソル位置は周辺テキストの符号点数に対する範囲へ丸める
    ///
    /// - Parameters:
    ///   - surroundingText: 周辺テキスト
    ///   - anchorIndex: 周辺テキスト内のカーソル位置 (符号点数)
    /// - Returns: 常に.successを含むレスポンス
    func setContext(surroundingText: String, anchorIndex: Int) -> Hazkey_ResponseEnvelope {
        let scalars = surroundingText.unicodeScalars
        let clamped = max(0, min(anchorIndex, scalars.count))
        if clamped != anchorIndex { NSLog("[hazkey] setContext: anchor clamped \(anchorIndex)->\(clamped) for length \(scalars.count)") }
        zenzaiLeftContext = String(String.UnicodeScalarView(scalars.prefix(clamped)))
        zenzaiRightContext = String(String(String.UnicodeScalarView(scalars.dropFirst(clamped))).prefix(Self.rightContextMaxCharacters))
        if let perfProbe = PerfProbe.shared {
            let isDuplicate = lastSurroundingContext.map {
                $0.text == surroundingText && $0.anchorIndex == anchorIndex
            } ?? false
            perfProbe.recordCount("set_context_duplicate", isDuplicate ? 1 : 0)
            lastSurroundingContext = (surroundingText, anchorIndex)
        }
        // Zenzaiモードは"makeCandidatesResult"で、この接続の"zenzaiLeftContext"からリクエストごとに計算する
        // その間に、"baseConvertRequestOptions.zenzaiMode"を読む箇所はないため、ここに保存しても使用されない
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    // MARK: - 組成テキスト

    /// 新しい組成を開始する
    ///
    /// 組成テキスト・候補リスト・Zenzaiの左文脈・直接入力モードを初期化して、この接続の変換セッション (誤字の訂正用の補助セッションを含む) のキャッシュを破棄する
    ///
    /// - Returns: 常に.successを含むレスポンス
    func createComposingTextInstanse() -> Hazkey_ResponseEnvelope {
        composingText = ComposingTextBox()
        currentCandidateList = nil
        zenzaiLeftContext = ""
        zenzaiRightContext = ""
        lastSurroundingContext = nil
        isSubInputMode = false
        isShiftPressedAlone = false
        shiftPressedAt = nil
        // 新しい組成の開始時にこの接続の変換セッションを破棄して、同じ入力でも前の組成のラティスを再利用して新たに学習した候補が隠れないようにする
        // 1つの組成内での逐次変換ではセッションを引き続き再利用する
        _ = withConversionSession { converter.stopComposition() }
        // 誤字の訂正案を評価する補助セッションも、同じ理由で破棄する
        for id in typoCorrectionSessionIDs + [typoBaselineSessionID].compactMap({ $0 }) {
            do { try converter.withSession(id) { converter.stopComposition() } }
            catch { NSLog("[hazkey] Failed to reset typo correction session \(id): \(error)") }
        }
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    /// 1文字を組成テキストのカーソル位置へ挿入する
    ///
    /// 直接入力モードでは文字をそのまま挿入して、通常モードではキーマップと入力テーブルでローマ字かな変換する
    ///
    /// [Shift]キーを単独で押下した状態で直接入力の開始文字 (設定の大文字等) を入力すると、直接入力モードに入る
    ///
    /// - Parameter inputString: 入力された文字 (先頭の1文字だけを使用する)
    /// - Returns: 成功時は.success、文字列が空の場合は.failedを含むレスポンス
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

    /// 修飾キーのイベントを処理して、[Shift]キーの単独タップで直接入力モードを切り替える
    ///
    /// [Shift]キーを押して500[ms]未満で離した場合だけ切り替え、長押しや他のキーとの同時押下 (CANCEL) では切り替えない
    ///
    /// - Parameters:
    ///   - modifier: 修飾キーの種類 (現在は[Shift]キーのみ)
    ///   - event: 押下・解放・取消のいずれか
    /// - Returns: 成功時は.success、未知の修飾キーやイベントの場合は.failedを含むレスポンス
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
                // [Shift]が別のキー (修飾キーまたは文字キー) と組み合わされた状態で離された場合
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

    /// 現在の入力モードを返す
    ///
    /// - Returns: 直接入力モードの場合は.direct、それ以外は.normalを含むレスポンス
    func getCurrentInputMode() -> Hazkey_ResponseEnvelope {
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
            $0.currentInputModeInfo = Hazkey_Commands_CurrentInputModeInfo.with {
                $0.inputMode = isSubInputMode ? .direct : .normal
            }
        }
    }

    /// 保留中の学習データを永続化する
    ///
    /// - Returns: 成功時は.success、保存に失敗した場合は.failedを含むレスポンス
    /// - Note: HazkeySharedResources.saveLearningData()へ転送する
    func saveLearningData() -> Hazkey_ResponseEnvelope {
        shared.saveLearningData()
    }

    /// Zenzaiモデルを読み込み直して、ウォームアップを行う
    ///
    /// - Returns: 成功時は.success、モデルを読み込めなかった場合は.failedを含むレスポンス
    /// - Note: HazkeySharedResources.reloadZenzaiModel()へ転送する
    func reloadZenzaiModel() -> Hazkey_ResponseEnvelope {
        shared.reloadZenzaiModel()
    }

    /// カーソルの左の1文字を削除する ([BackSpace]キー)
    ///
    /// - Returns: 常に.successを含むレスポンス
    func deleteLeft() -> Hazkey_ResponseEnvelope {
        composingText.value.deleteBackwardFromCursorPosition(count: 1)
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    /// カーソルの右の1文字を削除する ([Delete]キー)
    ///
    /// - Returns: 常に.successを含むレスポンス
    func deleteRight() -> Hazkey_ResponseEnvelope {
        composingText.value.deleteForwardFromCursorPosition(count: 1)
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    /// 候補を確定して、候補が対応する読みを組成テキストから取り除く
    ///
    /// 変換エンジンの候補は学習データを更新する (ユーザ辞書由来の候補を除く)
    ///
    /// 相対日付・かな数字・絵文字等の注入候補は学習しない
    ///
    /// - Parameter candidateIndex: 候補リスト内の確定する候補の位置
    /// - Returns: 成功時は.success、候補が見つからない場合は.failedを含むレスポンス
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
        case .fromTypoCorrection(let correctedCandidate, _, let originalPrefixCount):
            // 元の入力の先頭だけを消費し、訂正対象でない接尾辞は組成に残して変換可能なまま保つ
            if originalPrefixCount < composingText.value.convertTarget.count {
                composingText.value.prefixComplete(composingCount: .surfaceCount(originalPrefixCount))
            } else {
                composingText = ComposingTextBox()
            }
            let learnsFromCandidate = !correctedCandidate.data.contains {
                $0.metadata.contains(.isFromUserDictionary)
            }
            // 訂正候補は主変換の組成と対応しないため、setCompletedDataは呼ばず学習だけを更新する
            // 主変換の未確定のラティスは使わないため、組成を停止して次回の再変換に備える
            _ = withConversionSession {
                if learnsFromCandidate { converter.updateLearningData(correctedCandidate) }
                converter.stopComposition()
            }
            if learnsFromCandidate { learningDataNeedsCommit = true }
        case .fromUserDict:
            // ユーザ辞書エントリは常に読み全体に一致するため、組成テキストを消去するだけでよい
            // 変換エンジンの学習ストアには追加しない
            composingText = ComposingTextBox()
        case .fromDateProvider(_, let composingCount):
            // 日付候補はカーソルまでの相対日付トリガーの読みだけを消費し、右側の読みを保持する
            // 変換エンジンの確定 / 学習APIには触れず、共有dirtyフラグも変更しない
            composingText.value.prefixComplete(composingCount: composingCount)
        case .fromKanaNumberProvider(_, let composingCount):
            // かな数字候補はカーソルまでの数詞の読みだけを消費し、右側の読みを保持する
            // 変換エンジンの確定 / 学習APIには触れず、共有dirtyフラグも変更しない
            composingText.value.prefixComplete(composingCount: composingCount)
        case .fromEmoji(_, let composingCount):
            // 絵文字直接変換候補は一致した正規化クエリのprefixだけを消費し、後続suffixは保持する
            // 変換エンジンの確定 / 学習APIには触れないため、共有dirtyフラグは変更しない (他の接続に永続化待ちの学習がある可能性がある)
            composingText.value.prefixComplete(composingCount: composingCount)
        }
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    /// 予測候補を先頭の固定表記として受け入れる (上流ad714fe / #357)
    ///
    /// completePrefixと異なり確定はせず、候補の残りの読みを組成テキストに追加し、受け入れた表記を以降のZenzai変換の先頭の制約とする
    ///
    /// まだ確定していないため、学習データは更新しない
    ///
    /// - Parameter candidateIndex: 候補リスト内の受け入れる候補の位置
    /// - Returns: 成功時は.success、候補が見つからない場合や受け入れられない候補の場合は.failedを含むレスポンス
    /// - Note: 受入のホットキーは設定で変更できる (既定は[F5]キー)
    func acceptPrediction(candidateIndex: Int) -> Hazkey_ResponseEnvelope {
        // 範囲を先に確認する
        // Swiftの配列添字 (およびそのoptional chaining) は範囲外でnilを返さずトラップするため、不正なクライアント添字でサーバをクラッシュさせない
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

    /// 組成テキスト内のカーソルを移動する
    ///
    /// - Parameter offset: 移動する文字数 (負の値は左、正の値は右)
    /// - Returns: 常に.successを含むレスポンス
    func moveCursor(offset: Int) -> Hazkey_ResponseEnvelope {
        _ = composingText.value.moveCursorFromCursorPosition(count: offset)
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    /// 文節の境界を移動し、変換候補を作り直す ([Shift]+[Left] / [Shift]+[Right])
    ///
    /// カーソル位置を文節の境界として扱い、先頭の1文字から末尾までの範囲に丸めて移動する
    ///
    /// - Parameter offset: 境界を移動する文字数 (負の値は左、正の値は右)
    /// - Returns: 作り直した候補リストとひらがなの読みを含むレスポンス (組成テキストが空の場合は空の結果)
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

        // 文節境界の移動は打鍵ごとの処理ではなく、新しい読みでニューラル変換が走り時間予算を超えやすいため、時間予算を適用しない
        let (candidatesResult, serverCandidates) = makeCandidatesResult(
            is_suggest: false, appliesTypoTimeBudget: false)
        currentCandidateList = serverCandidates

        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
            $0.clauseBoundaryResult = Hazkey_Commands_ClauseBoundaryResult.with {
                $0.candidates = candidatesResult
                $0.hiragana = composingText.value.toHiragana()
            }
        }
    }

    // MARK: - 組成テキストの文字列化

    /// 組成テキストのひらがなを、カーソルの前・カーソル位置の1文字・カーソルの後の3つに分けて返す
    ///
    /// 表示設定を適用しない構造APIで、補助テキストの表示・非表示 (auxTextMode) はフロントエンド側 (hazkey::frontend::shouldShowAuxText) が判断する
    ///
    /// - Returns: 3分割したひらがなを含むレスポンス
    /// - Important: 設定によって空文字列を返すとpreeditのキャレット位置まで設定に従属してしまうため、常に実際の3分割を返すこと
    func getHiraganaWithCursor() -> Hazkey_ResponseEnvelope {
        // 範囲外の指定ではトラップせずに空文字列を返す部分文字列の取得
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

    /// 組成テキストを指定した文字種に変換して返す ([F6]〜[F10]キー等の直接変換)
    ///
    /// 英字への変換では、同じキーを押すたびに小文字・大文字・先頭のみ大文字を巡回する
    ///
    /// - Parameters:
    ///   - charType: 変換先の文字種 (ひらがな・全角カタカナ・半角カタカナ・全角英字・半角英字)
    ///   - currentPreedit: 現在のpreedit (英字の大文字・小文字の巡回に使用する)
    /// - Returns: 成功時は変換した文字列を含む.success、未知の文字種の場合は.failedを含むレスポンス
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

    // MARK: - 候補

    /// 変換の前に、組成テキストの末尾へ組成の区切りを挿入する
    ///
    /// 区切りを挿入すると、末尾の未確定のローマ字 (例: n) がかなへ確定される
    ///
    /// - Note: カーソルが末尾に無い場合や、既に区切りがある場合は何もしない
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

    /// 変換エンジンへ渡す組成テキストを返す
    ///
    /// 変換でカーソルが末尾に無い場合は、カーソルまでの読み (文節の境界まで) を変換する
    ///
    /// - Parameter is_suggest: サジェストの場合はtrue、変換の場合はfalse
    /// - Returns: HazkeyServerState.candidateRequestText(for:isSuggest:)の結果
    func candidateRequestText(is_suggest: Bool) -> ComposingText {
        Self.candidateRequestText(for: composingText.value, isSuggest: is_suggest)
    }

    /// 組成テキストから、変換エンジンへ渡す組成テキストを作る
    ///
    /// サジェスト (ライブ変換) は読み全体を変換するため、カーソルが途中にあっても末尾へ移した写しを返す
    /// カーソルが途中のまま渡すと、Zenzai は全文を区切りなしで評価する一方、ラティスはカーソルまでになり、プロンプトと候補が対応しない
    ///
    /// - Parameters:
    ///   - text: 現在の組成テキスト
    ///   - isSuggest: サジェストの場合はtrue、変換の場合はfalse
    /// - Returns: サジェストの場合はカーソルを末尾に置いた組成テキスト全体、変換でカーソルが途中の場合はカーソルまでの組成テキスト、それ以外は組成テキスト全体
    static func candidateRequestText(for text: ComposingText, isSuggest: Bool) -> ComposingText {
        if text.isAtEndIndex {
            return text
        }
        if !isSuggest {
            return text.prefixToCursorPosition()
        }
        var whole = text
        _ = whole.moveCursorFromCursorPosition(
            count: whole.convertTarget.count - whole.convertTargetCursorPosition)
        return whole
    }

    /// アラインメント区切りのために、変換エンジンへ全文の組成テキストを渡すかどうかを判定する
    ///
    /// 全文を渡すのは、非サジェスト・Zenzai 有効・設定が適用可能・カーソルが読みの途中・組成の入力の末尾が文節区切り (右側に未確定のローマ字が無い) の時のみ
    /// それ以外はカーソルまでの読みを渡す
    ///
    /// - Note: 設定の適用可否は、HazkeyServerConfig.alignmentSeparatorAppliesが1箇所で判定する
    static func shouldSendFullReadingForAlignment(
        fullText: ComposingText, isSuggest: Bool, zenzaiOn: Bool, alignmentApplies: Bool
    ) -> Bool {
        !isSuggest && zenzaiOn && alignmentApplies && !fullText.isAtEndIndex
            && fullText.convertTargetCursorPosition > 0
            && (fullText.input.last?.piece == .compositionSeparator)
    }

    /// 候補の読みが指定した長さを超えるものを除外する
    ///
    /// 全文の読みを変換エンジンへ渡した場合、全文に対応するかな候補が混入するため、
    /// カーソルまでの読みに収まる候補だけを残す (再要求はしない)
    ///
    /// - Parameters:
    ///   - candidates: 変換エンジンが返した候補
    ///   - readingLength: カーソルまでの読みの文字数
    /// - Returns: 範囲内の候補と、除外した件数を返す
    static func candidatesWithinReading(
        _ candidates: [Candidate], readingLength: Int
    ) -> (kept: [Candidate], droppedCount: Int) {
        var kept: [Candidate] = []
        var droppedCount = 0
        for candidate in candidates {
            if candidate.rubyCount <= readingLength {
                kept.append(candidate)
            } else {
                droppedCount += 1
            }
        }
        return (kept, droppedCount)
    }

    /// 学習メモリへの一括ポイント照会で、変換候補に削除可能の注釈 (has_learning_entry) を付ける
    ///
    /// 各候補の2種類の読みをまとめて照会して、いずれかが表記と一致すれば注釈を付ける
    ///
    /// 候補数にかかわらず、照会は1回の要求につき1回だけ行う
    ///
    /// - Parameters:
    ///   - readings: clientCandidatesと同じ位置に並んだ各候補の読み
    ///   - clientCandidates: 注釈を付けるクライアント向けの候補
    /// - Important: converter.requestCandidates(...) の後にのみ呼び出すこと
    ///
    ///   変換エンジンはその呼び出しの中で学習メモリの保存先を遅延して適用するため、
    ///   先に照会するとプロファイルの切り替え直後に前のプロファイルのディレクトリを読んでしまう
    ///
    /// - Note: 照会に失敗した場合は、全ての候補を注釈無しのままにする (保守的な縮退動作)
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

    /// 変換エンジンで候補を生成し、クライアント向けの候補リストとサーバ側の候補リストを作る
    ///
    /// 処理の流れは次の通り
    ///
    /// 1. 必要ならユーザ辞書を変換エンジンへ注入する
    /// 2. この接続の変換セッションで変換し、予測候補と変換候補を重複なく並べ、ライブ変換の表記を決める
    /// 3. 誤字の訂正候補のうち、基準を上回るものを先頭候補の直後へ挿入する
    /// 4. 削除可能の注釈を付ける
    /// 5. 絵文字・相対日付・かな数字の候補を注入する
    /// 6. 自動変換の設定に従ってライブ変換の表記を消して、ページの候補数を設定する
    ///
    /// - Parameters:
    ///   - is_suggest: サジェスト (入力中の候補) の場合はtrue、変換 ([Space]キー等) の場合はfalse
    ///   - appliesTypoTimeBudget: 主変換が時間予算 (TypoCorrector.typoTimeBudget) を超えた場合に誤字の訂正を省略し、訂正案の評価も時間予算で打ち切るか
    /// - Returns: クライアントへ返す候補結果と、同じ位置に並んだサーバ側の候補リスト
    /// - Note: 絵文字とかな数字の候補は変換の場合だけ注入して、サジェストやライブ変換には混ぜない
    private func makeCandidatesResult(
        is_suggest: Bool,
        appliesTypoTimeBudget: Bool = true
    ) -> (Hazkey_Commands_CandidatesResult, [DisplayedCandidate]) {
        self.currentCandidateListIsSuggest = is_suggest
        let perfProbe = PerfProbe.shared
        let candidateStartedAt = perfProbe?.now()
        var userDictionaryStartedAt = candidateStartedAt
        var userDictionaryFinishedAt = candidateStartedAt
        var zenzaiInferenceNanoseconds: UInt64?
        var zenzaiCounters: ZenzInferencePerfCounters?
        // 既にレスポンスへ出力した表記
        // 変換エンジンは、predictionResultsとmainResultsの各配列内では個別に重複排除するが、両配列間では同じ表記が重なることがある
        // (ユーザ辞書の単語が自身の最良ノードの予測としても現れる等)
        // そのため連結後のリストでは後続の重複を除外する
        var appendedTexts: Set<String> = []

        // 以下で出力する全変換候補のカタカナ正規化済み読み
        // clientCandidatesと位置を対応させる
        // 削除可能の注釈は、変換エンジンの応答後にこれらを使用した1回の一括ポイント照会で決める (annotateLearningEntriesを参照)
        var annotationReadings: [CandidateLearningReadings] = []

        // 候補を追加できるかどうか (サジェストでは上限まで、変換では常に追加できる)
        func canAppend(
            isSuggest: Bool,
            currentCount: Int,
            limit: Int
        ) -> Bool {
            return !isSuggest || currentCount < limit
        }

        // 変換エンジンの候補を、クライアント向け・サーバ側・注釈用の読みの3つのリストへ同じ位置で追加する
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
        // モデルのリンク解決とデバイス列挙は、この要求の中で1回だけ行う
        let zenzaiSnapshot = serverConfig.makeZenzaiRequestSnapshot()
        let zenzai: String
        let alignmentApplies: Bool
        switch zenzaiSnapshot {
        case .off:
            zenzai = "off"
            alignmentApplies = false
        case .on(let resolvedModelURL, _):
            zenzai = "on"
            alignmentApplies = HazkeyServerConfig.alignmentSeparatorApplies(
                profile: serverConfig.currentProfile, modelURL: resolvedModelURL)
        }
        let sendFullReading = Self.shouldSendFullReadingForAlignment(
            fullText: composingText.value,
            isSuggest: is_suggest,
            zenzaiOn: zenzai == "on",
            alignmentApplies: alignmentApplies)
        options.zenzaiMode = serverConfig.genZenzaiMode(
            snapshot: zenzaiSnapshot,
            leftContext: zenzaiLeftContext,
            rightContext: zenzaiRightContext,
            requestRichCandidates: HazkeyServerConfig.requestRichCandidates(
                for: serverConfig.currentProfile, isSuggestion: is_suggest),
            sendsFullReadingForAlignment: sendFullReading)
        userDictionaryStartedAt = perfProbe?.now()
        defer {
            if let candidateStartedAt, let userDictionaryStartedAt, let userDictionaryFinishedAt {
                perfProbe?.recordCandidateStages(
                    userDictionaryStartedAt: userDictionaryStartedAt,
                    userDictionaryFinishedAt: userDictionaryFinishedAt,
                    candidateStartedAt: candidateStartedAt,
                    zenzai: zenzai,
                    zenzaiInferenceNanoseconds: zenzaiInferenceNanoseconds,
                    zenzaiCounters: zenzaiCounters)
            }
        }

        let copiedComposingText = candidateRequestText(is_suggest: is_suggest)
        if let perfProbe {
            let request = CandidateRequestSignature(
                composingText: composingText.value,
                isSuggest: is_suggest,
                leftContext: zenzaiLeftContext,
                rightContext: zenzaiRightContext,
                configRevision: serverConfig.configRevision)
            perfProbe.recordCount("identical_request", request == previousCandidateRequest ? 1 : 0)
            previousCandidateRequest = request
        }

        // ユーザ辞書を変換エンジンに注入して、各エントリが指定品詞 (CID) の接続コスト順位付けに参加するようにする
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
        let mainRequestStartedAt = ContinuousClock.now
        if zenzai == "on" {
            _ = ZenzInferencePerf.shared.consumeElapsedNanoseconds()
            _ = ZenzInferencePerf.shared.consumeCounters()
        }
        guard
            var converted = withConversionSession({
                converter.requestCandidates(
                    sendFullReading ? composingText.value : copiedComposingText, options: options)
            })
        else {
            // セッションは接続終了時にのみ削除され、単一スレッドのサーバループが終了済みセッションで変換することもないが、
            // 念のためトラップせず空リストを返す
            var emptyResult = Hazkey_Commands_CandidatesResult()
            emptyResult.liveTextIndex = -1
            return (emptyResult, [])
        }
        let mainRequestDurationMs = ContinuousClock.now - mainRequestStartedAt
        if zenzai == "on" {
            zenzaiInferenceNanoseconds = ZenzInferencePerf.shared.consumeElapsedNanoseconds()
            zenzaiCounters = ZenzInferencePerf.shared.consumeCounters()
        }
        let fullHiraganaPreedit = composingText.value.toHiragana()
        let hiraganaPreedit = copiedComposingText.toHiragana()
        let hiraganaPreeditLen = hiraganaPreedit.count
        if sendFullReading {
            let main = Self.candidatesWithinReading(
                converted.mainResults, readingLength: hiraganaPreeditLen)
            let predictions = Self.candidatesWithinReading(
                converted.predictionResults, readingLength: hiraganaPreeditLen)
            converted.mainResults = main.kept
            converted.predictionResults = predictions.kept
            let droppedCount = main.droppedCount + predictions.droppedCount
            droppedAlignmentCandidateCount += droppedCount
            if droppedCount > 0 && !hasReportedOversizedAlignmentCandidates {
                hasReportedOversizedAlignmentCandidates = true
                NSLog(
                    "[hazkey] dropped \(droppedCount) alignment candidates exceeding the cursor reading")
            }
        }
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

        let profile = serverConfig.currentProfile
        let inputReading = copiedComposingText.toHiragana()
        let typoEligible = profile.useTypoCorrectionEffective
            && !(is_suggest && profile.suggestionListMode == .suggestionListDisabled)
            && inputReading.count <= TypoCorrector.maxReadingLength
            && !copiedComposingText.input.contains(where: { $0.inputStyle == .direct })
            && (!appliesTypoTimeBudget || mainRequestDurationMs <= typoTimeBudget)
        if typoEligible {
            let triggers = TypoCorrector.triggers(in: inputReading)
            let variants = TypoCorrector.variants(of: copiedComposingText, triggers: triggers)
            if !variants.isEmpty {
                var correctionOptions = TypoCorrector.correctionOptions(from: options)
                correctionOptions.N_best = 1
                var evaluated: [(candidate: Candidate, reading: String, editCount: Int, adjustedValue: Double)] = []
                let evaluationStartedAt = typoClock()
                // 訂正案ごとに専用セッションを遅延確保する
                // 同じ接続での再変換では確保済みのセッションを再利用し、主変換とは別のラティスを保つ
                for (index, variant) in variants.enumerated() {
                    // 訂正案の数は入力の長さとトリガーの数に応じて増えるため、打鍵時は評価に使う時間も予算で打ち切る
                    if appliesTypoTimeBudget && typoClock() - evaluationStartedAt >= typoEvaluationBudget {
                        break
                    }
                    while typoCorrectionSessionIDs.count <= index {
                        let id = converter.createSession()
                        typoCorrectionSessionIDs.append(id)
                        shared.registerConversionSession(id)
                    }
                    let result = try? converter.withSession(typoCorrectionSessionIDs[index]) {
                        converter.requestCandidates(variant.composingText, options: correctionOptions)
                    }
                    if let candidate = result.flatMap({ TypoCorrector.bestExactMatch(in: $0.mainResults, readingLength: variant.reading.count) }) {
                        evaluated.append((
                            candidate, variant.reading, variant.editCount,
                            Double(candidate.value) - TypoCorrector.penalty(editCount: variant.editCount)))
                    }
                }
                // 訂正案は常にニューラル変換なしで評価するため、基準値も同じ条件で測る必要がある
                // ニューラル変換が無効な主変換の結果はそのまま使えるが、有効な場合は専用セッションで元の読みを評価する
                let baselineValue: Double?
                if evaluated.isEmpty {
                    baselineValue = nil
                } else if case .off = options.zenzaiMode {
                    baselineValue = TypoCorrector.bestExactMatch(
                        in: converted.mainResults, readingLength: hiraganaPreeditLen
                    ).map { Double($0.value) }
                } else {
                    if typoBaselineSessionID == nil {
                        let id = converter.createSession()
                        typoBaselineSessionID = id
                        shared.registerConversionSession(id)
                    }
                    baselineValue = typoBaselineSessionID.flatMap { id in
                        (try? converter.withSession(id) {
                            converter.requestCandidates(copiedComposingText, options: correctionOptions)
                        }).flatMap { TypoCorrector.bestExactMatch(in: $0.mainResults, readingLength: hiraganaPreeditLen) }
                            .map { Double($0.value) }
                    }
                }
                // 基準を上回る訂正案を、スコアの高い順に最大 maxVariants 件まで先頭候補の直後へ並べる
                // (mちがえる の「間違える」と「見違える」のように、読みの異なる訂正案はどれも利用者の意図になり得るため)
                // 母音補完は1箇所で5通りを評価するため、表示件数は評価数ではなくここで制限する
                let offered = baselineValue.map { baselineValue in
                    evaluated
                        .filter {
                            TypoCorrector.shouldOffer(
                                variantValue: Double($0.candidate.value), baselineValue: baselineValue,
                                editCount: $0.editCount)
                        }
                        .sorted { $0.adjustedValue > $1.adjustedValue }
                        .prefix(TypoCorrector.maxVariants)
                } ?? []
                // 完全な訂正 (読みにトリガーが残らないもの) が1つでも提示されるなら、まだトリガーが残る部分的な訂正は落とす
                // 例: ちゃゃゃっっっと では ちゃっと が完全な訂正であり、ゃゃ が残る部分的な縮約は劣る
                let preferred = TypoCorrector.competitive(
                    TypoCorrector.preferringComplete(Array(offered), reading: { $0.reading }),
                    adjustedValue: { $0.adjustedValue })
                var insertionIndex = min(1, clientCandidates.count)
                for correction in preferred where !appendedTexts.contains(correction.candidate.text) {
                    let needsPushout = is_suggest && clientCandidates.count >= N_best
                    let hasPushable = !needsPushout
                        || clientCandidates.indices.contains {
                            Int32($0) != candidatesResult.liveTextIndex && !clientCandidates[$0].isTypoCorrection
                        }
                    guard hasPushable else { break }
                    appendedTexts.insert(correction.candidate.text)
                    var client = Hazkey_Commands_CandidatesResult.Candidate()
                    client.text = correction.candidate.text
                    client.subHiragana = String(fullHiraganaPreedit.dropFirst(hiraganaPreeditLen))
                    client.isTypoCorrection = true
                    clientCandidates.insert(client, at: insertionIndex)
                    serverCandidates.insert(.fromTypoCorrection(
                        candidate: correction.candidate, correctedReading: katakanaNormalized(correction.reading),
                        originalPrefixCount: copiedComposingText.convertTarget.count), at: insertionIndex)
                    annotationReadings.insert(CandidateLearningReadings(prefixReading: katakanaNormalized(correction.reading), fullRuby: katakanaNormalized(correction.reading)), at: insertionIndex)
                    if Int32(insertionIndex) <= candidatesResult.liveTextIndex { candidatesResult.liveTextIndex += 1 }
                    insertionIndex += 1
                    // サジェストは候補数に上限があるため、挿入で押し出された末尾の非訂正・非ライブ候補を除去して上限を保つ
                    if needsPushout,
                        let removalIndex = clientCandidates.indices.reversed().first(where: {
                            !clientCandidates[$0].isTypoCorrection && Int32($0) != candidatesResult.liveTextIndex
                        })
                    {
                        clientCandidates.remove(at: removalIndex)
                        serverCandidates.remove(at: removalIndex)
                        annotationReadings.remove(at: removalIndex)
                        if Int32(removalIndex) < candidatesResult.liveTextIndex { candidatesResult.liveTextIndex -= 1 }
                        if removalIndex < insertionIndex { insertionIndex -= 1 }
                    }
                }
            }
        }

        // ここで削除可能の注釈を付ける
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
                    // 長さはかなの文字数のため、キー入力の要素数 (ローマ字入力では一致しない) ではなく表層の文字数で確定する
                    let matchedCount = item.query.count
                    let remaining = String(
                        fullHiraganaPreedit.dropFirst(min(matchedCount, fullHiraganaPreedit.count)))
                    var clientCandidate = Hazkey_Commands_CandidatesResult.Candidate()
                    clientCandidate.text = item.text
                    clientCandidate.subHiragana = remaining
                    serverCandidates.append(
                        .fromEmoji(
                            word: item.text, composingCount: .surfaceCount(matchedCount)))
                    clientCandidates.append(clientCandidate)
                }
            }
        }

        // === 相対日付候補の注入 (後処理) ===
        // 組成中のひらがなが相対日付トリガーワード (きょう、きのう等) に完全一致し、かつ変換エンジンが漢字表現 (今日、昨日等) を返した場合、
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
                // 漢字形が存在する場合のみ注入して、「漢字表現が有る時だけ挿入」というユーザ設定に従う
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
                        // 日付候補はカーソルまでの読みだけを消費するため、subHiraganaは右側の残りpreeditとする
                        clientCandidate.subHiragana = String(
                            fullHiraganaPreedit.dropFirst(hiraganaPreeditLen))

                        let insertAt = kanjiIndex + 1 + insertedCount
                        serverCandidates.insert(
                            .fromDateProvider(
                                word: dateStr, composingCount: .surfaceCount(hiraganaPreeditLen)),
                            at: insertAt)
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
                        // 合成漢字アンカー (確定時は、fromDateProviderとして扱う)
                        var anchorClientCandidate = Hazkey_Commands_CandidatesResult.Candidate()
                        anchorClientCandidate.text = trigger.kanji
                        anchorClientCandidate.subHiragana = String(
                            fullHiraganaPreedit.dropFirst(hiraganaPreeditLen))
                        serverCandidates.append(
                            .fromDateProvider(
                                word: trigger.kanji, composingCount: .surfaceCount(hiraganaPreeditLen)))
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
                            serverCandidates.append(
                                .fromDateProvider(
                                    word: dateStr, composingCount: .surfaceCount(hiraganaPreeditLen)))
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
                            .fromKanaNumberProvider(
                                word: text, composingCount: .surfaceCount(hiraganaPreeditLen)),
                            at: insertAt + offset)
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

    /// 候補リストを生成して返して、確定等のためにサーバ側の候補リストを記録する
    ///
    /// 変換の場合は、先に組成テキストの末尾へ組成の区切りを挿入する
    ///
    /// - Parameter is_suggest: サジェストの場合はtrue、変換の場合はfalse
    /// - Returns: 候補結果を含むレスポンス
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

    /// 候補について、学習データを削除し、候補リストを作り直す
    ///
    /// 読みと表記が同じであれば、品詞ID (CID) だけが異なる学習エントリも全て削除する
    ///
    /// 削除可能の注釈と同じ規則で照合するため、削除可能と表示された候補は必ず削除できる
    ///
    /// 誤字の訂正候補も変換エンジン候補と同じく学習データを持てるため、訂正後の読みで照合して削除する
    ///
    /// 候補リストは削除前と同じモード (サジェストまたは変換) で作り直す
    ///
    /// - Parameter candidateIndex: 候補リスト内の対象候補の位置
    /// - Returns: 削除件数と作り直した候補リストを含むレスポンス
    /// - Note: 絵文字等の注入候補や未学習の候補は学習データを持たないため、削除件数は0になる (候補リストは作り直さない)
    /// - Important: 変換エンジンの学習削除は直ちにディスクへ反映され、作り直した候補リストにも削除が反映される
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
        let candidate: Candidate
        let candidateReadings: CandidateLearningReadings
        switch list[candidateIndex] {
        case .fromConverter(let value):
            candidate = value
            let fullHiraganaPreedit = composingText.value.toHiragana()
            let requestHiraganaPreeditLen = candidateRequestText(is_suggest: currentCandidateListIsSuggest).toHiragana().count
            candidateReadings = candidate.learningReadings(
                truncatedTo: String(fullHiraganaPreedit.prefix(min(candidate.rubyCount, requestHiraganaPreeditLen))))
        case .fromTypoCorrection(let value, let reading, _):
            candidate = value
            candidateReadings = CandidateLearningReadings(prefixReading: reading, fullRuby: reading)
        default:
            return Hazkey_ResponseEnvelope.with {
                $0.status = .success
                $0.deleteCandidateLearningDataResult = Hazkey_Commands_DeleteCandidateLearningDataResult.with {
                    $0.deletedCount = 0
                }
            }
        }

        // appendCandidateと同じ式で候補の読みを算出する
        let readings = candidateReadings

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

/// 変換候補から学習メモリの照会に使う読みを導く拡張
extension Candidate {
    /// 候補が学習メモリに保存されうる2種類の読みを返す
    ///
    /// 注釈と学習削除でこのメソッドだけを使うため、削除可能と表示された候補は必ず削除できる
    ///
    /// - Parameter typedPrefix: 候補の位置まで切り詰めた入力のひらがな読み
    /// - Returns: カタカナに正規化した切り詰めた読みと候補全体の読み
    func learningReadings(truncatedTo typedPrefix: String) -> CandidateLearningReadings {
        CandidateLearningReadings(
            prefixReading: katakanaNormalized(typedPrefix),
            fullRuby: katakanaNormalized(data.map(\.ruby).joined()))
    }
}

/// 未設定の項目を既定値で補ったプロファイル設定の有効値
extension Hazkey_Config_Profile {
    /// [ユーザ辞書を使用]の有効値
    ///
    /// 既存の動作を維持するため、古い設定ファイルや未設定の場合はtrueになる
    var useUserDictionaryEffective: Bool {
        hasUseUserDictionary ? useUserDictionary : true
    }

    /// [相対日付]候補の有効値
    ///
    /// 既存の動作を維持するため、古い設定ファイルや未設定の場合はtrueになる
    var useRelativeDateEffective: Bool {
        let mode = specialConversionMode
        return mode.hasRelativeDate ? mode.relativeDate : true
    }
}
