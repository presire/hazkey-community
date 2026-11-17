import KanaKanjiConverterModule
import XCTest

@testable import hazkey_server

/// 記号候補の繰り上げ (SymbolCandidatePromotion.apply(...)) の純関数テスト
///
/// 実測した候補列の形 (した・かど・うえ・あける・やじるし) を、先頭3件の保護だけでは通らない位置に置いて検証する
final class SymbolCandidatePromotionTests: XCTestCase {
    /// 既定の読みの長さ (候補の全読みの判定に使う)
    private static let readingLength = 3
    /// 既定のカーソル後の残りの読み
    private static let remaining = "を"

    /// 候補列の1要素
    private struct Entry {
        let client: Hazkey_Commands_CandidatesResult.Candidate
        let server: DisplayedCandidate
    }

    /// コンバータ由来の候補を作る
    ///
    /// - Parameters:
    ///   - text: 表記
    ///   - nodes: 辞書の要素数 (Candidate.data.count)
    ///   - rubyCount: 消費する読みの長さ (既定は全読み)
    ///   - learned: 学習の注釈を付けるかどうか
    private func converter(
        _ text: String, nodes: Int = 1, rubyCount: Int = readingLength, learned: Bool = false
    ) -> Entry {
        var counts = Array(repeating: rubyCount / nodes, count: nodes)
        counts[nodes - 1] += rubyCount - (rubyCount / nodes) * nodes
        let data = counts.map {
            DicdataElement(
                word: text, ruby: String(repeating: "ア", count: $0), cid: CIDData.一般名詞.cid,
                mid: MIDData.一般.mid, value: 0)
        }
        var client = Hazkey_Commands_CandidatesResult.Candidate()
        client.text = text
        client.hasLearningEntry_p = learned
        return Entry(
            client: client,
            server: .fromConverter(
                Candidate(
                    text: text, value: 0, composingCount: .surfaceCount(rubyCount), lastMid: MIDData.一般.mid,
                    data: data)))
    }

    /// 誤字訂正の候補を作る
    private func typo(_ text: String) -> Entry {
        var entry = converter(text)
        guard case .fromConverter(let candidate) = entry.server else { return entry }
        var client = entry.client
        client.isTypoCorrection = true
        entry = Entry(
            client: client,
            server: .fromTypoCorrection(candidate: candidate, correctedReading: "アアア", originalPrefixCount: 3))
        return entry
    }

    /// 絵文字の注入候補を作る
    private func emoji(_ text: String) -> Entry {
        var client = Hazkey_Commands_CandidatesResult.Candidate()
        client.text = text
        return Entry(client: client, server: .fromEmoji(word: text, composingCount: .surfaceCount(3)))
    }

    /// 相対日付の注入候補を作る
    private func date(_ text: String) -> Entry {
        var client = Hazkey_Commands_CandidatesResult.Candidate()
        client.text = text
        return Entry(client: client, server: .fromDateProvider(word: text, composingCount: .surfaceCount(3)))
    }

    /// 繰り上げを適用する
    private func promote(
        _ entries: [Entry], live: Int32 = -1, pageSize: Int = 9, tier: SymbolTier, dictionary: [String] = []
    ) -> SymbolCandidatePromotion.Result {
        let result = SymbolCandidatePromotion.apply(
            clientCandidates: entries.map(\.client),
            serverCandidates: entries.map(\.server),
            liveTextIndex: live,
            readingLength: Self.readingLength,
            remainingReading: Self.remaining,
            pageSize: pageSize,
            tier: tier,
            dictionarySymbols: dictionary)
        // クライアント向けの候補とサーバ側の候補は常に同じ位置で対応する
        XCTAssertEqual(result.clientCandidates.map(\.text), result.serverCandidates.map(Self.text))
        return result
    }

    private static func text(_ candidate: DisplayedCandidate) -> String {
        switch candidate {
        case .fromConverter(let candidate): candidate.text
        case .fromTypoCorrection(let candidate, _, _): candidate.text
        case .fromUserDict(let word): word
        case .fromDateProvider(let word, _), .fromKanaNumberProvider(let word, _), .fromEmoji(let word, _),
            .fromPostalCode(let word, _), .fromSymbol(let word, _):
            word
        }
    }

    private static func isSymbolEntry(_ candidate: DisplayedCandidate) -> Bool {
        if case .fromSymbol = candidate { return true }
        return false
    }

    private func words(_ texts: [String]) -> [Entry] { texts.map { converter($0) } }

    // MARK: 件数と保護範囲

    /// Aティアは最大6件、Bティアは最大3件を、先頭3件の直後へ辞書の行順で入れる
    func testTierLimitsAndDictionaryOrder() {
        let dictionary = ["→", "←", "↑", "↓", "⇒", "⇔", "↔", "↕"]
        let base = words(["矢印", "や印", "ヤジルシ", "野次る"])
        let tierA = promote(base, tier: .a, dictionary: dictionary)
        XCTAssertEqual(
            tierA.clientCandidates.map(\.text).prefix(10),
            ["矢印", "や印", "ヤジルシ", "→", "←", "↑", "↓", "⇒", "⇔", "野次る"])
        let tierB = promote(base, tier: .b, dictionary: dictionary)
        // Bティアは、挿入位置の普通の語 (野次る、1ノード) をさらに飛ばす
        XCTAssertEqual(tierB.clientCandidates.map(\.text), ["矢印", "や印", "ヤジルシ", "野次る", "→", "←", "↑"])
    }

    /// ライブ変換の候補の直後を挿入位置とし、それより前は動かさず、liveTextIndexは同じ候補を指し続ける
    func testLiveCandidateIsProtected() {
        let entries = words(["a", "b", "c", "d", "e", "live", "f", "↓"])
        let result = promote(entries, live: 5, tier: .a, dictionary: ["→"])
        XCTAssertEqual(result.liveTextIndex, 5)
        XCTAssertEqual(result.clientCandidates.map(\.text), ["a", "b", "c", "d", "e", "live", "→", "↓", "f"])
    }

    /// liveTextIndexが-1の場合は-1のまま、先頭3件の直後へ入れる
    func testNoLiveCandidate() {
        let result = promote(words(["a", "b", "c", "d"]), tier: .a, dictionary: ["→"])
        XCTAssertEqual(result.liveTextIndex, -1)
        XCTAssertEqual(result.clientCandidates.map(\.text), ["a", "b", "c", "→", "d"])
    }

    /// 候補が3件未満の場合は、既存の候補を動かさず末尾へ足す
    func testFewerThanThreeCandidates() {
        let result = promote(words(["a", "b"]), live: 0, tier: .b, dictionary: ["↓"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["a", "b", "↓"])
        XCTAssertEqual(result.liveTextIndex, 0)
    }

    /// 2つの候補列の長さが異なる場合は、何も変えない
    func testMismatchedListsAreUnchanged() {
        let entries = words(["a", "b", "c", "d"])
        let result = SymbolCandidatePromotion.apply(
            clientCandidates: entries.map(\.client), serverCandidates: Array(entries.map(\.server).dropLast()),
            liveTextIndex: -1, readingLength: 3, remainingReading: "", pageSize: 9, tier: .a, dictionarySymbols: ["→"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["a", "b", "c", "d"])
    }

    // MARK: 誤字訂正の候補群

    /// 先頭の誤字訂正候補群 (3件) の後ろへ入れ、liveTextIndexは同じ候補を指し続ける
    func testTypoCorrectionGroupIsProtected() {
        let entries = [converter("下")] + [typo("訂1"), typo("訂2"), typo("訂3")] + [converter("子た", nodes: 2)]
        let result = promote(entries, live: 0, tier: .b, dictionary: ["↓"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["下", "訂1", "訂2", "訂3", "↓", "子た"])
        XCTAssertEqual(result.liveTextIndex, 0)
        XCTAssertEqual(result.clientCandidates[Int(result.liveTextIndex)].text, "下")
    }

    /// 誤字訂正の候補群が無い場合は、先頭3件の直後へ戻る
    func testWithoutTypoGroupFallsBackToThree() {
        let result = promote(words(["下", "訂1", "訂2", "訂3", "舌"]), live: 0, tier: .a, dictionary: ["↓"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["下", "訂1", "訂2", "↓", "訂3", "舌"])
    }

    /// 先頭ページの1記号分の余地より誤字訂正の候補群を優先し、訂正候補を先頭ページの外へ押し出さない
    func testTypoGroupHasPriorityOverFirstPageRoom() {
        let entries = [converter("下")] + [typo("訂1"), typo("訂2"), typo("訂3")] + words(["上位", "下位", "舌"])
        let result = promote(entries, live: 0, pageSize: 4, tier: .b, dictionary: ["↓"])
        XCTAssertEqual(result.clientCandidates.map(\.text).prefix(4), ["下", "訂1", "訂2", "訂3"])
        // 挿入位置4はページの外なので、連続する普通の語を全て飛ばす
        XCTAssertEqual(result.clientCandidates.map(\.text).suffix(4), ["上位", "下位", "舌", "↓"])
        // 挿入位置4がページ内 (ページサイズ5) なら、普通の語を飛ばさずページ内の最後の枠へ入れる
        let roomy = promote(entries, live: 0, pageSize: 5, tier: .b, dictionary: ["↓"])
        XCTAssertEqual(roomy.clientCandidates.map(\.text).prefix(5), ["下", "訂1", "訂2", "訂3", "↓"])
    }

    // MARK: Bティアの普通の語の保護

    /// 保護するのは、全読み・1ノード・かなのみでない・記号でない・学習注釈なしの.fromConverter候補だけ (英字のみを含む)
    func testProtectedOrdinaryWordTruthTable() {
        let cases: [(Entry, Bool, String)] = [
            (converter("下"), true, "漢字1ノード"),
            (converter("ue"), true, "英字1ノード"),
            (converter("シタ"), false, "かな1ノード"),
            (converter("○"), false, "記号1ノード"),
            (converter("下", learned: true), false, "学習注釈あり"),
            (converter("飽ける", nodes: 2), false, "2ノード"),
            (converter("下", rubyCount: 2), false, "部分読み"),
            (typo("下"), false, "誤字訂正"),
            (emoji("👇"), false, "注入候補"),
        ]
        for (entry, expected, label) in cases {
            XCTAssertEqual(
                SymbolCandidatePromotion.isProtectedOrdinaryWord(
                    entry.server, client: entry.client, readingLength: Self.readingLength),
                expected, label)
        }
    }

    /// した: index 3のかな1ノード (シタ) は保護せず、その位置へ入れる
    func testKanaSingleNodeIsNotProtected() {
        let entries = words(["下", "舌", "した", "シタ"]) + [converter("知た", nodes: 2), converter("👇"), converter("↓")]
        let result = promote(entries, live: 0, tier: .b, dictionary: ["↓"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["下", "舌", "した", "↓", "シタ", "知た", "👇"])
        guard case .fromConverter = result.serverCandidates[3] else {
            return XCTFail("全読みの既存候補を移す")
        }
    }

    /// かど: index 3のかな表記 (かど) は保護しない
    func testKanaReadingCandidateIsNotProtected() {
        let result = promote(words(["角", "門", "過度", "かど"]), tier: .b, dictionary: ["□"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["角", "門", "過度", "□", "かど"])
    }

    /// 普通の語の直後の記号1ノード (○) は保護せず、辞書の優先記号の後ろにコンバータ由来の記号として並べる
    func testSymbolSingleNodeIsNotProtected() {
        let result = promote(words(["丸", "円", "まる", "麻流", "○", "マル"]), tier: .b, dictionary: ["●"])
        // 普通の語 (麻流) だけを飛ばし、○ は飛ばさずにその前へ入れる
        XCTAssertEqual(result.clientCandidates.map(\.text), ["丸", "円", "まる", "麻流", "●", "○", "マル"])
    }

    /// うえ: 普通の語の連続の後に置いた英字1ノード (ue) も保護して、その後ろへ入れる
    func testAlphabetSingleNodeIsProtected() {
        let result = promote(words(["上", "植え", "飢え", "上位", "ue", "ウエ"]), tier: .b, dictionary: ["↑"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["上", "植え", "飢え", "上位", "ue", "↑", "ウエ"])
    }

    /// あける: 2ノードの飽けるは保護しない既知の見逃しとして固定する
    func testMultiNodeWordIsNotProtected() {
        let entries = words(["開ける", "明ける", "空ける"]) + [converter("飽ける", nodes: 2)] + words(["アケル"])
        let result = promote(entries, tier: .b, dictionary: ["□"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["開ける", "明ける", "空ける", "□", "飽ける", "アケル"])
    }

    /// やじるし: 非語の2ノード連結は保護しない
    func testNonWordMultiNodeChainsAreNotProtected() {
        let entries = words(["矢印", "野次るし", "ヤジるし"]) + ["や印", "野次る氏"].map { converter($0, nodes: 2) }
        let result = promote(entries, tier: .b, dictionary: ["→"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["矢印", "野次るし", "ヤジるし", "→", "や印", "野次る氏"])
    }

    /// 普通の語の連続は途中のかな候補で切れる (非連続の普通の語は飛ばさない)
    func testOnlyConsecutiveOrdinaryWordsAreSkipped() {
        let result = promote(words(["a1", "a2", "a3", "下位", "シタ", "下方"]), tier: .b, dictionary: ["↓"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["a1", "a2", "a3", "下位", "↓", "シタ", "下方"])
    }

    /// ページ内の挿入位置では1記号分の枠を残すよう飛ばす件数を制限し、ページの外では連続する普通の語を全て飛ばす
    func testFirstPageRoomForPageSizes() {
        let entries = words(["w0", "w1", "w2", "w3", "w4", "w5", "w6", "w7", "w8", "w9", "w10"])
        let expectedIndices: [(pageSize: Int, live: Int32, index: Int)] = [
            (9, -1, 8), (10, -1, 9), (4, -1, 3), (3, -1, 11), (2, -1, 11), (1, -1, 11),
            // ライブ変換の候補がページの外 (index 9) の場合
            (9, 9, 11),
        ]
        for (pageSize, live, index) in expectedIndices {
            let result = promote(entries, live: live, pageSize: pageSize, tier: .b, dictionary: ["↓"])
            XCTAssertEqual(result.clientCandidates.firstIndex { $0.text == "↓" }, index, "pageSize \(pageSize)")
            XCTAssertEqual(result.liveTextIndex, live)
        }
    }

    // MARK: 同じ表記の扱い

    /// 部分読みの同表記候補だけがある場合は、移動も新規追加もしない
    func testPartialReadingOnlyDuplicateIsSkipped() {
        let entries = words(["a", "b", "c", "d"]) + [converter("↓", rubyCount: 1)]
        let result = promote(entries, tier: .b, dictionary: ["↓", "↑"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["a", "b", "c", "d", "↑", "↓"])
        XCTAssertEqual(result.serverCandidates.filter(Self.isSymbolEntry).count, 1)
    }

    /// 全読みの同表記候補があれば、新規に作らず.fromConverterのまま移す
    func testFullReadingDuplicateIsReused() {
        let entries = words(["a", "b", "c", "d", "e"]) + [converter("↓", rubyCount: 1), converter("↓")]
        let result = promote(entries, tier: .a, dictionary: ["↓"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["a", "b", "c", "↓", "d", "e", "↓"])
        guard case .fromConverter(let moved) = result.serverCandidates[3] else { return XCTFail("移した候補") }
        XCTAssertEqual(moved.rubyCount, Self.readingLength)
    }

    /// 保護範囲の候補や動かさない注入候補と同じ表記は、移動も追加もしない
    func testTextsOfProtectedAndInjectedCandidatesAreSkipped() {
        let entries = words(["→", "b", "c", "d"]) + [emoji("❤")]
        let result = promote(entries, tier: .a, dictionary: ["→", "❤", "☆"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["→", "b", "c", "☆", "d", "❤"])
    }

    /// 補助記号辞書が空でも、保護範囲の候補と同じ表記のコンバータ由来の記号は移さない
    func testConverterSymbolDuplicateOfProtectedHeadIsNotMoved() {
        let result = promote(words(["→", "b", "c", "d", "→", "e"]), tier: .a, dictionary: [])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["→", "b", "c", "d", "→", "e"])
    }

    /// 補助記号辞書が空でも、動かさない注入候補と同じ表記のコンバータ由来の記号は移さない
    func testConverterSymbolDuplicateOfInjectedCandidateIsNotMoved() {
        let entries = words(["a", "b", "c", "d"]) + [date("↓"), converter("↓"), converter("※")]
        let result = promote(entries, tier: .a, dictionary: [])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["a", "b", "c", "※", "d", "↓", "↓"])
    }

    /// 新規候補のsubHiraganaは残りの読みと一致し、学習の注釈を持たない
    func testNewCandidatesCarryRemainingReading() {
        let result = promote(words(["a", "b", "c"]), tier: .a, dictionary: ["「」"])
        XCTAssertEqual(result.clientCandidates[3].subHiragana, Self.remaining)
        XCTAssertFalse(result.clientCandidates[3].hasLearningEntry_p)
        guard case .fromSymbol(let word, let count) = result.serverCandidates[3] else { return XCTFail("新規候補") }
        XCTAssertEqual(word, "「」")
        XCTAssertEqual(count, .surfaceCount(Self.readingLength))
    }

    /// 他の注入候補は動かさず、相互の順序を保つ
    func testInjectedCandidatesKeepTheirOrder() {
        let entries = words(["今日", "京", "きょう"]) + [date("2026年11月16日"), date("2026-11-16")] + words(["→"])
        let result = promote(entries, tier: .b, dictionary: ["☆"])
        XCTAssertEqual(
            result.clientCandidates.map(\.text), ["今日", "京", "きょう", "☆", "→", "2026年11月16日", "2026-11-16"])
    }

    // MARK: 上限外の補助記号

    /// 上限外の補助記号は先頭ページに入れず、最初の絵文字の前へ足す
    func testLeftoversGoAfterFirstPageAndBeforeEmoji() {
        let dictionary = (0..<12).map { String(Unicode.Scalar(0x2190 + $0)!) }
        let entries = words(["a", "b", "c", "d", "e", "f", "g", "h", "i"]) + [emoji("😀")]
        let result = promote(entries, tier: .a, dictionary: dictionary)
        XCTAssertEqual(
            result.clientCandidates.map(\.text),
            ["a", "b", "c"] + dictionary.prefix(6) + ["d", "e", "f", "g", "h", "i"] + dictionary.suffix(6) + ["😀"])
        // 絵文字が早い位置にあっても、上限外の記号はページの外 (index 9以降) に入れる
        let earlyEmoji = [emoji("😀")] + words(["a", "b", "c", "d", "e", "f", "g", "h"])
        let early = promote(earlyEmoji, tier: .a, dictionary: dictionary).clientCandidates.map(\.text)
        XCTAssertEqual(early.firstIndex(of: dictionary[6]), 9)
        XCTAssertEqual(Array(early.prefix(9)), ["😀", "a", "b"] + dictionary.prefix(6))
    }

    /// 繰り上げ後の候補数がページサイズ未満の場合は、上限外の補助記号を足さない
    func testNoLeftoversBelowPageSize() {
        let dictionary = (0..<12).map { String(Unicode.Scalar(0x2190 + $0)!) }
        let result = promote(words(["a", "b"]), tier: .a, dictionary: dictionary)
        XCTAssertEqual(result.clientCandidates.map(\.text), ["a", "b"] + dictionary.prefix(6))
    }

    /// 補助記号辞書に無いコンバータ由来の記号は、辞書の記号の後ろへ元の順で入れ、上限外は元の順序を保つ
    func testConverterSymbolsFillRemainingSlots() {
        let entries = words(["a", "b", "c", "d", "※", "e", "♪", "☆"])
        let result = promote(entries, tier: .b, dictionary: ["→"])
        XCTAssertEqual(result.clientCandidates.map(\.text), ["a", "b", "c", "d", "→", "※", "♪", "e", "☆"])
    }
}
