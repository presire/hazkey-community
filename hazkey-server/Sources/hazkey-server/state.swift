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

class HazkeyServerState {
    let serverConfig: HazkeyServerConfig
    let converter: KanaKanjiConverter
    let userDictionary: UserDictionary = UserDictionary()
    var currentCandidateList: [DisplayedCandidate]?
    /// [community] Mode (suggest vs conversion) of `currentCandidateList`.
    /// Deleting a candidate's learning data must rebuild the list in the same
    /// mode — rebuilding a suggest-mode list as a non-predict list would break
    /// live-conversion state. Remembered on every `makeCandidatesResult` call,
    /// i.e. kept in sync with every non-nil `currentCandidateList`.
    var currentCandidateListIsSuggest = false
    var composingText: ComposingTextBox = ComposingTextBox()

    var isShiftPressedAlone = false
    var isSubInputMode = false
    var learningDataNeedsCommit = false
    var zenzaiLeftContext = ""
    private var userDictInjected = false

    var keymap: Keymap
    var currentTableName: String
    var baseConvertRequestOptions: ConvertRequestOptions

    init() {
        self.serverConfig = HazkeyServerConfig()

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

    func setContext(surroundingText: String, anchorIndex: Int) -> Hazkey_ResponseEnvelope {
        let clamped = max(0, min(anchorIndex, surroundingText.count))
        if clamped != anchorIndex { NSLog("[hazkey] setContext: anchor clamped \(anchorIndex)->\(clamped) for length \(surroundingText.count)") }
        zenzaiLeftContext = String(surroundingText.prefix(clamped))
        baseConvertRequestOptions.zenzaiMode = serverConfig.genZenzaiMode(
            leftContext: zenzaiLeftContext)

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
        // New-composition boundary: drop the converter session so an identical
        // input does not reuse the prior composition's lattice and hide newly
        // learned candidates. Incremental conversion within a composition keeps
        // reusing the session.
        converter.stopComposition()
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
            case .release:
                if isShiftPressedAlone {
                    isSubInputMode.toggle()
                    isShiftPressedAlone = false
                }
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
        if learningDataNeedsCommit {
            converter.commitUpdateLearningData()
            learningDataNeedsCommit = false
        }
        return Hazkey_ResponseEnvelope.with {
            $0.status = .success
        }
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
            converter.setCompletedData(completedCandidate)
            if !completedCandidate.data.contains(where: { $0.metadata.contains(.isFromUserDictionary) }) {
                converter.updateLearningData(completedCandidate)
                learningDataNeedsCommit = true
            } else {
                learningDataNeedsCommit = false
            }
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
        guard converter.acceptPredictionCandidate(candidate, composingText: &composing) else {
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

        // [community] Learning-entry surface keys for the "deletable"
        // annotation. One in-memory scan per request; a failed enumeration
        // leaves candidates unannotated (conservative, no functional harm).
        let learningEntryKeys: Set<LearningSurfaceKey>
        do {
            learningEntryKeys = try learningSurfaceKeys()
        } catch {
            NSLog("Failed to enumerate learning memory for annotations: \(error)")
            learningEntryKeys = []
        }

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
            // [community] "deletable" annotation: true when the learning
            // memory holds an entry matching the candidate's (reading, word)
            // pair. Same matching rule as the delete handler.
            clientCandidate.hasLearningEntry_p = learningEntryKeys.contains(
                LearningSurfaceKey(
                    reading: String(fullHiraganaPreedit.prefix(endIndex)),
                    word: candidate.text))

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
        if serverConfig.currentProfile.useUserDictionaryEffective {
            let reloaded = userDictionary.reloadIfNeeded()
            if reloaded || !userDictInjected {
                converter.importDynamicUserDictionary(userDictionary.toDicdataElements())
                userDictInjected = true
                NSLog("[hazkey] Injected \(userDictionary.count) user dictionary entries into engine")
            }
        } else if userDictInjected {
            converter.importDynamicUserDictionary([])  // clear when toggled off
            userDictInjected = false
        }
        userDictionaryFinishedAt = perfProbe?.now()

        var candidatesResult = Hazkey_Commands_CandidatesResult()
        if zenzai == "on" {
            _ = ZenzInferencePerf.shared.consumeElapsedNanoseconds()
        }
        let converted = converter.requestCandidates(copiedComposingText, options: options)
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
        // user-dictionary / date / kana-number injections have no learning
        // backing: report "nothing deleted" instead of an error.
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
            matchingKeys = try matchingLearningEntryKeys(reading: reading, word: candidate.text)
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

    func clearProfileLearningData() -> Hazkey_ResponseEnvelope {
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
        } else {
            converter.resetMemory()
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
        guard offset <= 65_536 else {
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

        let existingKeys = Set(try allLearningMemoryEntries().map {
            LearningHistoryKey(
                reading: $0.data.ruby,
                word: $0.data.word,
                lcid: UInt32(clamping: $0.data.lcid),
                rcid: UInt32(clamping: $0.data.rcid))
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
        // converter reuses its session lattice (and the Zenzai draft/memoized
        // constraint) when the composing text is unchanged, so a rebuilt
        // candidate list would otherwise resurrect the deleted entries from
        // the stale caches. Resetting the active session drops only cached
        // conversion state — the composing text lives in HazkeyServerState
        // and the learning memory on disk, both unaffected.
        converter.stopComposition()
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

    private func allLearningMemoryEntries() throws -> [LearningMemoryEntry] {
        var entries: [LearningMemoryEntry] = []
        var offset = 0
        repeat {
            let page = try converter.learningMemoryEntries(offset: offset, limit: 65_536)
            entries.append(contentsOf: page.entries)
            guard let nextOffset = page.nextOffset else {
                return entries
            }
            offset = nextOffset
        } while offset < 65_536
        return entries
    }

    /// [community] Surface keys of every stored learning-memory entry, used to
    /// annotate converter candidates as "deletable".
    private func learningSurfaceKeys() throws -> Set<LearningSurfaceKey> {
        Set(
            try allLearningMemoryEntries().map { entry in
                LearningSurfaceKey(reading: entry.data.ruby, word: entry.data.word)
            })
    }

    /// [community] Every stored learning entry matching a candidate's
    /// (reading, word) pair regardless of CID, as keys for
    /// `forgetLearningEntries`. Same surface normalization as
    /// `learningSurfaceKeys`, so annotation and deletion agree.
    private func matchingLearningEntryKeys(
        reading: String,
        word: String
    ) throws -> [(reading: String, word: String, lcid: UInt32, rcid: UInt32)] {
        let target = LearningSurfaceKey(reading: reading, word: word)
        return try allLearningMemoryEntries().compactMap { entry in
            guard
                LearningSurfaceKey(reading: entry.data.ruby, word: entry.data.word) == target
            else { return nil }
            return (
                reading: entry.data.ruby, word: entry.data.word,
                lcid: UInt32(clamping: entry.data.lcid),
                rcid: UInt32(clamping: entry.data.rcid)
            )
        }
    }

    func reinitializeConfiguration() {
        NSLog("Reinitializing state configuration...")

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

        self.composingText = ComposingTextBox()
        self.currentCandidateList = nil
        self.isSubInputMode = false
        self.isShiftPressedAlone = false
        self.zenzaiLeftContext = ""

        NSLog("State configuration reinitialized successfully")
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
