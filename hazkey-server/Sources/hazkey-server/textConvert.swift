import Foundation
import KanaKanjiConverterModule

/// 変換中テキストの仮名や英字への表示変換をまとめる
extension ComposingText {
    /// ひらがなの変換対象を返す
    ///
    /// ComposingTextの変換対象(ひらがな)をそのまま返す
    ///
    /// - Returns: 変換対象のひらがな文字列
    func toHiragana() -> String {
        return self.convertTarget
    }

    /// ひらがなをカタカナに変換する
    ///
    /// ひらがなを全角カタカナへ変換した上で、全角指定が偽の場合のみ全角から半角へ変換する
    ///
    /// - Parameter fullwidth: 真の場合は全角カタカナのまま返す
    /// - Returns: 全角または半角のカタカナ文字列
    func toKatakana(_ fullwidth: Bool) -> String {
        let hiragana = self.toHiragana()
        let katakanaFullwidth =
            hiragana.applyingTransform(.hiraganaToKatakana, reverse: false) ?? hiragana
        if fullwidth {
            return katakanaFullwidth
        } else {
            return katakanaFullwidth.applyingTransform(.fullwidthToHalfwidth, reverse: false)
                ?? katakanaFullwidth
        }
    }

    /// 入力要素から英字列を組み立てて全角と半角を切り替える
    ///
    /// 入力要素の文字部分だけを集めて文字列化して、全角と半角の相互変換を適用する
    ///
    /// - Parameter fullwidth: 真の場合は全角へ寄せ偽の場合は半角へ寄せる
    /// - Returns: 全角または半角へ寄せた文字列
    /// - Note: 文節区切りは集計から除く
    func toAlphabet(_ fullwidth: Bool) -> String {
        let romaji = self.input.compactMap {
            switch $0.piece {
            case .character(let character):
                return character
            case .key(_, let character, _):
                return character
            case .compositionSeparator:
                return nil
            }
        }
        return String(romaji).applyingTransform(.fullwidthToHalfwidth, reverse: fullwidth) ?? ""
    }
}

/// 表示中の表記を見て英字の大文字小文字を循環させる
///
/// 小文字表示なら大文字へ、大文字表示なら先頭大文字へ、先頭大文字表示なら小文字へ戻す
///
/// 混在等の中途半端な形はそのまま返す
///
/// - Parameters:
///   - alphabet: 基準となる英字文字列
///   - preedit: 現在表示中の表記
/// - Returns: 循環後の英字文字列
func cycleAlphabetCase(_ alphabet: String, preedit: String) -> String {
    if preedit == alphabet.lowercased() {
        return alphabet.uppercased()
    } else if preedit == alphabet.uppercased() && alphabet.count > 1 {
        return alphabet.capitalized
    } else if alphabet != alphabet.uppercased()
        && alphabet != alphabet.lowercased()
        && alphabet != alphabet.capitalized
        && alphabet != preedit
    {
        return alphabet
    } else {
        return alphabet.lowercased()
    }
}

/// 表示中の表記を見て、カナ種を全角カタカナ → 半角カタカナ → ひらがなの順に循環させる
///
/// 表示がいずれのカナ種とも一致しない場合 (ひらがな以外の変換結果、英字等) は全角カタカナを返す
///
/// 同じ文字列になるカナ種は飛ばす (例: 半角化できる文字がなく、全角カタカナと半角カタカナが同じ場合はひらがなへ進む)
///
/// - Parameters:
///   - hiragana: ひらがなの表記
///   - fullKatakana: 全角カタカナの表記
///   - halfKatakana: 半角カタカナの表記
///   - preedit: 現在表示中の表記
/// - Returns: 循環後の表記
func cycleKanaType(
    hiragana: String, fullKatakana: String, halfKatakana: String, preedit: String
) -> String {
    var order: [String] = []
    for text in [fullKatakana, halfKatakana, hiragana] where !order.contains(text) {
        order.append(text)
    }
    guard let index = order.firstIndex(of: preedit) else {
        return order[0]
    }
    return order[(index + 1) % order.count]
}
