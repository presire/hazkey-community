/// 候補の表記が記号かどうかを判定する
///
/// 記号候補の繰り上げ (SymbolCandidatePromotion) と、補助記号辞書の読み込み (SymbolDictionaryProvider) が、この判定だけを使う
enum SymbolCandidateClassifier {
    /// 表記が記号かどうかを返す
    ///
    /// 次を全て満たす場合に記号とする
    ///
    /// - 末尾のU+FE0E (VS15、テキスト表示指定) を除いた全てのUnicodeスカラの一般カテゴリが、記号 (Sm / Sc / Sk / So) か句読点 (Pc / Pd / Ps / Pe / Pi / Pf / Po)
    /// - 空白 (U+3000を含む)・U+FE0F (VS16)・U+200D (ZWJ) を含まない
    /// - 絵文字表示が既定のスカラ (isEmojiPresentation) を含まない (絵文字はEmoji 17直接変換の担当とする)
    ///
    /// - Parameter text: 候補の表記 (正規化しない)
    /// - Returns: 記号の場合はtrue、かな・漢字・英数字などを含む場合や空文字列の場合はfalse
    /// - Note: 〇 (U+3007、Nl)・々 (Lm)・ー (U+30FC、Lm) は記号ではない。°Cは英字を含むため記号ではない
    static func isSymbol(_ text: String) -> Bool {
        var scalars = Array(text.unicodeScalars)
        if scalars.last == "\u{FE0E}" { scalars.removeLast() }
        guard !scalars.isEmpty else { return false }
        return scalars.allSatisfy { scalar in
            let properties = scalar.properties
            guard !properties.isWhitespace, scalar != "\u{FE0F}", scalar != "\u{200D}",
                !properties.isEmojiPresentation
            else { return false }
            switch properties.generalCategory {
            case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
                .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                .initialPunctuation, .finalPunctuation, .otherPunctuation:
                return true
            default:
                return false
            }
        }
    }

    /// 表記がかなだけからなるかどうかを返す
    ///
    /// ひらがな (U+3041〜U+309F)・カタカナ (U+30A0〜U+30FF)・半角カタカナ (U+FF66〜U+FF9F) だけからなる場合にtrueとする
    ///
    /// - Parameter text: 候補の表記
    /// - Returns: 空でなく、全てのスカラがかなの場合はtrue
    /// - Note: Bティアの普通の語の保護から、かな表記の1ノード候補 (した → シタなど) を外すために使う
    static func isKanaOnly(_ text: String) -> Bool {
        !text.isEmpty
            && text.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 0x3041...0x309F, 0x30A0...0x30FF, 0xFF66...0xFF9F: true
                default: false
                }
            }
    }
}
