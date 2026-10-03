import Foundation
import KanaKanjiConverterModule
import SwiftProtobuf

/// ユーザ定義キーマップTSVのサイズ上限である
///
/// - Note: 上限は1[MB]であり、上限を超えたファイルは無視される
let KEYMAP_FILE_SIZE_LIMIT = 1024 * 1024
/// ユーザ定義入力テーブルTSVのサイズ上限である
///
/// - Note: 上限は1[MB]であり、上限を超えたファイルは無視される
let TABLE_FILE_SIZE_LIMIT = 1024 * 1024

/// 設定の検証と書き込みに関するエラーを表す
///
/// LocalizedErrorに準拠し、errorDescriptionで利用者向けメッセージを返す
enum ConfigError: LocalizedError {
    /// 設定JSONの最上位が配列でない場合を示す
    case invalidJSONTopLevel
    /// 設定JSONの配列要素がオブジェクトでない場合を示す
    ///
    /// - Parameter index: オブジェクトでなかった要素の位置
    case invalidJSONProfile(index: Int)
    /// プロファイルが空の場合を示す
    case emptyProfiles
    /// 未知のenum値が含まれる場合を示す
    ///
    /// - Parameters:
    ///   - field: 検証対象のフィールド名
    ///   - rawValue: 認識できなかった整数値
    case unrecognizedEnum(field: String, rawValue: Int)
    /// 数値が許容範囲外の場合を示す
    ///
    /// - Parameters:
    ///   - field: 検証対象のフィールド名
    ///   - value: 検出した値
    ///   - range: 許容範囲
    case valueOutOfRange(field: String, value: Int32, range: ClosedRange<Int32>)
    /// 保留中の学習データの保存に失敗した場合を示す
    ///
    /// 設定は変更されず、何も書き込まない
    case learningCommitFailed(String)

    /// 利用者向けのエラーメッセージを返す
    ///
    /// - Returns: 原因を説明するメッセージ
    var errorDescription: String? {
        switch self {
        case .invalidJSONTopLevel:
            return "Config JSON must be an array of profiles."
        case .invalidJSONProfile(let index):
            return "Config JSON profile at index \(index) must be an object."
        case .emptyProfiles:
            return "At least one configuration profile is required."
        case .unrecognizedEnum(let field, let rawValue):
            return "Invalid \(field) enum value: \(rawValue)."
        case .valueOutOfRange(let field, let value, let range):
            return "Invalid \(field) value \(value); expected \(range.lowerBound)...\(range.upperBound)."
        case .learningCommitFailed(let message):
            return
                "Failed to persist the pending learning data of the active profile; "
                + "the configuration was not changed. \(message)"
        }
    }
}

/// 組み込みキーマップの一覧である
///
/// isBuiltIn付きの名前列であり、利用可能なキーマップの基礎になる
let builtInKeymaps = [
    "JIS Kana",
    "Japanese Symbol",
    "Fullwidth Period",
    "Fullwidth Comma",
    "Fullwidth Symbol",
    "Fullwidth Number",
    "Fullwidth Space",
].map { name in
    Hazkey_Config_Keymap.with {
        $0.name = name
        $0.isBuiltIn = true
        $0.filename = name
    }
}

/// 組み込み入力テーブルの一覧である
///
/// isBuiltIn付きの名前列であり、利用可能な入力テーブルの基礎になる
let builtInInputTables = [
    "Romaji",
    "Kana",
].map { name in
    Hazkey_Config_InputTable.with {
        $0.name = name
        $0.isBuiltIn = true
        $0.filename = name
    }
}

/// サーバ設定を保持して、読み込みと保存と派生値を担う
///
/// 保存済みプロファイルと現在のプロファイル、辞書パス、ニューラル変換の状態を持つ
class HazkeyServerConfig {
    /// 保存済みプロファイルの一覧である
    ///
    /// [0]が現在のプロファイルを指す
    var profiles: [Hazkey_Config_Profile]
    /// 現在のプロファイルである
    ///
    /// profilesの先頭と同期し、変換要求の生成に直接使われる
    var currentProfile: Hazkey_Config_Profile
    /// 設定のリビジョン番号である
    ///
    /// [set_config]が成功するたびに1を加算して、全てのレスポンスの[config_revision]に載せる
    ///
    /// フロントエンドはこの値の変化を検知して、キャッシュしているプロファイルを再読み込みする
    private(set) var configRevision: UInt64 = 0
    /// システム辞書のディレクトリである
    let dictionaryPath: URL
    /// 住所辞書 (補助LOUDS辞書) のディレクトリである
    ///
    /// 未配備の場合はnilになる
    let addressDictionaryPath: URL?
    /// 工学辞書 (補助LOUDS辞書) のディレクトリである
    ///
    /// 未配備の場合はnilになる
    let engineeringDictionaryPath: URL?
    /// ニューラル変換が利用可能かどうかを示す
    ///
    /// バックエンドデバイスとモデルパスの両方が揃った場合に真になる
    var zenzaiAvailable: Bool
    /// 有効なニューラル変換モデルのパスである
    ///
    /// モデルが見つからない場合はnilになる
    var zenzaiModelPath: URL?
    /// 利用可能なGGMLバックエンドデバイスの一覧である
    var ggmlBackendDevices: [GGMLBackendDevice]
    /// GPU安全確認プローブの結果である
    let backendProbeOutcome: BackendProbeOutcome?

    /// サーバ設定を初期化する
    ///
    /// 保存済み設定の読み込みと辞書パスの決定とニューラル変換状態の解決を行う
    ///
    /// - Note: 設定の読み込みに失敗した場合は既定プロファイルへ縮退する
    init() {
        do {
            profiles = try Self.loadConfig()
        } catch {
            NSLog("Failed to load config: \(error)")
            NSLog("Loading default config...")
            profiles = [HazkeyServerConfig.genDefaultConfig()]
        }

        currentProfile = profiles.first ?? Self.genDefaultConfig()

        let fileManager = FileManager()

        // 辞書ディレクトリのパスを決める
        // 環境変数HAZKEY_DICTIONARYが実在するパスを指す場合はそれを使用して、無ければシステム配備のDictionaryを使用する
        dictionaryPath = {
            if let envPath = ProcessInfo.processInfo.environment["HAZKEY_DICTIONARY"],
                fileManager.fileExists(atPath: envPath)
            {
                return URL(filePath: envPath)
            } else {
                return URL(fileURLWithPath: systemResourcePath).appendingPathComponent(
                    "Dictionary", isDirectory: true)
            }
        }()

        // 住所辞書の配備は任意
        // 存在しなければnilを渡して、住所辞書なしの通常変換のみで動作する
        // 環境変数HAZKEY_ADDRESS_DICTIONARYが設定されていればその値だけを使用して、
        // そのパスが実在しなくてもシステム配備 (/usr/share/hazkey-community/AddressDictionary) へはフォールバックしない
        addressDictionaryPath = {
            let candidate: URL =
                if let envPath = ProcessInfo.processInfo.environment["HAZKEY_ADDRESS_DICTIONARY"] {
                    URL(filePath: envPath)
                } else {
                    URL(fileURLWithPath: systemResourcePath).appendingPathComponent(
                        "AddressDictionary", isDirectory: true)
                }
            return Self.existingDirectoryURL(candidate, fileManager: fileManager)
        }()

        // 工学辞書も住所辞書と同じ規則で決める
        // (環境変数はHAZKEY_ENGINEERING_DICTIONARY、システム配備は"/usr/share/hazkey-community/EngineeringDictionary")
        engineeringDictionaryPath = {
            let candidate: URL =
                if let envPath = ProcessInfo.processInfo.environment["HAZKEY_ENGINEERING_DICTIONARY"] {
                    URL(filePath: envPath)
                } else {
                    URL(fileURLWithPath: systemResourcePath).appendingPathComponent(
                        "EngineeringDictionary", isDirectory: true)
                }
            return Self.existingDirectoryURL(candidate, fileManager: fileManager)
        }()

        self.zenzaiModelPath = nil
        self.zenzaiAvailable = false
        let backendLoad = loadZenzaiDevicesSafely()
        self.ggmlBackendDevices = backendLoad.devices
        self.backendProbeOutcome = backendLoad.probeOutcome
        zenzaiModelPath = resolveActiveZenzaiModelPath()
        self.zenzaiAvailable = (ggmlBackendDevices.count > 0) && (zenzaiModelPath != nil)
    }

    /// 現在の設定を返す
    ///
    /// 保存済みプロファイルと利用可能なキーマップと入力テーブルとバックエンド情報を束ねる
    ///
    /// - Returns: CurrentConfigを含むレスポンスを返す
    /// - Note: 読み込みに失敗した場合は失敗応答を返す
    func getCurrentConfig() -> Hazkey_ResponseEnvelope {
        let profiles: [Hazkey_Config_Profile]
        do {
            profiles = try Self.loadConfig()
        } catch {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "\(error)"
            }
        }

        let userKeymapDir = Self.getConfigDirectory().appendingPathComponent(
            "keymap", isDirectory: true
        )
        var keymaps = builtInKeymaps
        do {
            try FileManager.default.createDirectory(
                at: userKeymapDir, withIntermediateDirectories: true)
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: userKeymapDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            let keymapFiles = try fileURLs.filter { url in
                guard url.pathExtension.lowercased() == "tsv" else { return false }
                let attrs = try url.resourceValues(forKeys: [.fileSizeKey])
                if let size = attrs.fileSize {
                    return size < KEYMAP_FILE_SIZE_LIMIT
                }
                return false
            }

            for file in keymapFiles {
                keymaps.append(
                    Hazkey_Config_Keymap.with {
                        $0.name = file.deletingPathExtension().lastPathComponent
                        $0.isBuiltIn = false
                        $0.filename = file.lastPathComponent
                    })
            }
        } catch {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Failed to get user keymap files: \(error)"
            }
        }

        let userInputTableDir = Self.getConfigDirectory().appendingPathComponent(
            "table", isDirectory: true
        )
        var inputTables = builtInInputTables
        do {
            try FileManager.default.createDirectory(
                at: userInputTableDir, withIntermediateDirectories: true)
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: userInputTableDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            let inputTableFiles = try fileURLs.filter { url in
                guard url.pathExtension.lowercased() == "tsv" else { return false }
                let attrs = try url.resourceValues(forKeys: [.fileSizeKey])
                if let size = attrs.fileSize {
                    return size < TABLE_FILE_SIZE_LIMIT
                }
                return false
            }

            for file in inputTableFiles {
                inputTables.append(
                    Hazkey_Config_InputTable.with {
                        $0.name = file.deletingPathExtension().lastPathComponent
                        $0.isBuiltIn = false
                        $0.filename = file.lastPathComponent
                    })
            }
        } catch {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Failed to get user input table files: \(error)"
            }
        }

        var zenzaiDevices: [Hazkey_Config_BackendDevice] = []
        for devices in ggmlBackendDevices {
            zenzaiDevices.append(
                Hazkey_Config_BackendDevice.with {
                    $0.name = devices.name
                    $0.desc = devices.description
                }
            )
        }

        let currentConfig = Hazkey_Config_CurrentConfig.with {
            $0.fileHashes = []
            $0.zenzaiModelAvailable = zenzaiModelPath != nil
            $0.zenzaiModelPath = zenzaiModelPath?.path ?? ""
            $0.xdgConfigHomePath = Self.getConfigDirectory().path
            $0.availableKeymaps = keymaps
            $0.availableTables = inputTables
            $0.availableZenzaiBackendDevices = zenzaiDevices
            $0.zenzaiGpuProbeFallback = zenzaiGPUFallbackActive(backendProbeOutcome)
            $0.profiles = profiles
        }
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
            $0.currentConfig = currentConfig
        }
    }

    /// 新しい設定を検証して適用する
    ///
    /// 受信したプロファイルを正規化して検証して、保留中の学習を旧プロファイルへ確定してから書き込む
    ///
    /// 書き込み後に現設定を切り替えてリビジョンを加算して、モデルを再ウォームアップする
    ///
    /// - Parameters:
    ///   - hashes: ファイル検証用ハッシュ列
    ///   - profiles: 保存するプロファイル列
    ///   - state: 学習確定と再初期化に使う接続 (省略時は保存のみ行う)
    /// - Returns: 成功または失敗を示すレスポンスを返す
    /// - Note: ウォームアップの失敗は保存成功に影響せず、ログのみ残す
    func setCurrentConfig(
        _ hashes: [Hazkey_Config_FileHash],
        _ profiles: [Hazkey_Config_Profile],
        state: HazkeyServerState? = nil
    ) -> Hazkey_ResponseEnvelope {
        do {
            try saveConfig(profiles, state: state)
        } catch {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "\(error)"
            }
        }

        // 設定の適用後に、ニューラル変換モデルを再ウォームアップする
        // デバイスやモデルを切り替えた場合でも、モデルのロード時間を次の打鍵に持ち越さないため
        //
        // 設定の保存自体は成功しているため、ウォームアップに失敗しても応答はfailedにせず、ログ出力のみとする
        // (失敗をUIへ伝える経路は、モデル管理ダイアログから呼ぶreload_zenzai_model RPCが別に持っている)
        if let state {
            let warmup = state.reloadZenzaiModel()
            if warmup.status == .failed {
                NSLog("[hazkey] Post-config neural model warmup failed: \(warmup.errorMessage)")
            }
        }

        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    /// ニューラル変換の有効無効を切り替える
    ///
    /// 現在のプロファイルの[zenzai_enable]を反転して保存する
    ///
    /// - Returns: 切替後の状態を含むレスポンスを返す
    func toggleZenzai() -> Hazkey_ResponseEnvelope {
        var updatedProfiles = profiles
        guard !updatedProfiles.isEmpty else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "No active profile"
            }
        }
        updatedProfiles[0].zenzaiEnable.toggle()

        do {
            try saveConfig(updatedProfiles)
        } catch {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "\(error)"
            }
        }

        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
            $0.toggleZenzaiResult.enabled = currentProfile.zenzaiEnable
        }
    }

    /// パスが実在するディレクトリの場合にのみURLを返す
    ///
    /// 存在しない場合や通常ファイルの場合はnilを返す
    ///
    /// 辞書パスの環境変数規則の判定に使う
    ///
    /// - Parameters:
    ///   - url: 判定対象の候補パス
    ///   - fileManager: 存在確認に使う管理機構
    /// - Returns: ディレクトリの場合のみ候補を返し、それ以外はnilを返す
    static func existingDirectoryURL(_ url: URL, fileManager: FileManager) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }
        return url
    }

    /// 既定のプロファイルを生成する
    ///
    /// 名称はDefaultであり、複数文字の自動変換と最小2文字と予測表示と提案3件と1頁9件と入力履歴を含む
    ///
    /// ホットキー・カーソル非末尾時の補助表示・特殊変換・内蔵キーマップ・ローマ字表・推論上限10の文脈付きCPUニューラル変換を持つ
    ///
    /// 住所辞書と工学辞書は既定で無効である
    ///
    /// - Returns: 既定値で埋めたプロファイルを返す
    static func genDefaultConfig() -> Hazkey_Config_Profile {
        var newConf = Hazkey_Config_Profile.init()
        newConf.profileName = "Default"
        newConf.autoConvertMode =
            Hazkey_Config_Profile.AutoConvertMode.autoConvertForMultipleChars
        newConf.autoConvertMinChars = 2
        newConf.autoConvertHotkey = "Control+Shift+L"
        newConf.acceptPredictionHotkey = "F5"
        newConf.zenzaiToggleHotkey = "Control+Alt+Z"
        newConf.auxTextMode = Hazkey_Config_Profile.AuxTextMode.auxTextShowWhenCursorNotAtEnd
        newConf.suggestionListMode =
            Hazkey_Config_Profile.SuggestionListMode.suggestionListShowPredictiveResults
        newConf.numSuggestions = 3
        newConf.useRichSuggestion = false
        newConf.numCandidatesPerPage = 9
        newConf.useRichCandidates = false
        newConf.useInputHistory = true
        newConf.useAddressDictionary = false
        newConf.useEngineeringDictionary = false
        newConf.useTypoCorrection = false
        newConf.zenzaiRightContext = false
        newConf.zenzaiAlignmentSeparator = false
        newConf.specialConversionMode = Hazkey_Config_Profile.SpecialConversionMode.with {
            $0.commaSeparatedNumber = true
            $0.mailDomain = true
            $0.calendar = true
            $0.time = true
            $0.romanTypography = true
            $0.unicodeCodepoint = true
            $0.hazkeyVersion = true
            $0.relativeDate = true
            $0.halfwidthKatakana = true
            $0.extendedEmoji = true
        }
        newConf.stopStoreNewHistory = false
        newConf.enabledKeymaps = [
            Hazkey_Config_Profile.EnabledKeymap.with {
                $0.name = "Fullwidth Number"
                $0.isBuiltIn = true
                $0.filename = "Fullwidth Number"
            },
            Hazkey_Config_Profile.EnabledKeymap.with {
                $0.name = "Fullwidth Symbol"
                $0.isBuiltIn = true
                $0.filename = "Fullwidth Symbol"
            },
            Hazkey_Config_Profile.EnabledKeymap.with {
                $0.name = "Japanese Symbol"
                $0.isBuiltIn = true
                $0.filename = "Japanese Symbol"
            },
            Hazkey_Config_Profile.EnabledKeymap.with {
                $0.name = "Fullwidth Space"
                $0.isBuiltIn = true
                $0.filename = "Fullwidth Space"
            },
        ]
        newConf.enabledTables = [
            Hazkey_Config_Profile.EnabledInputTable.with {
                $0.name = "Romaji"
                $0.isBuiltIn = true
                $0.filename = "Romaji"
            }
        ]
        newConf.submodeEntryPointChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        newConf.zenzaiBackendDeviceName = "CPU"
        newConf.zenzaiEnable = true
        newConf.zenzaiInferLimit = 10
        newConf.zenzaiContextualMode = true
        newConf.zenzaiProfile = ""
        return newConf
    }

    /// 既定のプロファイルを応答形式で返す
    ///
    /// genDefaultConfigをCurrentConfigに包み、設定画面の[リセット]処理に使う
    ///
    /// - Returns: 既定プロファイルを含む成功応答を返す
    static func getDefaultProfile() -> Hazkey_ResponseEnvelope {
        let currentConfig = Hazkey_Config_CurrentConfig.with {
            $0.profiles = [Self.genDefaultConfig()]
        }
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
            $0.currentConfig = currentConfig
        }
    }

    /// 設定を検証して保存する
    ///
    /// 受信したプロファイルを正規化し、config.jsonの書き込み前に旧プロファイルへ保留中の学習を確定する
    ///
    /// 書き込み後に現設定とモデル状態を更新して、要求元接続の構成を作り直してリビジョンを加算する
    ///
    /// - Parameters:
    ///   - newProfiles: 保存するプロファイル列
    ///   - state: 未保存の学習データを保存する接続 (nilの場合は保存しない)
    /// - Throws: 学習データの保存に失敗した場合は、ConfigError.learningCommitFailedを投げる
    /// - Important: config.jsonより先に学習データを保存して、失敗した場合は何も書き込まずに中止する
    func saveConfig(
        _ newProfiles: [Hazkey_Config_Profile],
        state: HazkeyServerState? = nil
    ) throws {
        let normalizedProfiles = try Self.normalizeProfiles(newProfiles)
        let configDir = Self.getConfigDirectory()
        let configPath = configDir.appendingPathComponent("config.json")

        // 未保存の学習データは、入力した時点で有効だったプロファイルに属する
        // そのため、currentProfile (つまりmemoryDirectory()) が旧プロファイルのディレクトリを指している間に保存する
        // 先にプロファイルを切り替えると、次回の保存時に新しいプロファイルの履歴へ混ざってしまう
        //
        // この保存は、config.jsonを書き込む前に行う
        // 保存に失敗した場合は、config.jsonを書き込まずにプロファイルの切替を中止して、
        // 未保存の学習データは旧プロファイルに属したまま残す (ディスクとメモリの状態が食い違わない)
        // 再度設定を適用すると、保存が再試行される
        if let state {
            let commitResult = state.saveLearningData()
            guard commitResult.status == .success else {
                throw ConfigError.learningCommitFailed(commitResult.errorMessage)
            }
        }

        try FileManager.default.createDirectory(
            at: configDir, withIntermediateDirectories: true, attributes: nil)

        var jsonObjects: [Any] = []
        var encodeOptions = JSONEncodingOptions()
        encodeOptions.alwaysPrintEnumsAsInts = true
        encodeOptions.useDeterministicOrdering = true
        for profile in normalizedProfiles {
            let jsonData = try profile.jsonUTF8Data(options: encodeOptions)
            let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: [])
            jsonObjects.append(jsonObject)
        }

        let jsonData = try JSONSerialization.data(
            withJSONObject: jsonObjects, options: [.prettyPrinted, .sortedKeys])

        try jsonData.write(to: configPath)

        NSLog("Config saved to: \(configPath.path)")

        profiles = normalizedProfiles
        guard let firstProfile = normalizedProfiles.first else {
            throw ConfigError.emptyProfiles
        }
        currentProfile = firstProfile
        zenzaiModelPath = resolveActiveZenzaiModelPath()
        zenzaiAvailable = !ggmlBackendDevices.isEmpty && zenzaiModelPath != nil

        if let state = state {
            state.reinitializeConfiguration()
        }

        configRevision &+= 1
    }

    /// 保存済み設定を読み込む
    ///
    /// config.jsonが無い場合は、既定プロファイルを正規化して返す
    ///
    /// - Returns: 検証済みプロファイル列を返す
    /// - Throws: 読み込みや復号や検証に失敗した場合に投げる
    static func loadConfig() throws -> [Hazkey_Config_Profile] {
        let configDir = Self.getConfigDirectory()
        let configPath = configDir.appendingPathComponent("config.json")

        // 設定ファイルの有無を確認する
        // 存在しなければ既定プロファイルから生成した正規化済み設定を返す
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            NSLog("Config file does not exist at: \(configPath.path), returning empty config")
            return try normalizeProfiles([Self.genDefaultConfig()])
        }

        // 設定ファイルの内容を読み込む
        let jsonData = try Data(contentsOf: configPath)

        let configs = try decodeProfiles(from: jsonData)

        NSLog("Config loaded from: \(configPath.path)")
        return configs
    }

    /// 設定JSONをプロファイル列へ復号する
    ///
    /// 最上位配列の各要素を個別に復号して、未知フィールドを無視して正規化する
    ///
    /// 空配列の場合は既定プロファイルへ縮退する
    ///
    /// - Parameter jsonData: config.jsonの内容
    /// - Returns: 検証済みプロファイル列を返す
    /// - Throws: 形式不正や検証失敗の場合に投げる
    static func decodeProfiles(from jsonData: Data) throws -> [Hazkey_Config_Profile] {
        guard let jsonArray = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [Any]
        else {
            throw ConfigError.invalidJSONTopLevel
        }

        var profiles: [Hazkey_Config_Profile] = []
        var decodeOptions = JSONDecodingOptions()
        decodeOptions.ignoreUnknownFields = true
        for (index, jsonValue) in jsonArray.enumerated() {
            guard let jsonObject = jsonValue as? [String: Any] else {
                throw ConfigError.invalidJSONProfile(index: index)
            }
            let jsonObjectData = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
            let config = try Hazkey_Config_Profile(
                jsonUTF8Data: jsonObjectData, options: decodeOptions)
            profiles.append(config)
        }

        if profiles.isEmpty {
            NSLog("Loaded empty config. returning default config...")
            return try normalizeProfiles([Self.genDefaultConfig()])
        }

        return try normalizeProfiles(profiles)
    }

    /// プロファイル列を検証して正規化する
    ///
    /// 各プロファイルにnormalizeProfileを適用する
    ///
    /// - Parameter profiles: 検証対象のプロファイル列
    /// - Returns: 正規化済みプロファイル列を返す
    /// - Throws: 空配列や検証失敗の場合に投げる
    static func normalizeProfiles(_ profiles: [Hazkey_Config_Profile]) throws -> [Hazkey_Config_Profile] {
        guard !profiles.isEmpty else {
            throw ConfigError.emptyProfiles
        }
        return try profiles.map(normalizeProfile)
    }

    /// 単一プロファイルを検証して正規化する
    ///
    /// 欠落した任意項目を既定値で補い、enumと数値範囲を検証する
    ///
    /// 補完対象を以下に示す
    /// - 変換方式
    /// - 補助表示
    /// - 候補表示
    /// - [zenzai_infer_limit]
    /// - [num_suggestions]
    /// - [auto_convert_min_chars]
    /// - 候補表示件数
    /// - 切替ホットキー
    /// - 半角カナ
    /// - 拡張絵文字
    /// - [use_address_dictionary]
    /// - [use_engineering_dictionary]
    ///
    /// 範囲検査を以下に示す
    /// - 候補提案数
    /// - 自動変換最小文字数
    /// - 候補表示件数が1〜10
    /// - 推論上限が1〜100である
    ///
    /// - Parameter profile: 検証対象のプロファイル
    /// - Returns: 正規化済みプロファイルを返す
    /// - Throws: 未知のenumや範囲外の値がある場合に投げる
    static func normalizeProfile(_ profile: Hazkey_Config_Profile) throws -> Hazkey_Config_Profile {
        let defaults = Self.genDefaultConfig()
        var normalized = profile

        if !normalized.hasAutoConvertMode {
            normalized.autoConvertMode = defaults.autoConvertMode
        }
        if !normalized.hasAuxTextMode {
            normalized.auxTextMode = defaults.auxTextMode
        }
        if !normalized.hasSuggestionListMode {
            normalized.suggestionListMode = defaults.suggestionListMode
        }
        if !normalized.hasNumSuggestions {
            normalized.numSuggestions = defaults.numSuggestions
        }
        if !normalized.hasAutoConvertMinChars {
            normalized.autoConvertMinChars = defaults.autoConvertMinChars
        }
        if !normalized.hasNumCandidatesPerPage {
            normalized.numCandidatesPerPage = defaults.numCandidatesPerPage
        }
        if !normalized.hasZenzaiInferLimit {
            normalized.zenzaiInferLimit = defaults.zenzaiInferLimit
        }
        if !normalized.hasZenzaiToggleHotkey {
            normalized.zenzaiToggleHotkey = defaults.zenzaiToggleHotkey
        }
        if !normalized.specialConversionMode.hasHalfwidthKatakana {
            normalized.specialConversionMode.halfwidthKatakana =
                defaults.specialConversionMode.halfwidthKatakana
        }
        if !normalized.specialConversionMode.hasExtendedEmoji {
            normalized.specialConversionMode.extendedEmoji =
                defaults.specialConversionMode.extendedEmoji
        }
        if !normalized.hasUseAddressDictionary {
            normalized.useAddressDictionary = defaults.useAddressDictionary
        }
        if !normalized.hasUseEngineeringDictionary {
            normalized.useEngineeringDictionary = defaults.useEngineeringDictionary
        }
        if !normalized.hasUseTypoCorrection {
            normalized.useTypoCorrection = defaults.useTypoCorrection
        }
        if !normalized.hasZenzaiRightContext {
            normalized.zenzaiRightContext = defaults.zenzaiRightContext
        }
        if !normalized.hasZenzaiAlignmentSeparator {
            normalized.zenzaiAlignmentSeparator = defaults.zenzaiAlignmentSeparator
        }

        try validateEnums(normalized)
        try validateRange(normalized.numSuggestions, field: "numSuggestions", range: 1...10)
        try validateRange(normalized.autoConvertMinChars, field: "autoConvertMinChars", range: 1...10)
        try validateRange(normalized.numCandidatesPerPage, field: "numCandidatesPerPage", range: 1...10)
        try validateRange(normalized.zenzaiInferLimit, field: "zenzaiInferLimit", range: 1...100)
        return normalized
    }

    /// プロファイル内のenum値を検証する
    ///
    /// - Parameter profile: 検証対象のプロファイル
    /// - Throws: 未知のenum値がある場合に投げる
    private static func validateEnums(_ profile: Hazkey_Config_Profile) throws {
        if case .UNRECOGNIZED(let rawValue) = profile.autoConvertMode {
            throw ConfigError.unrecognizedEnum(field: "autoConvertMode", rawValue: rawValue)
        }
        if case .UNRECOGNIZED(let rawValue) = profile.auxTextMode {
            throw ConfigError.unrecognizedEnum(field: "auxTextMode", rawValue: rawValue)
        }
        if case .UNRECOGNIZED(let rawValue) = profile.suggestionListMode {
            throw ConfigError.unrecognizedEnum(field: "suggestionListMode", rawValue: rawValue)
        }
    }

    /// 数値が許容範囲内かを検証する
    ///
    /// - Parameters:
    ///   - value: 検証対象の値
    ///   - field: 検証対象のフィールド名
    ///   - range: 許容範囲
    /// - Throws: 範囲外の場合に投げる
    private static func validateRange(
        _ value: Int32,
        field: String,
        range: ClosedRange<Int32>
    ) throws {
        guard range.contains(value) else {
            throw ConfigError.valueOutOfRange(field: field, value: value, range: range)
        }
    }

    /// 設定ディレクトリのパスを返す
    ///
    /// 環境変数XDG_CONFIG_HOMEが設定されていれば、その配下のhazkey-communityを使用して、未設定時はホーム配下の既定位置を使用する
    ///
    /// - Returns: 設定ディレクトリのURLを返す
    static func getConfigDirectory() -> URL {
        if let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
            !xdgConfigHome.isEmpty
        {
            return URL(fileURLWithPath: xdgConfigHome).appendingPathComponent("hazkey-community")
        }

        // XDG_CONFIG_HOME未設定時の代替として、"~/.config/hazkey-community/"ディレクトリを使用する
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".config").appendingPathComponent("hazkey-community")
    }

    /// データディレクトリのパスを返す
    ///
    /// 環境変数XDG_DATA_HOMEが設定されていれば、その配下のhazkey-communityを使用して、未設定時はホーム配下の既定位置を使用する
    ///
    /// - Returns: データディレクトリのURLを返す
    static func getDataDirectory() -> URL {
        if let xdgDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"],
            !xdgDataHome.isEmpty
        {
            return URL(fileURLWithPath: xdgDataHome).appendingPathComponent("hazkey-community")
        }

        // 環境変数XDG_DATA_HOME未設定時の代替として、"~/.local/share/hazkey-community/"ディレクトリを使用する
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".local").appendingPathComponent("share")
            .appendingPathComponent("hazkey-community")
    }

    /// 状態ディレクトリのパスを返す
    ///
    /// 環境変数XDG_STATE_HOMEが設定されていれば、その配下のhazkey-communityを使用して、未設定時はホーム配下の既定位置を使用する
    ///
    /// 学習メモリの配置基準になる
    ///
    /// - Returns: 状態ディレクトリのURLを返す
    static func getStateDirectory() -> URL {
        if let xdgStateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"],
            !xdgStateHome.isEmpty
        {
            return URL(fileURLWithPath: xdgStateHome).appendingPathComponent("hazkey-community")
        }

        // 環境変数XDG_STATE_HOME未設定時の代替として、"~/.local/state/hazkey-community/"を使用する
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".local").appendingPathComponent("state")
            .appendingPathComponent("hazkey-community")
    }

    /// キャッシュディレクトリのパスを返す
    ///
    /// 環境変数XDG_CACHE_HOMEが設定されていれば、その配下のhazkey-communityを使用して、未設定時はホーム配下の既定位置を使用する
    ///
    /// - Returns: キャッシュディレクトリのURLを返す
    static func getCacheDirectory() -> URL {
        if let xdgCacheHome = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"],
            !xdgCacheHome.isEmpty
        {
            return URL(fileURLWithPath: xdgCacheHome).appendingPathComponent("hazkey-community")
        }

        // 環境変数XDG_CACHE_HOME未設定時の代替として、"~/.cache/hazkey-community/"を使用する
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".cache").appendingPathComponent("hazkey-community")
    }

    /// 候補表示にリッチ候補を使うかを判定する
    ///
    /// 予測候補はuseRichSuggestionを、通常変換はuseRichCandidatesを使用する
    ///
    /// - Parameters:
    ///   - profile: 判定対象のプロファイル
    ///   - isSuggestion: 予測候補かどうかの真偽値
    /// - Returns: リッチ表示を使う場合に真を返す
    static func requestRichCandidates(
        for profile: Hazkey_Config_Profile,
        isSuggestion: Bool
    ) -> Bool {
        isSuggestion ? profile.useRichSuggestion : profile.useRichCandidates
    }

    /// 学習メモリのディレクトリを解決する
    ///
    /// [use_profile_independent_history]が無効の場合は、共有のmemory配下を返す
    ///
    /// 有効の場合はprofile_idをbase64url化した専用配下を返して、空の識別子はdefault扱いになる
    ///
    /// - Parameters:
    ///   - profile: 判定対象のプロファイル
    ///   - stateDirectory: 状態ディレクトリ (省略時は既定の状態位置)
    /// - Returns: 学習メモリのディレクトリを返す
    static func memoryDirectory(
        for profile: Hazkey_Config_Profile,
        stateDirectory: URL = HazkeyServerConfig.getStateDirectory()
    ) -> URL {
        let sharedDirectory = stateDirectory.appendingPathComponent("memory", isDirectory: true)
        guard profile.useProfileIndependentHistoryEffective else {
            return sharedDirectory
        }

        let profileIdentifier = profile.profileID.isEmpty
            ? "default"
            : Data(profile.profileID.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        return sharedDirectory.appendingPathComponent(profileIdentifier, isDirectory: true)
    }

    /// 有効なニューラル変換モデルのパスを解決する
    ///
    /// カスタム重み指定が有効で実在する通常ファイルの場合はそのパスを返して、それ以外は探索済みパスを返す
    ///
    /// 通常ファイルでない指定は記録してnilを返す
    ///
    /// - Parameters:
    ///   - profile: カスタム重み設定を持つプロファイル
    ///   - discoveredModelPath: 探索で見つかったモデルパス
    /// - Returns: 有効なモデルパスを返して、解決できない場合はnilを返す
    static func resolveZenzaiModelPath(
        for profile: Hazkey_Config_Profile,
        discoveredModelPath: URL?
    ) -> URL? {
        guard profile.useZenzaiCustomWeight, !profile.zenzaiWeightPath.isEmpty else {
            return discoveredModelPath
        }

        let customModelPath = URL(fileURLWithPath: profile.zenzaiWeightPath)
        guard let values = try? customModelPath.resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true
        else {
            NSLog("Configured Zenzai model is not a regular file: \(customModelPath.path)")
            return nil
        }
        return customModelPath
    }

    /// 現在のプロファイルに対応する学習メモリのディレクトリを返す
    ///
    /// - Returns: 学習メモリのディレクトリを返す
    func memoryDirectory() -> URL {
        Self.memoryDirectory(for: currentProfile)
    }

    /// 学習メモリのディレクトリを必要に応じて作成する
    ///
    /// - Throws: 作成に失敗した場合に投げる
    func createMemoryDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: memoryDirectory(), withIntermediateDirectories: true)
    }

    /// 現在有効なニューラル変換モデルのパスを解決する
    ///
    /// バックエンドデバイスが無い場合はnilを返す
    ///
    /// - Returns: 有効なモデルパスを返して、解決できない場合はnilを返す
    private func resolveActiveZenzaiModelPath() -> URL? {
        guard !ggmlBackendDevices.isEmpty else {
            return nil
        }
        return Self.resolveZenzaiModelPath(
            for: currentProfile, discoveredModelPath: getZenzaiModelPath())
    }

    /// バージョン依存のZenzai v3モードを生成する純関数
    ///
    /// profile / topic / style / preferenceとleftSideContextの導出は、genZenzaiModeの従来式と同一
    /// 右文脈フラグが無効のときは従来式と等しい値を返す
    ///
    /// - Parameters:
    ///   - profile: 有効なプロファイル
    ///   - leftContext: カーソル左側の文脈文字列
    ///   - rightContext: カーソル右側の文脈文字列 (接続単位の保持値)
    ///   - modelURL: 実体へ解決済みのモデルパス (nilは非対応扱い)
    ///   - sendsFullReadingForAlignment: 全文を送る場合に区切りを有効化する
    /// - Returns: 変換要求に渡すv3モードを返す
    static func makeZenzaiV3DependentMode(
        profile: Hazkey_Config_Profile,
        leftContext: String,
        rightContext: String,
        modelURL: URL?,
        sendsFullReadingForAlignment: Bool = false
    ) -> ConvertRequestOptions.ZenzaiV3DependentMode {
        let supported = ZenzaiModelCapabilities.supportsRightContext(modelURL: modelURL)
        let rightSideContext: String? =
            (profile.zenzaiRightContextEffective && profile.zenzaiContextualMode && supported
                && !rightContext.isEmpty) ? rightContext : nil
        return ConvertRequestOptions.ZenzaiV3DependentMode(
            profile: profile.zenzaiProfile,
            topic: profile.zenzaiTopic,
            style: profile.zenzaiStyle,
            preference: profile.zenzaiPreference,
            leftSideContext: profile.zenzaiContextualMode ? leftContext : nil,
            rightSideContext: rightSideContext,
            enableAlignmentSeparator: sendsFullReadingForAlignment
                && Self.alignmentSeparatorApplies(profile: profile, modelURL: modelURL)
        )
    }

    /// アラインメント区切り (U+EE08) をZenzai v3モードへ反映するかを判定する
    ///
    /// 区切りは組成中の読みの情報であり周辺テキストではないため、文脈変換設定には依存しない。
    /// カーソル末尾での適用可否は全文送信判定が受け持つ。
    static func alignmentSeparatorApplies(
        profile: Hazkey_Config_Profile,
        modelURL: URL?
    ) -> Bool {
        profile.zenzaiAlignmentSeparatorEffective
            && ZenzaiModelCapabilities.supportsAlignmentSeparator(modelURL: modelURL)
    }

    /// 変換要求用のニューラル変換モードを生成する
    ///
    /// 無効時や利用不可時は無効モードを返して、有効時は重みと推論上限と文脈付き条件を束ねる
    ///
    /// カーソル左側の文脈はleftContextで渡して、文脈モード有効時のみ参照する
    ///
    /// モデルパスは実体へ解決して渡すが、保持値は管理下リンクのままにする
    ///
    /// - Parameters:
    ///   - leftContext: カーソル左側の文脈文字列
    ///   - rightContext: カーソル右側の文脈文字列 (省略時は送らない)
    ///   - requestRichCandidates: リッチ候補要求の上書き (省略時は現設定を使用する)
    ///   - sendsFullReadingForAlignment: 全文を送る場合に区切りを有効化する
    /// - Returns: 変換要求に渡すニューラル変換モードを返す
    func genZenzaiMode(
        leftContext: String,
        rightContext: String = "",
        requestRichCandidates: Bool? = nil,
        sendsFullReadingForAlignment: Bool = false
    )
        -> ConvertRequestOptions.ZenzaiMode
    {
        genZenzaiMode(
            snapshot: makeZenzaiRequestSnapshot(),
            leftContext: leftContext,
            rightContext: rightContext,
            requestRichCandidates: requestRichCandidates,
            sendsFullReadingForAlignment: sendsFullReadingForAlignment)
    }

    /// 1回の変換要求で使うニューラル変換の解決結果
    enum ZenzaiRequestSnapshot {
        /// ニューラル変換を使わない (無効・利用不可・モデルなしのいずれか)
        case off
        /// ニューラル変換を使う (モデルパスは実体へ解決済み)
        case on(resolvedModelURL: URL, deviceConfig: ZenzaiDeviceConfig)
    }

    /// 1回の変換要求で使うニューラル変換の解決結果を作る
    ///
    /// モデルのリンク解決とバックエンドデバイスの列挙を、ここで1回だけ行う
    ///
    /// 管理下モデルのリンク切替へ要求ごとに追従させるため、結果は要求をまたいで保持しないこと
    ///
    /// ニューラル変換を使わない場合は、リンク解決もデバイス列挙も行わない
    ///
    /// - Returns: 要求1回分のスナップショットを返す
    func makeZenzaiRequestSnapshot() -> ZenzaiRequestSnapshot {
        guard zenzaiAvailable, let zenzaiModelPath = zenzaiModelPath, currentProfile.zenzaiEnable
        else {
            return .off
        }
        let deviceName =
            currentProfile.zenzaiBackendDeviceName.isEmpty
            ? "CPU" : currentProfile.zenzaiBackendDeviceName
        // 変換エンジンは読み込み済みモデルをプロセス全体のレジストリに保持して、重みパス文字列をキーにしている
        // (SharedZenzModelCache.cacheKey(path:deviceConfig:))
        //
        // 管理下のzenzai.ggufシンボリックリンクをそのまま渡すと、リンク先を切り替えても以前のモデルを供給し続けるため、
        // [Hazkey Community設定]画面でのモデル切替がサーバ再起動後まで反映されない
        //
        // ここでリンクを実体に解決することにより、キーが実ファイルを追跡するようにする
        // なお、zenzaiModelPath自体は意図的に管理下シンボリックリンクのままにしている
        // (CurrentConfig.zenzai_model_pathとそのテストが依存しているため)
        return .on(
            resolvedModelURL: zenzaiModelPath.resolvingSymlinksInPath(),
            deviceConfig: createDeviceConfig(deviceName: deviceName))
    }

    /// スナップショットから変換要求用のニューラル変換モードを生成する
    ///
    /// 同じ要求の中で判定とモード生成に同じスナップショットを使い、リンク解決とデバイス列挙の重複を避ける
    ///
    /// - Parameters:
    ///   - snapshot: makeZenzaiRequestSnapshot()で作った、この要求のスナップショット
    ///   - leftContext: カーソル左側の文脈文字列
    ///   - rightContext: カーソル右側の文脈文字列 (省略時は送らない)
    ///   - requestRichCandidates: リッチ候補要求の上書き (省略時は現設定を使用する)
    ///   - sendsFullReadingForAlignment: 全文を送る場合に区切りを有効化する
    /// - Returns: 変換要求に渡すニューラル変換モードを返す
    func genZenzaiMode(
        snapshot: ZenzaiRequestSnapshot,
        leftContext: String,
        rightContext: String = "",
        requestRichCandidates: Bool? = nil,
        sendsFullReadingForAlignment: Bool = false
    ) -> ConvertRequestOptions.ZenzaiMode {
        switch snapshot {
        case .off:
            return ConvertRequestOptions.ZenzaiMode.off
        case .on(let resolvedModelURL, let deviceConfig):
            return ConvertRequestOptions.ZenzaiMode.on(
                weight: resolvedModelURL,
                inferenceLimit: Int(currentProfile.zenzaiInferLimit),
                requestRichCandidates: requestRichCandidates ?? currentProfile.useRichCandidates,
                personalizationMode: nil,
                versionDependentMode: .v3(
                    Self.makeZenzaiV3DependentMode(
                        profile: currentProfile,
                        leftContext: leftContext,
                        rightContext: rightContext,
                        modelURL: resolvedModelURL,
                        sendsFullReadingForAlignment: sendsFullReadingForAlignment
                    )),
                deviceConfig: deviceConfig
            )
        }
    }

    /// 基本の変換要求オプションを生成する
    ///
    /// [use_input_history]と新規履歴の保存可否から学習種別を決め、1頁の候補数と特殊候補と学習配置と誤字補正無効化を束ねる
    ///
    /// - Returns: 変換要求の基礎オプションを返す
    func genBaseConvertRequestOptions() -> ConvertRequestOptions {
        let learningType =
            switch (currentProfile.useInputHistory, currentProfile.stopStoreNewHistory) {
            case (true, false):
                LearningType.inputAndOutput
            case (true, true):
                LearningType.onlyOutput
            default:
                LearningType.nothing
            }

        let specialCandidateProviders: [any SpecialCandidateProvider] = {
            let mode = currentProfile.specialConversionMode
            let providers: [SpecialCandidateProvider?] = [
                mode.commaSeparatedNumber ? CommaSeparatedNumberSpecialCandidateProvider() : nil,
                mode.calendar ? CalendarSpecialCandidateProvider() : nil,
                mode.hazkeyVersion ? VersionSpecialCandidateProvider() : nil,
                mode.mailDomain ? EmailAddressSpecialCandidateProvider() : nil,
                mode.romanTypography ? TypographySpecialCandidateProvider() : nil,
                mode.time ? TimeExpressionSpecialCandidateProvider() : nil,
                mode.unicodeCodepoint ? UnicodeSpecialCandidateProvider() : nil,
            ]
            return providers.compactMap { $0 }
        }()

        let zenzaiMode = genZenzaiMode(leftContext: "")

        return ConvertRequestOptions.init(
            N_best: Int(currentProfile.numCandidatesPerPage),
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .none,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: true,
            halfWidthKanaCandidate: currentProfile.specialConversionMode.halfwidthKatakana,
            learningType: learningType,
            maxMemoryCount: 65536,
            shouldResetMemory: false,
            memoryDirectoryURL: memoryDirectory(),
            sharedContainerURL: HazkeyServerConfig.getCacheDirectory().appendingPathComponent(
                "shared", isDirectory: true),
            textReplacer: .empty,
            specialCandidateProviders: specialCandidateProviders,
            zenzaiMode: zenzaiMode,
            preloadDictionary: false,
            // AzooKeyKanaKanjiConverterのフォーク (hazkeyブランチ) では、
            // 引数needTypoCorrection: BoolがtypoCorrectionMode: TypoCorrectionModeに置き換えている
            //
            // .disabledは、従来の"needTypoCorrection: false"と動作上完全に等価 (誤字補正を無条件に無効化)
            // (KanaKanjiConverter.isClassicTypoCorrectionEnabledを参照)
            typoCorrectionMode: .disabled,
            metadata: ConvertRequestOptions.Metadata.init(versionString: "Hazkey-Community \(hazkeyVersion)")
        )
    }

    /// 有効なキーマップを読み込む
    ///
    /// 内蔵定義と利用者定義TSVを後勝ちで合成して、不明な定義や読み込み失敗は飛ばす
    ///
    /// - Returns: 合成済みキーマップを返す
    func loadKeymap() -> Keymap {
        var maps: Keymap = [:]
        outer: for enabledKeymap in currentProfile.enabledKeymaps.reversed() {
            var newKeymapRule: Keymap
            if enabledKeymap.isBuiltIn {
                switch enabledKeymap.filename {
                case "JIS Kana":
                    newKeymapRule = JISKanaMap
                case "Japanese Symbol":
                    newKeymapRule = japaneseSymbolMap
                case "Fullwidth Period":
                    newKeymapRule = fullwidthPeriodMap
                case "Fullwidth Comma":
                    newKeymapRule = fullwidthCommaMap
                case "Fullwidth Symbol":
                    newKeymapRule = fullwidthSymbolMap
                case "Fullwidth Number":
                    newKeymapRule = fullwidthNumberMap
                case "Fullwidth Space":
                    newKeymapRule = fullwidthSpaceMap
                default:
                    NSLog("Unknown built-in keymap: \(enabledKeymap.name)")
                    continue outer
                }
            } else {
                // ユーザ定義キーマップを読み込む
                let customKeymapFile = HazkeyServerConfig.getConfigDirectory()
                    .appendingPathComponent(
                        "keymap", isDirectory: true
                    ).appendingPathComponent(enabledKeymap.filename, isDirectory: false)
                do {
                    let contents = try String(contentsOf: customKeymapFile, encoding: .utf8)
                    newKeymapRule = [:]
                    newKeymapRule = Self.parseCustomKeymap(contents)
                } catch {
                    NSLog(
                        "Failed to load custom keymap \(enabledKeymap.name): \(error)"
                    )
                    continue outer
                }
            }
            maps.merge(newKeymapRule) { (_, second) in second }
        }

        return maps
    }

    /// 利用者定義キーマップの内容を解釈する
    ///
    /// タブ区切り1列は無効化、2列以上は入力文字と修飾文字として取り込む
    ///
    /// - Parameter contents: TSVファイルの内容
    /// - Returns: 解釈済みキーマップを返す
    static func parseCustomKeymap(_ contents: String) -> Keymap {
        var keymap: Keymap = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let key = columns.first?.first else { continue }

            switch columns.count {
            case 1:
                keymap[key] = nil
            case 2...:
                guard let input = columns[1].first else { continue }
                keymap[key] = (input, columns.count > 2 ? columns[2].first : nil)
            default:
                continue
            }
        }
        return keymap
    }

    /// 指定名の入力テーブルを読み込んで登録する
    ///
    /// 区切り表を土台に、有効な入力表を後勝ちで合成する
    ///
    /// 不明な定義や読み込み失敗は飛ばす
    ///
    /// - Parameter tableName: 登録先の入力方式名
    func loadInputTable(tableName: String) {
        var tables: [InputTable] = [compositionSeparatorTable]
        outer: for enabledTable in currentProfile.enabledTables.reversed() {
            let tableToAdd: InputTable
            if enabledTable.isBuiltIn {
                switch enabledTable.filename {
                case "Romaji":
                    tableToAdd = romajiTable
                case "Kana":
                    tableToAdd = kanaTable
                default:
                    debugLog("Unknown built-in input table: \(enabledTable.name)")
                    continue outer
                }
            } else {
                // ユーザ定義入力テーブルを読み込む
                let customTableFile = HazkeyServerConfig.getConfigDirectory()
                    .appendingPathComponent(
                        "table", isDirectory: true
                    ).appendingPathComponent(enabledTable.filename, isDirectory: false)
                do {
                    tableToAdd = try InputStyleManager.loadTable(from: customTableFile)
                } catch {
                    NSLog("Failed to load custom table \(enabledTable.name)Q \(error)")
                    continue outer
                }
            }
            tables.append(tableToAdd)
        }

        let inputTable = InputTable(tables: tables, order: InputTable.Ordering.lastInputWins)
        InputStyleManager.registerInputStyle(table: inputTable, for: tableName)
    }

    /// 直接入力サブモードへ入る文字列を返す
    ///
    /// [Shift]キー同時押下で、直接入力へ切り替える対象文字である
    ///
    /// - Returns: 対象文字の配列を返す
    func getSubModeEntryPointChars() -> [Character] {
        return Array(currentProfile.submodeEntryPointChars)
    }

    /// 有効なニューラル変換モデルを解決し直して準備する
    ///
    /// 起動時と設定適用後の初回打鍵の待ち時間を抑える
    func reloadZenzaiModel() {
        zenzaiModelPath = resolveActiveZenzaiModelPath()
        self.zenzaiAvailable = (ggmlBackendDevices.count > 0) && (zenzaiModelPath != nil)
    }
}

/// 設定プロファイルの欠落時実効値を提供する
///
/// 旧設定との互換のため、項目欠落時の代替値を一箇所で定義する
extension Hazkey_Config_Profile {
    /// プロファイル非依存の入力履歴設定[use_profile_independent_history]の実効値である
    ///
    /// 旧設定または項目欠落時はfalseとする (従来動作を維持)
    var useProfileIndependentHistoryEffective: Bool {
        hasUseProfileIndependentHistory ? useProfileIndependentHistory : false
    }

    /// 拡張絵文字候補設定の実効値である
    ///
    /// 旧設定または項目欠落時は、既存動作を維持するためtrueとする
    var extendedEmojiEffective: Bool {
        let mode = specialConversionMode
        return mode.hasExtendedEmoji ? mode.extendedEmoji : true
    }

    /// 住所辞書設定[use_address_dictionary]の実効値である
    ///
    /// 旧設定または項目欠落時は既定の無効として扱う
    var useAddressDictionaryEffective: Bool {
        hasUseAddressDictionary ? useAddressDictionary : false
    }

    /// 工学辞書設定[use_engineering_dictionary]の実効値である
    ///
    /// 旧設定または項目欠落時は既定の無効として扱う
    var useEngineeringDictionaryEffective: Bool {
        hasUseEngineeringDictionary ? useEngineeringDictionary : false
    }

    var useTypoCorrectionEffective: Bool {
        hasUseTypoCorrection ? useTypoCorrection : false
    }

    var zenzaiRightContextEffective: Bool {
        hasZenzaiRightContext ? zenzaiRightContext : false
    }

    var zenzaiAlignmentSeparatorEffective: Bool {
        hasZenzaiAlignmentSeparator ? zenzaiAlignmentSeparator : false
    }
}

/// 利用可能なllama.cpp(GGML)のバックエンドデバイスを列挙する
///
/// バックエンドの探索ディレクトリは、次の優先順位で決める
///
/// 1. 引数backendDirectoryOverride(nil以外の場合)
///
/// 2. 環境変数GGML_BACKEND_DIR
///
/// 3. システム既定値 (配下のlibllama/backends/)
///
/// backendDirectoryOverrideは、安全確認処理がVulkanを含まない隔離配置を指定するために使用する
///
/// 危険と判定した組み合わせの再読み込みを避ける
///
/// - Parameter backendDirectoryOverride: 探索先の上書き (省略時は、環境変数と既定値を使用する)
/// - Returns: 列挙したバックエンドデバイスを返す
func getZenzaiDevices(backendDirectoryOverride: String? = nil) -> [GGMLBackendDevice] {
    var ggmlBackendDirectory =
        backendDirectoryOverride
        ?? ProcessInfo.processInfo.environment["GGML_BACKEND_DIR"]
        ?? (systemLibraryPath + "/libllama/backends/")
    // GGMLはディレクトリ名の末尾に/が必要なため、無ければ補う
    if !ggmlBackendDirectory.hasSuffix("/") {
        ggmlBackendDirectory.append("/")
    }
    loadGGMLBackends(from: ggmlBackendDirectory)

    let backendDevices = enumerateGGMLBackendDevices()
    #if DEBUG
        for device in backendDevices {
            NSLog(
                "GGML Backend Device: \(device.name), Type: \(device.type), Description: \(device.description)"
            )
        }
    #endif
    return backendDevices
}

/// 有効なニューラル変換モデルのパスを探索する
///
/// 探索順は[HAZKEY_ZENZAI_MODEL]の指定、利用者配下のzenzai.gguf、システム配備の順である
///
/// 最初に見つかった通常ファイルを返す
///
/// - Returns: 有効なモデルパスを返して、見つからない場合はnilを返す
func getZenzaiModelPath() -> URL? {
    let systemZenzaiModelPath = URL(fileURLWithPath: systemResourcePath)
        .appendingPathComponent("zenzai.gguf", isDirectory: false)
    let userZenzaiModelPath = HazkeyServerConfig.getDataDirectory()
        .appendingPathComponent("zenzai", isDirectory: true)
        .appendingPathComponent("zenzai.gguf", isDirectory: false)

    let paths: [URL] = [
        ProcessInfo.processInfo.environment["HAZKEY_ZENZAI_MODEL"].map { URL(filePath: $0) },
        userZenzaiModelPath,
        systemZenzaiModelPath,
    ].compactMap { $0 }

    for url in paths {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
            values.isDirectory == false
        {
            NSLog(url.path)
            return url
        }
    }
    return nil
}
