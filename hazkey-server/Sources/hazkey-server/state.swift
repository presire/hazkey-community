import Foundation
import KanaKanjiConverterModule
import SwiftUtils

/// Entry kept per displayed candidate so we can distinguish converter results
/// from user-dictionary injections during commit.
enum DisplayedCandidate {
    case fromConverter(Candidate)
    /// Legacy: no longer produced after engine-injection migration.
    /// Engine-injected user-dict entries now arrive as `.fromConverter`.
    case fromUserDict(word: String)
    /// [community] Relative-date candidate injected by `RelativeDateProvider`.
    /// Treated like `.fromUserDict` at commit time (clear composing text, no
    /// learning) but kept as a distinct case for clarity and future extensions.
    case fromDateProvider(word: String)
    /// [community] Special-number candidate (subscript/superscript/circled/
    /// roman numerals/...) injected by `KanaNumberProvider`. Treated like
    /// `.fromDateProvider` at commit time (clear composing text, no
    /// learning) but kept distinct for clarity.
    case fromKanaNumberProvider(word: String)
    /// [community] Emoji 17.0 direct-conversion candidate injected by
    /// `EmojiCandidateProvider`. Consumes only the matched normalized-query
    /// prefix (`composingCount`) at commit time via `prefixComplete`, leaving
    /// any trailing suffix in the composition; never learns. Kept distinct
    /// for clarity and deletion routing.
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

/// [community] (reading, word) surface key identifying a candidate's learning
/// entries across CID variants. Reading is katakana-normalized so that a
/// hiragana reading from the composing text matches the katakana ruby stored
/// in the learning memory. Shared by the "deletable" annotation and the
/// delete handler, so a candidate shown as deletable is always deletable.
struct LearningSurfaceKey: Hashable {
    let reading: String
    let word: String

    init(reading: String, word: String) {
        self.reading = katakanaNormalized(reading)
        self.word = word
    }
}

/// Server-wide resources shared by every client connection.
///
/// The `KanaKanjiConverter` instance (dictionaries, Zenzai model, learning
/// memory, memoization caches) is heavy and process-global; only
/// per-composition state (lattice, completed data, Zenzai/prediction caches)
/// is keyed by `ConversionSessionID` inside the converter. Each socket client
/// gets its own `HazkeyServerState` holding one converter session plus its
/// own composing text and candidate list.
class HazkeySharedResources {
    let serverConfig: HazkeyServerConfig
    let converter: KanaKanjiConverter
    let userDictionary: UserDictionary = UserDictionary()
    /// [community] Cached immutable emoji provider. Built once per process;
    /// never refreshed thereafter.
    let emojiProvider: EmojiCandidateProvider?

    var keymap: Keymap
    var currentTableName: String
    var baseConvertRequestOptions: ConvertRequestOptions
    var learningDataNeedsCommit = false
    var userDictInjected = false

    /// [community] Upper bound on rows enumerated in one pass by
    /// `allLearningMemoryEntries()`. Must stay equal to the `maxMemoryCount`
    /// passed in `HazkeyServerConfig.genBaseConvertRequestOptions()`, which is
    /// the authoritative cap on stored entries.
    static let learningEnumerationLimit = 65_536

    /// [community] The annotation lookup runs once per keystroke, so an
    /// unrecoverable failure would otherwise write one log line per key.
    private var lastLearningLookupFailureLog: ContinuousClock.Instant?
    private static let learningLookupFailureLogInterval: Duration = .seconds(60)

    /// Session IDs of all live connections. Learning deletions invalidate
    /// every session's cached conversion state, not just the requester's, so
    /// a deleted entry cannot resurface in another client's list.
    private var liveConversionSessionIDs: Set<KanaKanjiConverter.ConversionSessionID> = []

    convenience init() {
        self.init(emojiDictionaryURL: nil)
    }

    /// - Parameter emojiDictionaryURL: Injected dictionary URL for tests.
    ///   `nil` uses the production E17 asset.
    init(emojiDictionaryURL: URL?) {
        self.serverConfig = HazkeyServerConfig()
        self.emojiProvider = EmojiCandidateProvider(
            dictionaryURL: emojiDictionaryURL ?? EmojiCandidateProvider.defaultDictionaryURL)

        self.converter = KanaKanjiConverter.init(dictionaryURL: serverConfig.dictionaryPath)

        // Initialize keymap and table
        self.keymap = serverConfig.loadKeymap()
        self.currentTableName = UUID().uuidString
        serverConfig.loadInputTable(tableName: currentTableName)

        // Create user state directories (history data)
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

        // Create user cache directories (user dictionary)
        do {
            try FileManager.default.createDirectory(
                at: HazkeyServerConfig.getCacheDirectory().appendingPathComponent(
                    "shared", isDirectory: true), withIntermediateDirectories: true)
        } catch {
            NSLog("Failed to create user cache directory: \(error.localizedDescription)")
        }

        // Initialize base convert options
        self.baseConvertRequestOptions = serverConfig.genBaseConvertRequestOptions()
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

    /// Registers a live connection session for server-wide cache invalidation.
    func registerConversionSession(_ id: KanaKanjiConverter.ConversionSessionID) {
        liveConversionSessionIDs.insert(id)
    }

    /// Unregisters a closed connection session.
    func unregisterConversionSession(_ id: KanaKanjiConverter.ConversionSessionID) {
        liveConversionSessionIDs.remove(id)
    }

}

// MARK: - Shared configuration and learning

extension HazkeySharedResources {
    /// Reloads keymap, input table, base options, and memory directory.
    /// Composition state is per-connection and untouched here; each
    /// `HazkeyServerState` resets its own composition after calling this.
    func reinitializeConfiguration() {
        // Only the requesting connection resets its own composition after this
        // call; other live connections keep their in-flight composition. This
        // is safe because `InputStyleManager.registerInputStyle(table:for:)`
        // (fork `KanaKanjiConverterModule`) only ADDS an entry keyed by the
        // new `.tableName(UUID)` and never removes previously registered
        // names, so `ComposingText` elements already tagged with the old
        // `.tableName(...)` still resolve. Residual (acceptable): within one
        // in-flight composition, keys inserted before the config change keep
        // the old mapping while later keys use the new keymap/table.
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
    }

    /// [community] The converter applies `memoryDirectoryURL` lazily inside
    /// `requestCandidates(_:options:)`. The settings dialog never converts, so
    /// the learning-history listing and deletion would keep reading the
    /// previous profile's directory until the next keystroke. Apply it eagerly.
    func syncConverterLearningConfig() {
        converter.updateLearningConfig(
            LearningConfig(
                learningType: baseConvertRequestOptions.learningType,
                maxMemoryCount: baseConvertRequestOptions.maxMemoryCount,
                memoryURL: baseConvertRequestOptions.memoryDirectoryURL))
    }

    func saveLearningData() -> Hazkey_ResponseEnvelope {
        if learningDataNeedsCommit {
            converter.commitUpdateLearningData()
            learningDataNeedsCommit = false
        }
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
        // Deleting the directory alone leaves the converter's uncommitted
        // temporal memory, its cached memory LOUDS, and the dirty flag intact,
        // so the next commit would write the pending entries straight back into
        // the directory the user just cleared. Reset converter state and the
        // flag on both branches.
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

    /// Learning history merged to one row per (reading, word) surface key.
    /// The learning memory stores one row per (ruby, word, lcid, rcid), so the
    /// same surface can surface as several CID-variant rows (e.g. the
    /// clause-bigram entry and the whole-string entry of one commit). The
    /// dialog displays one merged row per surface and deletion removes every
    /// variant — the same semantics as the candidate delete hotkey — so
    /// lcid/rcid are not exposed to clients.
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

        // An entry can only be stored under its own reading, so point-looking up
        // just the requested readings is equivalent to scanning everything.
        let existingKeys = Set(
            try converter.persistedLearningMemoryKeys(
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
        // Deleted entries must not surface in subsequent conversions. The
        // converter reuses each session's lattice (and the Zenzai
        // draft/memoized constraint) when the composing text is unchanged, so
        // a rebuilt candidate list would otherwise resurrect the deleted
        // entries from the stale caches. Resetting every live session drops
        // only cached conversion state — composing texts live in each
        // per-connection HazkeyServerState and the learning memory on disk,
        // both unaffected.
        for id in liveConversionSessionIDs {
            do { try converter.withSession(id) { converter.stopComposition() } }
            catch { NSLog("[hazkey] Failed to reset conversion session \(id): \(error)") }
        }
        converter.purgeZenzaiMemoizationCache()
        return UInt32(uniqueKeys.count)
    }

    /// [community] Delete every learning entry matching each (reading, word)
    /// surface key, regardless of CID — the same semantics as the candidate
    /// delete hotkey (`deleteCandidateLearningData`). Used by the settings
    /// dialog, whose rows are merged across CID variants by
    /// `listLearningEntries`. Surfaces with no stored entry are skipped so a
    /// row deleted in the meantime cannot fail the whole batch; the returned
    /// count is the number of exact entries actually removed.
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

    // Internal (not private): per-connection `HazkeyServerState` calls these
    // for candidate annotation and deletion matching.
    func allLearningMemoryEntries() throws -> [LearningMemoryEntry] {
        try converter.allLearningMemoryEntries(limit: Self.learningEnumerationLimit).entries
    }

    /// [community] Surface keys of the persisted learning entries stored under
    /// `readings`, used to annotate converter candidates as "deletable".
    /// Readings must already be katakana-normalized: they are exact trie keys.
    func learningSurfaceKeys(forReadings readings: [String]) throws -> Set<LearningSurfaceKey> {
        Set(
            try converter.persistedLearningMemoryKeys(exactReadings: readings).map {
                LearningSurfaceKey(reading: $0.reading, word: $0.word)
            })
    }

    /// [community] Every stored learning entry matching a candidate's
    /// (reading, word) pair regardless of CID, as keys for
    /// `forgetLearningEntries`. Derived from the same point lookup as the
    /// annotation, so a candidate shown as deletable is always deletable.
    func matchingLearningEntryKeys(
        reading: String,
        word: String
    ) throws -> [(reading: String, word: String, lcid: UInt32, rcid: UInt32)] {
        let target = LearningSurfaceKey(reading: reading, word: word)
        return try converter.persistedLearningMemoryKeys(exactReadings: [target.reading])
            .filter { LearningSurfaceKey(reading: $0.reading, word: $0.word) == target }
            .map {
                (
                    reading: $0.reading, word: $0.word,
                    lcid: UInt32(clamping: $0.lcid),
                    rcid: UInt32(clamping: $0.rcid)
                )
            }
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
}

// MARK: - Per-connection composition session

/// One IME composition session bound to a single socket client.
///
/// `HazkeyServer` creates one `HazkeyServerState` per accepted connection and
/// destroys it on disconnect. The heavy converter, configuration, user
/// dictionary, and emoji provider live in the server-wide `shared` object;
/// this object owns only per-composition state (composing text, candidate
/// list, shift/sub-mode flags, Zenzai left context) plus one
/// `KanaKanjiConverter.ConversionSessionID` selecting its slice of the shared
/// converter's session-keyed state (lattice, completed data, Zenzai and
/// prediction caches). Every converter call touching composition state runs
/// inside `withConversionSession`, so simultaneous clients never observe each
/// other's uncommitted input. Learning memory is shared server-wide.
class HazkeyServerState {
    let shared: HazkeySharedResources
    let conversionSessionID: KanaKanjiConverter.ConversionSessionID

    var composingText: ComposingTextBox = ComposingTextBox()
    var currentCandidateList: [DisplayedCandidate]?
    /// [community] Mode (suggest vs conversion) of `currentCandidateList`.
    /// Deleting a candidate's learning data must rebuild the list in the same
    /// mode — rebuilding a suggest-mode list as a non-predict list would break
    /// live-conversion state. Remembered on every `makeCandidatesResult` call,
    /// i.e. kept in sync with every non-nil `currentCandidateList`.
    var currentCandidateListIsSuggest = false

    var isShiftPressedAlone = false
    var shiftPressedAt: ContinuousClock.Instant?
    var isSubInputMode = false
    /// Maximum hold duration for a Shift press-release to count as a tap.
    /// A longer hold is treated as a long press and must not toggle sub-input mode.
    private static let shiftTapMaxDuration: Duration = .milliseconds(500)
    var zenzaiLeftContext = ""

    private var isClosed = false

    // MARK: - Forwarding accessors (shared resources)

    // These keep every existing `state.xxx` call site (ProtocolHandler,
    // tests) compiling unchanged while the storage lives in `shared`.
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

    /// - Parameter emojiDictionaryURL: Injected dictionary URL for tests.
    ///   `nil` uses the production E17 asset.
    convenience init(emojiDictionaryURL: URL?) {
        self.init(shared: HazkeySharedResources(emojiDictionaryURL: emojiDictionaryURL))
    }

    init(shared: HazkeySharedResources) {
        self.shared = shared
        self.conversionSessionID = shared.converter.createSession()
        shared.registerConversionSession(conversionSessionID)
    }

    /// Releases this connection's converter session. Idempotent: safe to call
    /// twice (the disconnect path and a later fd-reuse close may overlap).
    func close() {
        guard !isClosed else { return }
        isClosed = true
        shared.unregisterConversionSession(conversionSessionID)
        converter.removeSession(conversionSessionID)
    }

    /// Runs `body` with this connection's conversion session active. The converter
    /// is shared server-wide; per-composition state (lattice, completed data,
    /// Zenzai cache, lastData) is keyed by session, so composition calls must
    /// select this connection's session first.
    private func withConversionSession<T>(_ body: () throws -> T) -> T? {
        do { return try converter.withSession(conversionSessionID, operation: body) }
        catch { NSLog("[hazkey] Conversion session unavailable: \(error)"); return nil }
    }

    /// Resets shared configuration, then this connection's composition state.
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

    // MARK: - Shared learning forwarders

    // Thin forwarders so `ProtocolHandler` and tests keep calling `state.*`.
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
        // The Zenzai mode is computed per request in `makeCandidatesResult`
        // from this connection's `zenzaiLeftContext`; nothing reads
        // `baseConvertRequestOptions.zenzaiMode` in between, so storing it
        // here would be dead.

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
        // New-composition boundary: drop this connection's converter session
        // so an identical input does not reuse the prior composition's
        // lattice and hide newly learned candidates. Incremental conversion
        // within a composition keeps reusing the session.
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
                // Shift was released while combined with another key (modifier or
                // character); never toggle the sub-input (direct) mode.
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
        // Bounds check first: Swift array subscript traps on an out-of-range
        // index, and a malformed client index must not crash the server.
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
            // Learning memory is shared server-wide, so a commit that produced no
            // learning update must NOT clear the dirty flag: doing so would drop
            // another connection's pending persistence.
            if learnsFromCandidate { learningDataNeedsCommit = true }
        case .fromUserDict:
            // User-dictionary entries always match the full reading, so we
            // simply clear the composing text. They do not feed the
            // converter's learning store.
            composingText = ComposingTextBox()
        case .fromDateProvider:
            // [community] Date-provider candidates match the full reading of a
            // relative-date trigger word (きょう/きのう/...) and produce a
            // computed date string. Behaves like `.fromUserDict` at commit:
            // clear composing text, do not feed the learning store.
            composingText = ComposingTextBox()
        case .fromKanaNumberProvider:
            // [community] Kana-number special-candidate entries match the full
            // reading of a kana numeral. Behaves like `.fromDateProvider` at
            // commit: clear composing text, do not feed the learning store.
            composingText = ComposingTextBox()
        case .fromEmoji(_, let composingCount):
            // [community] Emoji direct-conversion candidates consume only the
            // matched normalized-query prefix, retaining any trailing suffix.
            // Never touches the converter's completion/learning APIs, so the
            // shared dirty flag is left alone (another connection may have
            // pending learning to persist).
            composingText.value.prefixComplete(composingCount: composingCount)
        }
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
    }

    /// [community] Accept a prediction candidate as a fixed leading notation
    /// (upstream ad714fe / #357). Unlike completePrefix this does not commit:
    /// the candidate's remaining ruby is appended to the composing text and
    /// the accepted notation becomes the leading constraint of subsequent
    /// Zenzai conversions. No learning data is updated because nothing is
    /// committed yet.
    func acceptPrediction(candidateIndex: Int) -> Hazkey_ResponseEnvelope {
        // Bounds check first: Swift array subscript (and optional chaining on
        // it) traps on an out-of-range index instead of returning nil, and a
        // malformed client index must not crash the server.
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

        if (serverConfig.currentProfile.auxTextMode
            == Hazkey_Config_Profile.AuxTextMode.auxTextDisabled)
            || (serverConfig.currentProfile.auxTextMode
                == Hazkey_Config_Profile.AuxTextMode.auxTextShowWhenCursorNotAtEnd
                && hiragana.count == cursorPos)
        {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .success
                $0.textWithCursor = Hazkey_Commands_TextWithCursor.with {
                    $0.beforeCursosr = ""
                    $0.onCursor = ""
                    $0.afterCursor = ""
                }
            }
        }

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

    /// Candidates

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

    /// [community] Sets `has_learning_entry` on the converter candidates from a
    /// single batched point lookup against the persisted learning memory.
    ///
    /// - Important: Only valid after `converter.requestCandidates(...)`. The
    ///   converter applies the active profile's `memoryDirectoryURL` lazily
    ///   inside that call, so looking up earlier would read the previous
    ///   profile's directory right after a profile switch.
    /// - Note: A failed lookup leaves every candidate unannotated, which is the
    ///   same conservative degradation as before the point lookup existed.
    private func annotateLearningEntries(
        readings: [String],
        into clientCandidates: inout [Hazkey_Commands_CandidatesResult.Candidate]
    ) {
        guard !readings.isEmpty else { return }
        let learnedSurfaces: Set<LearningSurfaceKey>
        do {
            learnedSurfaces = try shared.learningSurfaceKeys(forReadings: Array(Set(readings)))
        } catch {
            shared.reportLearningLookupFailure(error)
            return
        }
        guard !learnedSurfaces.isEmpty else { return }
        for index in clientCandidates.indices where index < readings.count {
            clientCandidates[index].hasLearningEntry_p = learnedSurfaces.contains(
                LearningSurfaceKey(reading: readings[index], word: clientCandidates[index].text))
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
        // Surface texts already emitted into the response. The converter
        // deduplicates within predictionResults and within mainResults
        // separately, but the two arrays can share texts (a user dictionary
        // word also surfaces as a prediction of its own best node), so the
        // concatenated list must skip later duplicates.
        var appendedTexts: Set<String> = []

        // [community] Katakana-normalized reading of every converter candidate
        // emitted below, positionally aligned with `clientCandidates`. The
        // "deletable" annotation is resolved from these in one batched point
        // lookup once the converter has returned — see `annotateLearningEntries`.
        var annotationReadings: [String] = []

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
                katakanaNormalized(String(fullHiraganaPreedit.prefix(endIndex))))

            clientCandidates.append(clientCandidate)
            serverCandidates.append(.fromConverter(candidate))
        }

        var options = baseConvertRequestOptions
        let N_best = {
            if is_suggest
                && serverConfig.currentProfile.suggestionListMode
                    == Hazkey_Config_Profile.SuggestionListMode.suggestionListDisabled
            {
                // for auto conversion
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

        // Inject user dictionary into the engine so entries participate in
        // connection-cost ranking with their assigned part-of-speech (CID).
        // The injection itself is instance-level (shared by all connections),
        // so it runs outside any conversion session.
        if serverConfig.currentProfile.useUserDictionaryEffective {
            let reloaded = userDictionary.reloadIfNeeded()
            if reloaded || !shared.userDictInjected {
                converter.importDynamicUserDictionary(userDictionary.toDicdataElements())
                shared.userDictInjected = true
                NSLog("[hazkey] Injected \(userDictionary.count) user dictionary entries into engine")
            }
        } else if shared.userDictInjected {
            converter.importDynamicUserDictionary([])  // clear when toggled off
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
            // Defensive: sessions are removed only on connection close, and
            // the single-threaded server loop never converts for a closed
            // session. Return an empty list rather than trapping.
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

        // predictionResults is empty when prediction=disabled
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

            // find live text
            if candidatesResult.liveText.isEmpty && isExactMatch {
                candidatesResult.liveText = candidate.text
                // Duplicate of an already-appended entry (the same surface was
                // emitted as a learned prediction / earlier result): keep the
                // earlier entry and point the live text at it instead of
                // appending the same text twice.
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
                // Cross-source duplicate (learned prediction + user dictionary
                // collision): the kept earlier entry already represents this
                // text, so skip the redundant copy.
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

        // [community] Resolve the "deletable" annotation here: every converter
        // candidate has been emitted, and the injections below insert entries
        // at arbitrary positions, which would break the positional alignment
        // with `annotationReadings`.
        annotateLearningEntries(readings: annotationReadings, into: &clientCandidates)

        // === [community] Emoji 17.0 direct-candidate injection ===
        // Normal conversion only (`is_suggest == false`), gated by the
        // `extended_emoji` setting. Appended after the converter's main
        // candidates and before the date/number post-processors. Exact-string
        // deduped against `appendedTexts`; liveText/liveTextIndex untouched;
        // no learning annotation. Text is preserved byte-for-byte.
        if !is_suggest, serverConfig.currentProfile.extendedEmojiEffective,
            let emojiProvider
        {
            let emojiItems = emojiProvider.emojiCandidates(for: hiraganaPreedit)
            if !emojiItems.isEmpty {
                for item in emojiItems {
                    guard !appendedTexts.contains(item.text) else { continue }
                    appendedTexts.insert(item.text)
                    // Matched normalized-query length drives both the remaining
                    // preedit and the prefix completion of the same candidate.
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

        // === [community] Relative-date candidate injection (post-process) ===
        // Inject formatted date strings (yyyy年M月d日, yyyy-MM-dd, ...) when the
        // composing hiragana exactly matches a relative-date trigger word
        // (きょう, きのう, ...) AND the engine returned the kanji representation
        // (今日, 昨日, ...). Date candidates are inserted immediately after the
        // kanji representation in both serverCandidates (for index alignment
        // with completePrefix) and clientCandidates (for wire serialization).
        //
        // Fallback (synthesizeKanjiWhenMissing): when the engine does not produce
        // the kanji anchor (e.g. さきおとつい → 一昨昨日 is absent), and the trigger
        // explicitly opts in, a synthetic anchor + date strings are appended at the
        // end of both lists. No insertion is done; liveTextIndex is unchanged.
        if serverConfig.currentProfile.useRelativeDateEffective {
            if let trigger = RelativeDateProvider.detectTrigger(
                composingHiragana: hiraganaPreedit)
            {
                // Find the index of the kanji representation in serverCandidates.
                // Only inject when the kanji form exists (matches the user's
                // "漢字表現が有る時だけ挿入" preference).
                let kanjiIndex = serverCandidates.firstIndex(where: { dc in
                    if case .fromConverter(let c) = dc { return c.text == trigger.kanji }
                    return false
                })

                if let kanjiIndex = kanjiIndex {
                    // Normal path: converter anchor found — insert date strings
                    // immediately after the kanji representation.
                    let dateStrings = RelativeDateProvider.generateDateStrings(for: trigger)
                    var insertedCount = 0
                    for dateStr in dateStrings {
                        // Respect N_best limit for suggest mode.
                        guard canAppend(
                            isSuggest: is_suggest,
                            currentCount: serverCandidates.count,
                            limit: N_best
                        ) else { break }

                        var clientCandidate = Hazkey_Commands_CandidatesResult.Candidate()
                        clientCandidate.text = dateStr
                        // Date candidates consume the full reading, so subHiragana
                        // is the remaining preedit (empty for exact-match trigger).
                        clientCandidate.subHiragana = String(
                            fullHiraganaPreedit.dropFirst(hiraganaPreeditLen))

                        let insertAt = kanjiIndex + 1 + insertedCount
                        serverCandidates.insert(.fromDateProvider(word: dateStr), at: insertAt)
                        clientCandidates.insert(clientCandidate, at: insertAt)
                        insertedCount += 1
                    }
                } else if trigger.synthesizeKanjiWhenMissing {
                    // Fallback path: engine did not return the kanji anchor and
                    // this trigger opts in for synthesis.
                    // Append the synthetic anchor then the date strings at the tail.
                    // Do NOT mutate liveTextIndex; do NOT insert before existing entries.
                    //
                    // Limit is checked against clientCandidates.count (visible slots),
                    // not serverCandidates.count: in suggest mode the live candidate may
                    // exist only in serverCandidates (hidden), so using serverCandidates
                    // would incorrectly consume a visible slot.
                    if canAppend(
                        isSuggest: is_suggest,
                        currentCount: clientCandidates.count,
                        limit: N_best
                    ) {
                        // Synthetic kanji anchor (treated as fromDateProvider at commit).
                        var anchorClientCandidate = Hazkey_Commands_CandidatesResult.Candidate()
                        anchorClientCandidate.text = trigger.kanji
                        anchorClientCandidate.subHiragana = String(
                            fullHiraganaPreedit.dropFirst(hiraganaPreeditLen))
                        serverCandidates.append(.fromDateProvider(word: trigger.kanji))
                        clientCandidates.append(anchorClientCandidate)

                        // Date strings following the synthetic anchor.
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

        // === [community] Kana-number special-candidate injection (post-process) ===
        // The converter identifies Japanese-number candidates with `CIDData.数`.
        // Its ASCII decimal candidate is the authoritative resolved value; this
        // server layer only maps that value to the approved glyph families.
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

    // TODO: return error message
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

    /// [community] Delete the learning-memory entries backing the focused
    /// candidate and rebuild the candidate list in the remembered mode.
    ///
    /// Matching is by (reading, word) surface pair across CID variants — the
    /// same rule the "deletable" annotation uses, so a candidate shown as
    /// deletable is always deletable. `forgetLearningMemory` persists to disk
    /// immediately and resets the converter's memory cache, so the rebuilt
    /// list reflects the deletion.
    func deleteCandidateLearningData(candidateIndex: Int) -> Hazkey_ResponseEnvelope {
        // Bounds check first: Swift array subscript traps on an out-of-range
        // index, and a malformed client index must not crash the server.
        guard let list = currentCandidateList, list.indices.contains(candidateIndex) else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Candidate index \(candidateIndex) not found."
            }
        }
        // Only converter candidates can carry learning entries. Legacy
        // user-dictionary / date / kana-number / emoji injections have no
        // learning backing: report "nothing deleted" instead of an error.
        guard case .fromConverter(let candidate) = list[candidateIndex] else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .success
                $0.deleteCandidateLearningDataResult = Hazkey_Commands_DeleteCandidateLearningDataResult.with {
                    $0.deletedCount = 0
                }
            }
        }

        // Reading of the candidate, with the same formula as appendCandidate.
        let fullHiraganaPreedit = composingText.value.toHiragana()
        let requestHiraganaPreeditLen = candidateRequestText(
            is_suggest: currentCandidateListIsSuggest
        ).toHiragana().count
        let reading = String(
            fullHiraganaPreedit.prefix(min(candidate.rubyCount, requestHiraganaPreeditLen)))

        // Collect every (reading, word) match across CID variants. An empty
        // match (not learned) is a normal "nothing deleted" result, not an
        // error.
        let matchingKeys: [(reading: String, word: String, lcid: UInt32, rcid: UInt32)]
        do {
            matchingKeys = try shared.matchingLearningEntryKeys(reading: reading, word: candidate.text)
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

        // Rebuild the candidate list in the same mode as before the deletion.
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

extension Hazkey_Config_Profile {
    /// Effective value of the per-profile user dictionary setting.
    /// Legacy or missing config defaults to true to preserve existing behavior.
    var useUserDictionaryEffective: Bool {
        hasUseUserDictionary ? useUserDictionary : true
    }

    /// [community] Effective value of the relative-date candidate setting.
    /// Legacy or missing config defaults to true to preserve existing behavior.
    var useRelativeDateEffective: Bool {
        let mode = specialConversionMode
        return mode.hasRelativeDate ? mode.relativeDate : true
    }
}
