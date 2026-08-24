import Foundation
import KanaKanjiConverterModule
import SwiftProtobuf

let KEYMAP_FILE_SIZE_LIMIT = 1024 * 1024  //1MB
let TABLE_FILE_SIZE_LIMIT = 1024 * 1024  //1MB

enum ConfigError: LocalizedError {
    case invalidJSONTopLevel
    case invalidJSONProfile(index: Int)
    case emptyProfiles
    case unrecognizedEnum(field: String, rawValue: Int)
    case valueOutOfRange(field: String, value: Int32, range: ClosedRange<Int32>)

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
        }
    }
}

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

class HazkeyServerConfig {
    var profiles: [Hazkey_Config_Profile]
    var currentProfile: Hazkey_Config_Profile
    let dictionaryPath: URL
    var zenzaiAvailable: Bool
    var zenzaiModelPath: URL?
    var ggmlBackendDevices: [GGMLBackendDevice]

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

        // set dictionary path
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

        self.zenzaiModelPath = nil
        self.zenzaiAvailable = false
        self.ggmlBackendDevices = getZenzaiDevices()
        zenzaiModelPath = resolveActiveZenzaiModelPath()
        self.zenzaiAvailable = (ggmlBackendDevices.count > 0) && (zenzaiModelPath != nil)
    }

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
            $0.profiles = profiles
        }
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
            $0.currentConfig = currentConfig
        }
    }

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

        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    static func genDefaultConfig() -> Hazkey_Config_Profile {
        var newConf = Hazkey_Config_Profile.init()
        newConf.profileName = "Default"
        newConf.autoConvertMode =
            Hazkey_Config_Profile.AutoConvertMode.autoConvertForMultipleChars
        newConf.autoConvertMinChars = 2
        newConf.autoConvertHotkey = "Control+Shift+L"
        newConf.auxTextMode = Hazkey_Config_Profile.AuxTextMode.auxTextShowWhenCursorNotAtEnd
        newConf.suggestionListMode =
            Hazkey_Config_Profile.SuggestionListMode.suggestionListShowPredictiveResults
        newConf.numSuggestions = 3
        newConf.useRichSuggestion = false
        newConf.numCandidatesPerPage = 9
        newConf.useRichCandidates = false
        newConf.useInputHistory = true
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

    static func getDefaultProfile() -> Hazkey_ResponseEnvelope {
        let currentConfig = Hazkey_Config_CurrentConfig.with {
            $0.profiles = [Self.genDefaultConfig()]
        }
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
            $0.currentConfig = currentConfig
        }
    }

    func saveConfig(
        _ newProfiles: [Hazkey_Config_Profile],
        state: HazkeyServerState? = nil
    ) throws {
        let normalizedProfiles = try Self.normalizeProfiles(newProfiles)
        let configDir = Self.getConfigDirectory()
        let configPath = configDir.appendingPathComponent("config.json")

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
    }

    static func loadConfig() throws -> [Hazkey_Config_Profile] {
        let configDir = Self.getConfigDirectory()
        let configPath = configDir.appendingPathComponent("config.json")

        // Check if config file exists
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            NSLog("Config file does not exist at: \(configPath.path), returning empty config")
            return try normalizeProfiles([Self.genDefaultConfig()])
        }

        // Read file contents
        let jsonData = try Data(contentsOf: configPath)

        let configs = try decodeProfiles(from: jsonData)

        NSLog("Config loaded from: \(configPath.path)")
        return configs
    }

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

    static func normalizeProfiles(_ profiles: [Hazkey_Config_Profile]) throws -> [Hazkey_Config_Profile] {
        guard !profiles.isEmpty else {
            throw ConfigError.emptyProfiles
        }
        return try profiles.map(normalizeProfile)
    }

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
        if !normalized.specialConversionMode.hasHalfwidthKatakana {
            normalized.specialConversionMode.halfwidthKatakana =
                defaults.specialConversionMode.halfwidthKatakana
        }

        try validateEnums(normalized)
        try validateRange(normalized.numSuggestions, field: "numSuggestions", range: 1...10)
        try validateRange(normalized.autoConvertMinChars, field: "autoConvertMinChars", range: 1...10)
        try validateRange(normalized.numCandidatesPerPage, field: "numCandidatesPerPage", range: 1...10)
        try validateRange(normalized.zenzaiInferLimit, field: "zenzaiInferLimit", range: 1...100)
        return normalized
    }

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

    private static func validateRange(
        _ value: Int32,
        field: String,
        range: ClosedRange<Int32>
    ) throws {
        guard range.contains(value) else {
            throw ConfigError.valueOutOfRange(field: field, value: value, range: range)
        }
    }

    static func getConfigDirectory() -> URL {
        if let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
            !xdgConfigHome.isEmpty
        {
            return URL(fileURLWithPath: xdgConfigHome).appendingPathComponent("hazkey")
        }

        // Fallback to ~/.config/hazkey
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".config").appendingPathComponent("hazkey")
    }

    static func getDataDirectory() -> URL {
        if let xdgDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"],
            !xdgDataHome.isEmpty
        {
            return URL(fileURLWithPath: xdgDataHome).appendingPathComponent("hazkey")
        }

        // Fallback to ~/.local/share/hazkey
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".local").appendingPathComponent("share")
            .appendingPathComponent("hazkey")
    }

    static func getStateDirectory() -> URL {
        if let xdgStateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"],
            !xdgStateHome.isEmpty
        {
            return URL(fileURLWithPath: xdgStateHome).appendingPathComponent("hazkey")
        }

        // Fallback to ~/.local/state/hazkey
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".local").appendingPathComponent("state")
            .appendingPathComponent("hazkey")
    }

    static func getCacheDirectory() -> URL {
        if let xdgCacheHome = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"],
            !xdgCacheHome.isEmpty
        {
            return URL(fileURLWithPath: xdgCacheHome).appendingPathComponent("hazkey")
        }

        // Fallback to ~/.cache/hazkey
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".cache").appendingPathComponent("hazkey")
    }

    static func requestRichCandidates(
        for profile: Hazkey_Config_Profile,
        isSuggestion: Bool
    ) -> Bool {
        isSuggestion ? profile.useRichSuggestion : profile.useRichCandidates
    }

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

    func memoryDirectory() -> URL {
        Self.memoryDirectory(for: currentProfile)
    }

    func createMemoryDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: memoryDirectory(), withIntermediateDirectories: true)
    }

    private func resolveActiveZenzaiModelPath() -> URL? {
        guard !ggmlBackendDevices.isEmpty else {
            return nil
        }
        return Self.resolveZenzaiModelPath(
            for: currentProfile, discoveredModelPath: getZenzaiModelPath())
    }

    func genZenzaiMode(
        leftContext: String,
        requestRichCandidates: Bool? = nil
    )
        -> ConvertRequestOptions.ZenzaiMode
    {
        let deviceName =
            currentProfile.zenzaiBackendDeviceName.isEmpty
            ? "CPU" : currentProfile.zenzaiBackendDeviceName

        if zenzaiAvailable, let zenzaiModelPath = zenzaiModelPath, currentProfile.zenzaiEnable {
            return ConvertRequestOptions.ZenzaiMode.on(
                weight: zenzaiModelPath,
                inferenceLimit: Int(currentProfile.zenzaiInferLimit),
                requestRichCandidates: requestRichCandidates ?? currentProfile.useRichCandidates,
                personalizationMode: nil,
                versionDependentMode: .v3(
                    ConvertRequestOptions.ZenzaiV3DependentMode.init(
                        profile: currentProfile.zenzaiProfile,
                        topic: currentProfile.zenzaiTopic,
                        style: currentProfile.zenzaiStyle,
                        preference: currentProfile.zenzaiPreference,
                        leftSideContext: currentProfile.zenzaiContextualMode
                            ? leftContext : nil
                    )),
                deviceConfig: createDeviceConfig(deviceName: deviceName)
            )
        } else {
            return ConvertRequestOptions.ZenzaiMode.off
        }
    }

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
            needTypoCorrection: false,
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
            metadata: ConvertRequestOptions.Metadata.init(versionString: "Hazkey \(hazkeyVersion)")
        )
    }

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
                // load custom keymap
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
                // load custom table
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

    func getSubModeEntryPointChars() -> [Character] {
        return Array(currentProfile.submodeEntryPointChars)
    }

    func reloadZenzaiModel() {
        zenzaiModelPath = resolveActiveZenzaiModelPath()
        self.zenzaiAvailable = (ggmlBackendDevices.count > 0) && (zenzaiModelPath != nil)
    }
}

extension Hazkey_Config_Profile {
    /// Legacy or missing config keeps history shared between profiles.
    var useProfileIndependentHistoryEffective: Bool {
        hasUseProfileIndependentHistory ? useProfileIndependentHistory : false
    }
}

func getZenzaiDevices() -> [GGMLBackendDevice] {
    var ggmlBackendDirectory =
        ProcessInfo.processInfo.environment["GGML_BACKEND_DIR"]
        ?? (systemLibraryPath + "/libllama/backends/")
    // trailing slash is important
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
