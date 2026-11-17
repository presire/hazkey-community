import KanaKanjiConverterModule

/// 通常変換の最終候補列で、記号候補を所定の位置へ繰り上げ、補助記号辞書の記号を補う
///
/// HazkeyServerState.makeCandidatesResult(is_suggest:appliesTypoTimeBudget:)が、全ての注入候補を加えた後に1回だけ呼ぶ純関数
///
/// 保護範囲 (先頭protectedCount件・ライブ変換の候補・先頭の誤字訂正候補群) より前の候補は動かさず、その直後へ記号を移す
///
/// - Note: 動かすのは全読みの.fromConverter候補と新規の.fromSymbol候補だけで、他の注入候補は動かさない
///
///   表記はUnicodeスカラ列の完全一致で比べ、正規化しない (℃ と °C、≠ と =+U+0338を区別する)
enum SymbolCandidatePromotion {
    /// 常に動かさない先頭の候補数
    static let protectedCount = 3

    /// 繰り上げの結果
    struct Result {
        /// 並べ替えたクライアント向けの候補列
        let clientCandidates: [Hazkey_Commands_CandidatesResult.Candidate]
        /// clientCandidatesと同じ順に並べ替えたサーバ側の候補列
        let serverCandidates: [DisplayedCandidate]
        /// 並べ替え後のライブ変換の候補の位置 (-1は該当なし)
        let liveTextIndex: Int32
    }

    /// 繰り上げる記号 (移動と新規の合計) の上限
    ///
    /// - Parameter tier: 読みのtier
    /// - Returns: Aティアは6、Bティアは3
    static func limit(for tier: SymbolTier) -> Int {
        switch tier {
        case .a: 6
        case .b: 3
        }
    }

    /// 記号候補を繰り上げ、補助記号辞書の記号を補う
    ///
    /// 繰り上げる記号は、補助記号辞書の行順 (dictionarySymbols) の後に、辞書に無いコンバータ由来の記号を元の順で並べ、上限 (limit(for:)) までとする
    ///
    /// 補助記号辞書の記号ごとに、保護範囲や他の注入候補と同じ表記なら飛ばし、同じ表記の全読み候補があれば保護範囲外の最初の1件を移し、部分読み候補だけがあれば動かさず追加もせずに飛ばし、どれも無ければ.fromSymbol候補を作る
    ///
    /// 辞書に無いコンバータ由来の記号も、保護範囲や動かさない注入候補と同じ表記なら移さない
    ///
    /// Bティアでは、挿入位置から連続する普通の語の候補 (isProtectedOrdinaryWord) をさらに飛ばす。ただし挿入位置がページ内の場合は、1記号分の枠を先頭ページに残すよう、飛ばす件数をpageSize - 1 - 挿入位置までとする
    ///
    /// 上限を超えた補助記号辞書の記号は、繰り上げ後の候補数がpageSize以上の場合に限り、既存の表記と重複しないものだけを、先頭ページより後ろかつ最初の絵文字候補の前 (絵文字が無ければ末尾) へ追加する
    ///
    /// - Parameters:
    ///   - clientCandidates: 注入を終えたクライアント向けの候補列 (学習注釈を付け終えたもの)
    ///   - serverCandidates: clientCandidatesと同じ位置で対応するサーバ側の候補列
    ///   - liveTextIndex: ライブ変換の候補の位置 (-1は該当なし)
    ///   - readingLength: カーソルまでの読みの文字数 (全読みの判定と.fromSymbolの消費量に使う)
    ///   - remainingReading: カーソルより右の残りの読み (新規候補のsubHiraganaにする)
    ///   - pageSize: 1ページの候補数 (設定の実効値)
    ///   - tier: 読みのtier (補助記号辞書に無い読みはBティア)
    ///   - dictionarySymbols: 補助記号辞書の、その読みの記号 (優先順。辞書に無い読みは空)
    /// - Returns: 並べ替えた2つの候補列と新しいliveTextIndex。2つの候補列の長さが異なる場合は入力をそのまま返す
    /// - Note: liveTextIndexの候補は挿入位置より前にあり動かないため、liveTextIndexは入力と同じ値になる
    static func apply(
        clientCandidates: [Hazkey_Commands_CandidatesResult.Candidate],
        serverCandidates: [DisplayedCandidate],
        liveTextIndex: Int32,
        readingLength: Int,
        remainingReading: String,
        pageSize: Int,
        tier: SymbolTier,
        dictionarySymbols: [String]
    ) -> Result {
        guard clientCandidates.count == serverCandidates.count else {
            return Result(
                clientCandidates: clientCandidates, serverCandidates: serverCandidates, liveTextIndex: liveTextIndex)
        }
        let count = serverCandidates.count

        func fullReadingCandidate(at index: Int) -> Candidate? {
            guard case .fromConverter(let candidate) = serverCandidates[index], candidate.rubyCount == readingLength
            else { return nil }
            return candidate
        }
        func isConverterCandidate(at index: Int) -> Bool {
            if case .fromConverter = serverCandidates[index] { return true }
            return false
        }

        // 挿入位置は、先頭protectedCount件・ライブ変換の候補・先頭の誤字訂正候補群の直後のうち最も後ろ
        let typoGroupEnd: Int = {
            guard let first = serverCandidates.firstIndex(where: isTypoCorrection) else { return 0 }
            var end = first
            while end < count && isTypoCorrection(serverCandidates[end]) { end += 1 }
            return end
        }()
        let protectedEnd = min(
            count, max(protectedCount, liveTextIndex < 0 ? 0 : Int(liveTextIndex) + 1, typoGroupEnd))

        // 保護範囲の候補と、動かさない注入候補 (.fromConverter以外) の表記は、繰り上げも追加もしない
        var excludedKeys = Set<[Unicode.Scalar]>()
        for index in 0..<count where index < protectedEnd || !isConverterCandidate(at: index) {
            excludedKeys.insert(scalarKey(clientCandidates[index].text))
        }

        enum Choice {
            case move(Int)
            case insert(String)
        }
        let limit = limit(for: tier)
        var choices: [Choice] = []
        var chosenKeys = Set<[Unicode.Scalar]>()
        var movedIndices = Set<Int>()
        let dictionaryKeys = Set(dictionarySymbols.map(scalarKey))
        for symbol in dictionarySymbols where choices.count < limit {
            let key = scalarKey(symbol)
            guard !excludedKeys.contains(key), !chosenKeys.contains(key) else { continue }
            if let index = (protectedEnd..<count).first(where: { index in
                fullReadingCandidate(at: index).map { scalarKey($0.text) == key } ?? false
            }) {
                choices.append(.move(index))
                movedIndices.insert(index)
            } else if (protectedEnd..<count).contains(where: { scalarKey(clientCandidates[$0].text) == key }) {
                // 同じ表記の部分読み候補だけがある場合は、重複を避けて動かさず追加もしない
                continue
            } else {
                choices.append(.insert(symbol))
            }
            chosenKeys.insert(key)
        }
        // 補助記号辞書に無いコンバータ由来の記号を、元の順で残りの枠へ入れる
        for index in protectedEnd..<count where choices.count < limit {
            guard let candidate = fullReadingCandidate(at: index),
                SymbolCandidateClassifier.isSymbol(candidate.text)
            else { continue }
            let key = scalarKey(candidate.text)
            guard !excludedKeys.contains(key), !dictionaryKeys.contains(key), !chosenKeys.contains(key),
                !movedIndices.contains(index)
            else { continue }
            choices.append(.move(index))
            movedIndices.insert(index)
            chosenKeys.insert(key)
        }

        // Bティアは、挿入位置から連続する普通の語の候補をさらに飛ばす
        var insertionIndex = protectedEnd
        if tier == .b && !choices.isEmpty {
            var skipCount = 0
            while protectedEnd + skipCount < count
                && isProtectedOrdinaryWord(
                    serverCandidates[protectedEnd + skipCount],
                    client: clientCandidates[protectedEnd + skipCount],
                    readingLength: readingLength)
            {
                skipCount += 1
            }
            if protectedEnd < pageSize {
                skipCount = min(skipCount, max(0, pageSize - 1 - protectedEnd))
            }
            insertionIndex = protectedEnd + skipCount
        }

        var newClient = Array(clientCandidates[..<insertionIndex])
        var newServer = Array(serverCandidates[..<insertionIndex])
        for choice in choices {
            switch choice {
            case .move(let index):
                newClient.append(clientCandidates[index])
                newServer.append(serverCandidates[index])
            case .insert(let symbol):
                newClient.append(symbolClientCandidate(symbol, remainingReading: remainingReading))
                newServer.append(.fromSymbol(word: symbol, composingCount: .surfaceCount(readingLength)))
            }
        }
        for index in insertionIndex..<count where !movedIndices.contains(index) {
            newClient.append(clientCandidates[index])
            newServer.append(serverCandidates[index])
        }

        // 上限を超えた補助記号辞書の記号は、先頭ページより後ろに限って追加する
        if newServer.count >= pageSize {
            var existingKeys = Set(newClient.map { scalarKey($0.text) })
            let leftovers = dictionarySymbols.filter { existingKeys.insert(scalarKey($0)).inserted }
            if !leftovers.isEmpty {
                let position: Int
                if let firstEmoji = newServer.firstIndex(where: isEmoji) {
                    position = min(max(pageSize, insertionIndex, firstEmoji), newServer.count)
                } else {
                    position = newServer.count
                }
                newClient.insert(
                    contentsOf: leftovers.map { symbolClientCandidate($0, remainingReading: remainingReading) },
                    at: position)
                newServer.insert(
                    contentsOf: leftovers.map {
                        DisplayedCandidate.fromSymbol(word: $0, composingCount: .surfaceCount(readingLength))
                    },
                    at: position)
            }
        }

        return Result(clientCandidates: newClient, serverCandidates: newServer, liveTextIndex: liveTextIndex)
    }

    /// Bティアで、記号より前に残す普通の語の候補かどうかを返す
    ///
    /// 全読みの.fromConverter候補で、1ノード (Candidate.data.count == 1) で、表記がかなだけでなく、記号でなく、学習の注釈が付かない候補を対象とする
    ///
    /// - Parameters:
    ///   - candidate: サーバ側の候補
    ///   - client: 対応するクライアント向けの候補 (学習の注釈の確認に使う)
    ///   - readingLength: カーソルまでの読みの文字数
    /// - Returns: 普通の語として保護する場合はtrue
    /// - Note: data.count == 1が示すのは辞書の要素が1件ということだけで、意味的な普通の語の判定ではない (かな・記号・英字の1ノード候補もある)
    ///
    ///   英字だけの表記は保守的に保護し、飽ける (あける、2ノード) のような複数ノードの語は保護しない
    static func isProtectedOrdinaryWord(
        _ candidate: DisplayedCandidate,
        client: Hazkey_Commands_CandidatesResult.Candidate,
        readingLength: Int
    ) -> Bool {
        guard case .fromConverter(let converted) = candidate else { return false }
        return converted.rubyCount == readingLength
            && converted.data.count == 1
            && !SymbolCandidateClassifier.isKanaOnly(converted.text)
            && !SymbolCandidateClassifier.isSymbol(converted.text)
            && !client.hasLearningEntry_p
    }

    private static func isTypoCorrection(_ candidate: DisplayedCandidate) -> Bool {
        if case .fromTypoCorrection = candidate { return true }
        return false
    }

    private static func isEmoji(_ candidate: DisplayedCandidate) -> Bool {
        if case .fromEmoji = candidate { return true }
        return false
    }

    private static func scalarKey(_ text: String) -> [Unicode.Scalar] {
        Array(text.unicodeScalars)
    }

    private static func symbolClientCandidate(
        _ symbol: String, remainingReading: String
    ) -> Hazkey_Commands_CandidatesResult.Candidate {
        var candidate = Hazkey_Commands_CandidatesResult.Candidate()
        candidate.text = symbol
        candidate.subHiragana = remainingReading
        return candidate
    }
}
