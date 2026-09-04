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

class HazkeyServerState {
    let serverConfig: HazkeyServerConfig
    let converter: KanaKanjiConverter
    let userDictionary: UserDictionary = UserDictionary()
    var currentCandidateList: [DisplayedCandidate]?
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
        guard let entry = currentCandidateList?[candidateIndex] else {
            return Hazkey_ResponseEnvelope.with {
                $0.status = .failed
                $0.errorMessage = "Candidate index \(candidateIndex) not found."
            }
        }
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
