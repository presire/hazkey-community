import Foundation
import KanaKanjiConverterModule

/// 打ち間違い (タイポ) を検出し、利用者の実際の入力を変えずに、読みの訂正候補を上限付きで生成する
///
/// トリガーの検出と編集案の生成だけを担い、変換エンジンへの問い合わせや候補の並べ替えは呼び出し側が行う
///
/// - Note: 生成するのはあくまで変換用の読みであり、組成テキストそのものは書き換えない
enum TypoCorrector {
    /// 訂正の種別
    enum EditKind: Equatable {
        /// 連打で重複したキーを削減する
        case repeatedKey
        /// 読みにそのまま残ったローマ字を削除する
        case strayRomaji
        /// 隣接する打鍵を入れ替える
        case adjacentSwap
        /// 抜けた母音を補完する
        case missingVowel
        /// 連続した同一のかなの並びを、まとめて1文字ずつへ縮約する
        ///
        /// [repeatedKey] が同一キーの連打だけを対象にするのに対し、こちらは
        /// [xya] の連続や [xtu] の連続のように、別々のキーから生じた同一かなの並びも含めて縮約する
        case collapsedRepeats
        /// 母音キーを、QWERTY配列で隣り合う子音キーへ打ち間違えた場合に、その子音を母音へ戻す
        ///
        /// 例: ありがとう の [o] を右隣の [p] と打ち間違えた [arigatpu] では、
        /// 残留した [p] を同じ位置の母音 [o] へ置き換える
        case adjacentKey
        /// や行の直前に置くべき撥音 [ん] を打ち忘れ、[にゃ] を [に] と [や] に分けて入力した場合に、[ん] を補う
        ///
        /// 例: 金曜日 を意図した [kinyoubi] (きにょうび) では、[に] の直前へ [ん] を挿入する
        case missingN
    }

    /// 1回の訂正の内容を表す
    struct Edit: Equatable {
        /// 訂正の対象となる入力位置
        ///
        /// repeatedKey では削除した先頭の入力位置、missingVowel では母音を挿入した入力位置
        ///
        /// strayRomaji では削除した文字の入力位置、adjacentSwap では入れ替える左側の入力位置
        ///
        /// collapsedRepeats では影響範囲を特定せず 0 を使う (縮約は入力の複数箇所へまたがるため)
        let position: Int
        /// 訂正の種別
        let kind: EditKind
        /// repeatedKey で削除した連打キーの個数 (他の種別は常に1)
        var count: Int = 1

        /// 訂正が影響する入力要素の範囲
        ///
        /// 種別ごとに、削除・入れ替え・挿入の影響が届く範囲を返す
        var inputRange: Range<Int> {
            switch kind {
            case .repeatedKey: max(0, position - 1)..<(position + count)
            case .strayRomaji: position..<(position + 1)
            case .adjacentSwap: max(0, position - 1)..<(position + 2)
            case .missingVowel: (position - 1)..<position
            case .collapsedRepeats: 0..<0
            case .adjacentKey: max(0, position - 1)..<(position + 1)
            case .missingN: max(0, position - 1)..<position
            }
        }
    }

    /// 1つの訂正案と、その訂正を適用した組成テキストを表す
    struct Variant {
        /// 訂正を適用した組成テキスト
        let composingText: ComposingText
        /// 訂正後の読み
        let reading: String
        /// この訂正案を生成した編集
        let edit: Edit
        /// この訂正案に含まれる編集の数 (既定は1)
        var editCount: Int = 1
    }

    /// 連打縮約の候補を、入力範囲と編集の組で保持する
    private struct RunCorrection {
        /// この縮約が削除する入力要素の範囲
        let inputRange: Range<Int>
        /// この縮約に対応する編集
        let edit: Edit
    }

    /// 読みの中に見つかった訂正の手がかり (トリガー)
    struct Trigger: Equatable {
        /// トリガーが占める読みの範囲
        let range: Range<Int>
    }

    /// 訂正箇所の数の上限
    ///
    /// 同じ位置の母音補完5通りは1箇所とみなすため、返る訂正案がこの数を超える場合がある
    static let maxVariants = 3
    /// 訂正の対象とする読みの最大長
    static let maxReadingLength = 32

    /// 連続して打ち重ねられるかな (促音・撥音・長音符・小書きかな)
    ///
    /// これらが2つ以上連続した並びを打ち間違いの手がかりとする
    static let repeatableKana: Set<Character> = ["っ", "ん", "ー", "ゃ", "ゅ", "ょ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゎ"]
    /// 小書きのかな
    ///
    /// 促音も含めた同一の並びを、キーをまたいで1文字へ縮約できる対象とする
    static let collapsibleSmallKana: Set<Character> = ["ゃ", "ゅ", "ょ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゎ", "っ"]
    /// 母音キーを打ち間違えやすい、QWERTY配列上で隣り合う子音キーから母音キーへの対応表 (E5)
    ///
    /// 母音キー [a/i/u/e/o] の左右いずれかに隣接する子音キーを値とし、打鍵位置ごとに試す母音を列挙する
    ///
    /// 例: [o] は [p] の左隣にあるため、[p] は [o] と打ち間違え得る
    static let adjacentVowelKeys: [Character: [Character]] = [
        "q": ["a"], "w": ["a", "e"], "s": ["a", "e"], "z": ["a"], "r": ["e"], "d": ["e"],
        "y": ["u"], "h": ["u"], "j": ["u", "i"], "k": ["i", "o"], "l": ["o"], "p": ["o"],
    ]
    /// 主変換がこの時間 (ミリ秒) を超えたら打鍵時の訂正を省略し、訂正案の評価もこの時間で打ち切る
    static let typoTimeBudget = 50

    /// 最初の1編集に課すペナルティ
    static let typoEditPenalty: PValue = 12
    /// 2編集目以降の1編集あたりのペナルティ
    ///
    /// 複数箇所の連打縮約 ([すーーぱーーー→すーぱー]、実測 raw margin +23.48) を 12×2=24 では落としてしまうため、2編集目を軽くする (合計 20)
    static let additionalEditPenalty: PValue = 8

    /// 読みから訂正の手がかり (トリガー) を検出する
    ///
    /// [repeatableKana] の同一文字が連続する各ペアと、母音か [ん] か [ー] の直前に置かれた [っ] を、その範囲とともに返す
    ///
    /// 読みの先頭、または直前がかなである位置から始まり、直後がかなである ASCII 英字の連続も、打ち残したローマ字として検出する
    ///
    /// かなの直後に現れた [にゃ] [にゅ] [にょ] も、直前に [ん] が無い場合は撥音の打ち忘れとして検出する (E6)
    ///
    /// - Parameter reading: 検査するひらがな読み
    /// - Returns: 見つかったトリガーの一覧 (読みの位置順)
    /// - Note: 読みの末尾に残った英字は入力途中とみなし、トリガーにしない
    static func triggers(in reading: String) -> [Trigger] {
        let chars = Array(reading)
        guard !chars.isEmpty else { return [] }
        var found: [Trigger] = []
        for index in chars.indices where index + 1 < chars.count {
            let repeatedKana = chars[index] == chars[index + 1] && repeatableKana.contains(chars[index])
            if repeatedKana || (chars[index] == "っ" && "あいうえおんー".contains(chars[index + 1])) {
                found.append(Trigger(range: index..<(index + 2)))
            }
            if chars[index] == "に", "ゃゅょ".contains(chars[index + 1]),
                index >= 1, isKana(chars[index - 1]), chars[index - 1] != "ん" {
                found.append(Trigger(range: index..<(index + 2)))
            }
        }
        var index = 0
        while index < chars.count {
            guard chars[index].isASCII, chars[index].isLetter else { index += 1; continue }
            let start = index
            while index < chars.count, chars[index].isASCII, chars[index].isLetter { index += 1 }
            // 読みの先頭に残ったローマ字 ([mちがい]) も対象にする (末尾の英字は入力途中のため対象外)
            if index < chars.count, isKana(chars[index]), start == 0 || isKana(chars[start - 1]) {
                found.append(Trigger(range: start..<index))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// トリガーを打ち消す訂正案を生成する
    ///
    /// E0: 読みの同一かなの並び (長さ2以上) をまとめて1文字ずつへ縮約する案を、次の提案より先に先頭へ置く
    ///
    /// 次の4種類の編集を、この順で候補にする
    ///
    /// E1: 同一で編集可能なキーの連続から末尾側を1個以上削除し、削除が少ない順に試す
    ///
    /// E2: 読みにそのまま現れた、マップ済みの ASCII 英字を1文字削除する
    ///
    /// E3: 編集可能な隣接2要素を、既に確定したかなを壊さない場合にだけ入れ替える
    ///
    /// E4: 残留ローマ字の連続の末尾に、抜けた母音を [aiueo] の5通り挿入する
    ///
    /// E5: 残留ローマ字の子音を、QWERTY配列で隣り合う母音 ([adjacentVowelKeys]) へ置き換える
    ///
    /// E6: 撥音 [ん] を伴わない [にゃ] [にゅ] [にょ] の直前へ [ん] を挿入する
    ///
    /// トリガーを打ち消せない編集と、読みが既存の訂正案と重複する編集は採用しない
    ///
    /// 上限 ([maxVariants]) は訂正箇所の数で数える
    ///
    /// E0 は縮約する並びの個数を1箇所として数える (2箇所以上なら [EditKind.collapsedRepeats]、1箇所なら [EditKind.repeatedKey])
    ///
    /// E0 が単一の並びで、E1 の同一キー連打の縮約でも同じ読みが得られる場合は、元の入力スタイルを保つ E1 の案に任せる
    ///
    /// 母音補完 (E4) と、同じ位置で試す複数の母音キー (E5) は、それぞれ1箇所とみなす
    ///
    /// 連打縮約が2箇所に分かれる場合は、互いに重ならない2箇所を同時に縮約した案も作る
    ///
    /// 小書きかなと促音の縮約は [xya] や [xtu] のように別々のローマ字キーへまたがることがあるため、対応する入力範囲を特定して縮約する
    ///
    /// - Parameters:
    ///   - text: 訂正の対象となる組成テキスト
    ///   - triggers: [triggers(in:)] で検出したトリガー
    /// - Returns: 生成した訂正案の一覧 (編集の種類と位置の順)
    /// - Note: 読みの長さが [maxReadingLength] を超える場合やトリガーが無い場合は空を返す
    static func variants(of text: ComposingText, triggers: [Trigger]) -> [Variant] {
        guard !triggers.isEmpty, text.convertTarget.count <= maxReadingLength else { return [] }
        let original = text.input
        let originalTriggers = triggers
        var proposals: [(Edit, [ComposingText.InputElement])] = []

        // E1: 同一で編集可能なキーの連続から、末尾側を削除して短くする
        // トリガーを消せる最小の縮約が先に来るよう、削除が少ない順に試す
        var runStart = 0
        while runStart < original.count {
            var runEnd = runStart + 1
            while runEnd < original.count, editable(original[runStart]), editable(original[runEnd]),
                  original[runEnd].piece == original[runStart].piece {
                runEnd += 1
            }
            for removed in stride(from: 1, to: runEnd - runStart, by: 1) {
                var edited = original
                edited.removeSubrange((runEnd - removed)..<runEnd)
                proposals.append((Edit(position: runEnd - removed, kind: .repeatedKey, count: removed), edited))
            }
            runStart = runEnd
        }
        // E2: 読みにそのまま現れた、マップ済みの ASCII 英字を削除する
        let readingChars = Array(text.convertTarget)
        var strayIndices: [Int] = []
        for (i, element) in original.enumerated() where editable(element) {
            guard let character = effectiveInputCharacter(element),
                  character.isASCII, character.isLetter,
                  let surfaceRange = surfaceRange(in: text, inputRange: i..<(i + 1)),
                  !surfaceRange.isEmpty,
                  surfaceRange.upperBound <= readingChars.count,
                  readingChars[surfaceRange].contains(character) else { continue }
            strayIndices.append(i)
            var edited = original
            edited.remove(at: i)
            proposals.append((Edit(position: i, kind: .strayRomaji), edited))
        }
        // E3: 編集可能な文字入力の隣接2要素だけを入れ替える
        // 残留英字を直前のキーの前へ移すと、既に確定したかなを壊してしまうため
        if original.count > 1 {
            for i in 0..<(original.count - 1) where editable(original[i]) && editable(original[i + 1]) {
                guard !strayIndices.contains(i + 1),
                      original[i].piece != original[i + 1].piece,
                      effectiveInputCharacter(original[i]) != nil,
                      effectiveInputCharacter(original[i + 1]) != nil else { continue }
                var edited = original
                edited.swapAt(i, i + 1)
                proposals.append((Edit(position: i, kind: .adjacentSwap), edited))
            }
        }
        // E4: 残留ローマ字の連続の末尾に、抜けた母音を挿入する
        for i in strayIndices where !strayIndices.contains(i + 1) {
            for vowel in "aiueo" {
                var edited = original
                edited.insert(.init(piece: .character(vowel), inputStyle: original[i].inputStyle), at: i + 1)
                proposals.append((Edit(position: i + 1, kind: .missingVowel), edited))
            }
        }
        // E5: 残留ローマ字の子音を、QWERTY配列で隣り合う母音キーへ置き換える
        // 編集位置は、残留ローマ字の各位置と、その極大な並びの直後の位置 (並びが続く限り子音キーが残るため) とする
        var adjacentKeyEditSites: [Int] = []
        var adjacentKeySiteSet: Set<Int> = Set()
        for index in strayIndices where isAdjacentKeySite(original, at: index) {
            if adjacentKeySiteSet.insert(index).inserted { adjacentKeyEditSites.append(index) }
        }
        var strayRunStart = 0
        while strayRunStart < strayIndices.count {
            var strayRunEnd = strayRunStart
            while strayRunEnd + 1 < strayIndices.count,
                strayIndices[strayRunEnd + 1] == strayIndices[strayRunEnd] + 1
            {
                strayRunEnd += 1
            }
            let afterRun = strayIndices[strayRunEnd] + 1
            if afterRun < original.count, isAdjacentKeySite(original, at: afterRun),
                adjacentKeySiteSet.insert(afterRun).inserted
            {
                adjacentKeyEditSites.append(afterRun)
            }
            strayRunStart = strayRunEnd + 1
        }
        for site in adjacentKeyEditSites {
            guard let character = effectiveInputCharacter(original[site]),
                let vowels = adjacentVowelKeys[character] else { continue }
            for vowel in vowels {
                var edited = original
                edited[site] = .init(piece: .character(vowel), inputStyle: original[site].inputStyle)
                proposals.append((Edit(position: site, kind: .adjacentKey), edited))
            }
        }
        // E6: 撥音 [ん] を伴わない [にゃ] [にゅ] [にょ] の直前へ [ん] を挿入する
        // 入力側で [n][y][a/u/o] の並びを探し、[ん] を挿入した読みが期待値と完全に一致する場合だけ採用する
        for trigger in triggers where trigger.range.count == 2
            && trigger.range.lowerBound >= 1 && trigger.range.upperBound <= readingChars.count
            && readingChars[trigger.range.lowerBound] == "に"
            && "ゃゅょ".contains(readingChars[trigger.range.lowerBound + 1])
            && isKana(readingChars[trigger.range.lowerBound - 1])
            && readingChars[trigger.range.lowerBound - 1] != "ん"
        {
            let smallKana = readingChars[trigger.range.lowerBound + 1]
            let fullKana: Character = smallKana == "ゃ" ? "や" : (smallKana == "ゅ" ? "ゆ" : "よ")
            var expected = readingChars
            expected.replaceSubrange(trigger.range, with: ["ん", fullKana])
            var inserted = false
            for i in 0..<original.count where !inserted && i + 2 < original.count {
                guard editable(original[i]), editable(original[i + 1]), editable(original[i + 2]),
                    effectiveInputCharacter(original[i]) == "n",
                    effectiveInputCharacter(original[i + 1]) == "y",
                    let third = effectiveInputCharacter(original[i + 2]),
                    "auo".contains(third) else { continue }
                var edited = original
                edited.insert(.init(piece: .character("n"), inputStyle: original[i].inputStyle), at: i)
                var candidate = ComposingText()
                candidate.insertAtCursorPosition(edited)
                guard candidate.convertTarget == String(expected) else { continue }
                proposals.append((Edit(position: i + 1, kind: .missingN), edited))
                inserted = true
            }
        }

        var results: [Variant] = []
        // 上限 (maxVariants) は訂正箇所の数で数える
        // 母音補完は同じ位置の5母音で1箇所とし、どの母音が正しいかは変換スコアでしか決まらないため全て評価する ([まtがえる] の「i」は2番目の母音)
        var slotCount = 0
        // E0: 読みの同一かなの並びをまとめて縮約する案を先頭へ置く
        // 複数の並びを同時に縮約できる唯一の案であり、部分的な縮約より優先する
        if let (collapsedVariant, siteCount) = collapsedRepeatsVariant(of: text) {
            // 単一の並びが E1 の同一キー連打の縮約でも得られる場合は、元の入力スタイルを保つ E1 の案に任せる
            let coveredByRepeatedKey = siteCount == 1 && proposals.contains { proposal in
                guard proposal.0.kind == .repeatedKey else { return false }
                var candidate = ComposingText()
                candidate.insertAtCursorPosition(proposal.1)
                return candidate.convertTarget == collapsedVariant.reading
            }
            if !coveredByRepeatedKey {
                let removedCount = readingChars.count - collapsedVariant.reading.count
                let edit: Edit = siteCount >= 2
                    ? Edit(position: 0, kind: .collapsedRepeats)
                    : Edit(position: 0, kind: .repeatedKey, count: removedCount)
                results.append(Variant(
                    composingText: collapsedVariant.composingText, reading: collapsedVariant.reading,
                    edit: edit, editCount: max(1, siteCount)))
                slotCount = 1
            }
        }
        var vowelSites: Set<Int> = []
        var adjacentKeySites: Set<Int> = []
        var collapsedRunEnds: Set<Int> = []
        var runCorrections: [RunCorrection] = []
        for (edit, elements) in proposals {
            let joinsVowelSite = edit.kind == .missingVowel && vowelSites.contains(edit.position)
            let joinsAdjacentKeySite = edit.kind == .adjacentKey && adjacentKeySites.contains(edit.position)
            guard joinsVowelSite || joinsAdjacentKeySite || slotCount < maxVariants else { continue }
            if edit.kind == .repeatedKey, collapsedRunEnds.contains(edit.position + edit.count) { continue }
            var candidate = ComposingText()
            candidate.insertAtCursorPosition(elements)
            guard removesOverlappingTrigger(original: text, edited: candidate, triggers: originalTriggers, edit: edit) else { continue }
            if edit.kind == .repeatedKey { collapsedRunEnds.insert(edit.position + edit.count) }
            guard !results.contains(where: { $0.reading == candidate.convertTarget }) else { continue }
            results.append(Variant(composingText: candidate, reading: candidate.convertTarget, edit: edit))
            if !joinsVowelSite && !joinsAdjacentKeySite { slotCount += 1 }
            if edit.kind == .missingVowel { vowelSites.insert(edit.position) }
            if edit.kind == .adjacentKey { adjacentKeySites.insert(edit.position) }
            if edit.kind == .repeatedKey {
                runCorrections.append(RunCorrection(
                    inputRange: edit.position..<(edit.position + edit.count), edit: edit))
            }
        }

        guard slotCount < maxVariants else { return results }

        // 小書きかなと促音は ([xya] や [xtu] のように) 別々のローマ字キーへまたがることがあるため、対応する入力範囲を特定する
        let mapping = text.inputIndexToSurfaceIndexMap()
        let boundaries = mapping.keys.sorted()
        var smallKanaVariants: [Variant] = []
        for trigger in triggers where trigger.range.upperBound <= readingChars.count
            && trigger.range.count == 2
            && readingChars[trigger.range.lowerBound] == readingChars[trigger.range.lowerBound + 1]
            && collapsibleSmallKana.contains(readingChars[trigger.range.lowerBound]) {
            if runCorrections.count == maxVariants { break }
            let smallKanaIndex = trigger.range.upperBound - 1
            guard let start = boundaries.first(where: { mapping[$0] == smallKanaIndex }),
                  let end = boundaries.first(where: { $0 > start && mapping[$0] == smallKanaIndex + 1 }),
                  original[start..<end].allSatisfy(editable) else { continue }
            var elements = original
            elements.removeSubrange(start..<end)
            var candidate = ComposingText()
            candidate.insertAtCursorPosition(elements)
            var expected = readingChars
            expected.remove(at: smallKanaIndex)
            guard candidate.convertTarget == String(expected) else { continue }
            let edit = Edit(position: start, kind: .repeatedKey, count: end - start)
            runCorrections.append(RunCorrection(inputRange: start..<end, edit: edit))
            smallKanaVariants.append(Variant(composingText: candidate, reading: candidate.convertTarget, edit: edit))
        }

        for first in runCorrections.indices {
            for second in runCorrections.indices where second > first {
                let left = runCorrections[first]
                let right = runCorrections[second]
                guard left.inputRange.upperBound < right.inputRange.lowerBound
                    || right.inputRange.upperBound < left.inputRange.lowerBound else { continue }
                var elements = original
                for range in [left.inputRange, right.inputRange].sorted(by: { $0.lowerBound > $1.lowerBound }) {
                    elements.removeSubrange(range)
                }
                var candidate = ComposingText()
                candidate.insertAtCursorPosition(elements)
                guard Self.triggers(in: candidate.convertTarget).isEmpty,
                      !results.contains(where: { $0.reading == candidate.convertTarget }) else { continue }
                results.append(Variant(
                    composingText: candidate, reading: candidate.convertTarget, edit: left.edit, editCount: 2))
                slotCount += 1
                if slotCount == maxVariants { return results }
            }
        }
        for variant in smallKanaVariants where slotCount < maxVariants {
            if !results.contains(where: { $0.reading == variant.reading }) {
                results.append(variant)
                slotCount += 1
            }
        }
        return results
    }

    /// 読みに連続した同一かなの並びがあれば、それらをまとめて1文字ずつへ縮約した訂正案を作る
    ///
    /// 縮約する並びの数を sites、並びを1文字ずつに畳んだ読みを collapsed とする
    ///
    /// 影響を受けない末尾をそのまま保つため、入力と読みの対応 ([ComposingText.inputIndexToSurfaceIndexMap]) から
    /// 最後の縮約の直後以降にあたる最小の境界を選び、その読みの接頭辞を凍結要素 ([InputTableID.empty] の mapped) として
    /// 先頭へ置き、元の入力の残り (入力途中のローマ字や文節区切り) をそのまま連結する
    ///
    /// 再構成した読みが collapsed と一致しない場合は採用しない
    ///
    /// - Parameter text: 縮約の対象となる組成テキスト
    /// - Returns: 縮約案と縮約する並びの数 (縮約できる並びが無い、または再構成に失敗した場合はnil)
    private static func collapsedRepeatsVariant(of text: ComposingText) -> (variant: Variant, siteCount: Int)? {
        let readingChars = Array(text.convertTarget)
        guard !readingChars.isEmpty else { return nil }
        // 直接入力は編集しない (組成に1つでも含まれる場合は縮約を見送る)
        guard !text.input.contains(where: { $0.inputStyle == .direct }) else { return nil }
        // 末尾で入力途中の ASCII 英字は縮約の対象にしない
        var trailingAsciiStart = readingChars.count
        while trailingAsciiStart > 0, readingChars[trailingAsciiStart - 1].isASCII,
              readingChars[trailingAsciiStart - 1].isLetter {
            trailingAsciiStart -= 1
        }
        // 同一かなの極大な並び (長さ2以上) を集める
        var runs: [Range<Int>] = []
        var index = 0
        while index < readingChars.count {
            var end = index + 1
            while end < readingChars.count, readingChars[end] == readingChars[index] { end += 1 }
            if end - index >= 2, repeatableKana.contains(readingChars[index]), end <= trailingAsciiStart {
                runs.append(index..<end)
            }
            index = end
        }
        guard let lastRun = runs.last else { return nil }
        // 並びを1文字ずつに畳んだ読みを作る
        var collapsed: [Character] = []
        var runIndex = 0
        var position = 0
        while position < readingChars.count {
            if runIndex < runs.count, runs[runIndex].lowerBound == position {
                collapsed.append(readingChars[position])
                position = runs[runIndex].upperBound
                runIndex += 1
            } else {
                collapsed.append(readingChars[position])
                position += 1
            }
        }
        let collapsedReading = String(collapsed)
        // 最後の縮約の直後以降にあたる最小の入力境界を選ぶ
        let mapping = text.inputIndexToSurfaceIndexMap()
        let boundaries = mapping.keys.sorted()
        guard let inputBoundary = boundaries.first(where: { (mapping[$0] ?? -1) >= lastRun.upperBound }),
              let surfaceBoundary = mapping[inputBoundary],
              surfaceBoundary <= readingChars.count else { return nil }
        let tailCount = readingChars.count - surfaceBoundary
        let prefixCount = collapsed.count - tailCount
        guard prefixCount >= 0, prefixCount <= collapsed.count else { return nil }
        let frozen = collapsed[0..<prefixCount].map {
            ComposingText.InputElement(piece: .character($0), inputStyle: .mapped(id: .empty))
        }
        var elements = frozen
        elements.append(contentsOf: text.input[inputBoundary...])
        var candidate = ComposingText()
        candidate.insertAtCursorPosition(elements)
        guard candidate.convertTarget == collapsedReading else { return nil }
        return (Variant(composingText: candidate, reading: collapsedReading, edit: Edit(position: 0, kind: .collapsedRepeats)), runs.count)
    }

    /// 完全な訂正が1つでもあれば、トリガーが残る部分的な訂正を除いた配列を返す
    ///
    /// 読みにトリガーが残らない訂正 (完全な訂正) が提示される場合、まだトリガーが残る訂正は劣るため落とす
    ///
    /// - Parameters:
    ///   - items: 選別する要素の配列
    ///   - reading: 各要素の訂正後の読みを取り出す関数
    /// - Returns: 完全な訂正が無ければ全件、あればトリガーが残らない要素だけの配列
    static func preferringComplete<T>(_ items: [T], reading: (T) -> String) -> [T] {
        guard items.contains(where: { triggers(in: reading($0)).isEmpty }) else { return items }
        return items.filter { triggers(in: reading($0)).isEmpty }
    }

    /// 最良の訂正から、ペナルティ適用後の値がこの幅以上低い訂正は提示しない
    ///
    /// 1編集分のペナルティと同じ幅にする
    ///
    /// 例: [さよんsら] では さよなら (実測 +38.2) に対し、差米ら (+15.9) や さよんすら (+13.1) は雑音になる
    static let competitiveMargin = Double(typoEditPenalty)

    /// 最良の訂正と競り合える訂正だけを残す
    ///
    /// - Parameters:
    ///   - items: 選別する要素の配列
    ///   - adjustedValue: 各要素のペナルティ適用後の値を取り出す関数
    /// - Returns: 最良の値との差が [competitiveMargin] 未満の要素だけの配列 (元の順序を保つ)
    static func competitive<T>(_ items: [T], adjustedValue: (T) -> Double) -> [T] {
        guard let best = items.map(adjustedValue).max() else { return items }
        return items.filter { adjustedValue($0) > best - competitiveMargin }
    }

    /// 編集数に応じたペナルティ値を返す
    ///
    /// - Parameter editCount: 訂正案に含まれる編集の数
    /// - Returns: 最初の1編集は [typoEditPenalty]、2編集目以降は1編集あたり [additionalEditPenalty] を加算した値 (0以下は0)
    static func penalty(editCount: Int) -> Double {
        guard editCount > 0 else { return 0 }
        return Double(typoEditPenalty) + Double(editCount - 1) * Double(additionalEditPenalty)
    }

    /// 訂正案を提示すべきかを判定する
    ///
    /// - Parameters:
    ///   - variantValue: 訂正案の変換スコア
    ///   - baselineValue: 元の読みの基準スコア
    ///   - editCount: 訂正案に含まれる編集の数
    /// - Returns: ペナルティを引いた訂正案の値が基準以上ならtrue
    static func shouldOffer(variantValue: Double, baselineValue: Double, editCount: Int) -> Bool {
        variantValue - penalty(editCount: editCount) >= baselineValue
    }

    /// 読み全体を覆う最初の候補を返す
    ///
    /// - Parameters:
    ///   - candidates: 変換結果の候補列
    ///   - readingLength: 覆うべき読みの長さ
    /// - Returns: ルビ文字数が readingLength に一致する最初の候補 (見つからなければnil)
    static func bestExactMatch(in candidates: [Candidate], readingLength: Int) -> Candidate? {
        candidates.first { $0.rubyCount == readingLength }
    }

    /// 訂正案の評価に使う変換オプションを作る
    ///
    /// 訂正の比較を安定させるため、N_best を1にし、日本語予測・特殊候補プロバイダ・ニューラル変換・従来の誤字訂正を無効化する
    ///
    /// - Parameter options: 元の変換オプション
    /// - Returns: 訂正案の評価専用に調整した変換オプション
    static func correctionOptions(from options: ConvertRequestOptions) -> ConvertRequestOptions {
        var result = options
        result.N_best = 1
        result.requireJapanesePrediction = .disabled
        result.specialCandidateProviders = []
        result.zenzaiMode = .off
        result.typoCorrectionMode = .disabled
        return result
    }

    /// その入力要素を訂正の対象にできるかを返す
    ///
    /// - Parameter element: 検査する入力要素
    /// - Returns: 直接入力ではなく、文節区切りでもなければtrue
    private static func editable(_ element: ComposingText.InputElement) -> Bool {
        guard element.inputStyle != .direct else { return false }
        return element.piece != .compositionSeparator
    }

    /// その入力位置が E5 (隣接キー誤打) の編集位置になり得るかを返す
    ///
    /// - Parameters:
    ///   - input: 検査する入力要素列
    ///   - index: 検査する入力位置
    /// - Returns: 編集可能で、実効文字が [adjacentVowelKeys] に載る ASCII 英字ならtrue
    private static func isAdjacentKeySite(
        _ input: [ComposingText.InputElement], at index: Int
    ) -> Bool {
        guard index >= 0, index < input.count, editable(input[index]),
            let character = effectiveInputCharacter(input[index]),
            character.isASCII, character.isLetter,
            adjacentVowelKeys[character] != nil else { return false }
        return true
    }

    /// その文字がかな (ひらがな・濁点・半濁点・長音符) かを返す
    ///
    /// - Parameter character: 検査する文字
    /// - Returns: 全スカラがひらがな・濁点・半濁点・長音符のいずれかならtrue
    private static func isKana(_ character: Character) -> Bool {
        let scalars = Array(character.unicodeScalars)
        return !scalars.isEmpty && scalars.allSatisfy {
            (0x3041...0x3096).contains($0.value)
                || (0x3099...0x309a).contains($0.value)
                || $0.value == 0x30fc
        }
    }

    /// 入力範囲に対応する読みの範囲を返す
    ///
    /// - Parameters:
    ///   - text: 対応を取る組成テキスト
    ///   - inputRange: 入力要素の範囲
    /// - Returns: 対応する読みの範囲 (範囲が不正、または対応が取れなければnil)
    private static func surfaceRange(
        in text: ComposingText,
        inputRange: Range<Int>
    ) -> Range<Int>? {
        guard inputRange.lowerBound >= 0, inputRange.upperBound <= text.input.count else {
            return nil
        }
        let mapping = text.inputIndexToSurfaceIndexMap()
        let boundaries = mapping.keys.sorted()
        guard let startInput = boundaries.last(where: { $0 <= inputRange.lowerBound }),
              let endInput = boundaries.first(where: { $0 >= inputRange.upperBound }),
              let start = mapping[startInput], let end = mapping[endInput], start <= end else {
            return nil
        }
        return start..<end
    }

    /// 編集が対象のトリガーを打ち消すかを判定する
    ///
    /// - Parameters:
    ///   - original: 編集前の組成テキスト
    ///   - edited: 編集後の組成テキスト
    ///   - triggers: 元の読みのトリガー
    ///   - edit: 加えた編集
    /// - Returns: 編集前の範囲にトリガーがあり、編集後の同じ範囲に ASCII 英字もトリガーも残らない場合にtrue
    private static func removesOverlappingTrigger(
        original: ComposingText, edited: ComposingText, triggers: [Trigger], edit: Edit
    ) -> Bool {
        let inputRange = edit.inputRange
        guard inputRange.upperBound <= original.input.count,
              let originalSpan = surfaceRange(in: original, inputRange: inputRange),
              !originalSpan.isEmpty else { return false }
        guard triggers.contains(where: { $0.range.overlaps(originalSpan) }) else { return false }
        let editedChars = Array(edited.convertTarget)
        let localSpan: Range<Int>
        switch edit.kind {
        case .repeatedKey:
            // 縮約の影響は前後の共通部分の境界に現れるため、共通接頭辞と共通接尾辞の
            // 境界を±1文字の文脈付きで局所判定する (反復文字で両者が重なる場合も安全側に広げる)
            let originalChars = Array(original.convertTarget)
            let editedCount = editedChars.count
            var commonPrefix = 0
            while commonPrefix < editedCount, commonPrefix < originalChars.count,
                originalChars[commonPrefix] == editedChars[commonPrefix]
            {
                commonPrefix += 1
            }
            var commonSuffix = 0
            while commonSuffix < editedCount, commonSuffix < originalChars.count,
                originalChars[originalChars.count - 1 - commonSuffix] == editedChars[editedCount - 1 - commonSuffix]
            {
                commonSuffix += 1
            }
            let suffixStart = editedCount - commonSuffix
            localSpan = max(0, min(commonPrefix, suffixStart) - 1)..<min(editedCount, max(commonPrefix, suffixStart) + 1)
        case .strayRomaji, .adjacentSwap, .missingVowel, .collapsedRepeats, .adjacentKey, .missingN:
            let editedRange: Range<Int> =
                switch edit.kind {
                case .strayRomaji: edit.position..<edit.position
                case .adjacentSwap: edit.position..<(edit.position + 2)
                case .missingVowel: (edit.position - 1)..<(edit.position + 1)
                case .collapsedRepeats: edit.position..<edit.position
                case .adjacentKey: edit.position..<(edit.position + 1)
                case .missingN: (edit.position - 1)..<(edit.position + 1)
                case .repeatedKey: edit.position..<edit.position  // 上の分岐で処理済み
                }
            let localStart = max(0, editedRange.lowerBound - 1)
            let localEnd = min(edited.input.count, editedRange.upperBound + 1)
            guard let span = surfaceRange(in: edited, inputRange: localStart..<localEnd),
                  span.upperBound <= editedChars.count else { return false }
            localSpan = span
        }
        guard localSpan.upperBound <= editedChars.count,
              !editedChars[localSpan].contains(where: { $0.isASCII && $0.isLetter }) else {
            return false
        }
        return !Self.triggers(in: edited.convertTarget).contains { $0.range.overlaps(localSpan) }
    }

    /// 入力要素が表す実効的な文字を返す
    ///
    /// - Parameter element: 検査する入力要素
    /// - Returns: キー要素なら意図した文字 (無ければ入力文字)、文字要素ならその文字 (文節区切りはnil)
    private static func effectiveInputCharacter(_ element: ComposingText.InputElement) -> Character? {
        switch element.piece {
        case .key(let intention, let input, _): intention ?? input
        case .character(let character): character
        case .compositionSeparator: nil
        }
    }
}
