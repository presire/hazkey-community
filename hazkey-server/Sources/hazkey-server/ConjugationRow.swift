import Foundation

// Ported from azooKey's JapaneseConjugationBuilder (ensan-hcl/azooKey, commit 79686594).
// Original placed these enums as file-private in a single file; split across two
// files here, so they are module-internal instead. Helper functions inside the
// builder struct remain private.

enum 活用の種類 {
    case 一段
    case 五段
    case サ変
    case ザ変
    case カ変
}

enum 行 {
    case ア行
    case カ行
    case ガ行
    case サ行
    case タ行
    case ダ行
    case ナ行
    case ハ行
    case バ行
    case マ行
    case ヤ行
    case ラ行
    case ワ行
    case unknown

    var ア段: String {
        switch self {
        case .ア行: return "ア"
        case .カ行: return "カ"
        case .ガ行: return "ガ"
        case .サ行: return "サ"
        case .タ行: return "タ"
        case .ダ行: return "ダ"
        case .ナ行: return "ナ"
        case .ハ行: return "ハ"
        case .バ行: return "バ"
        case .マ行: return "マ"
        case .ヤ行: return "ヤ"
        case .ラ行: return "ラ"
        case .ワ行: return "ワ"
        case .unknown: return "\0"
        }
    }
    var あ段: String {
        switch self {
        case .ア行: return "あ"
        case .カ行: return "か"
        case .ガ行: return "が"
        case .サ行: return "さ"
        case .タ行: return "た"
        case .ダ行: return "だ"
        case .ナ行: return "な"
        case .ハ行: return "は"
        case .バ行: return "ば"
        case .マ行: return "ま"
        case .ヤ行: return "や"
        case .ラ行: return "ら"
        case .ワ行: return "わ"
        case .unknown: return "\0"
        }
    }
    var イ段: String {
        switch self {
        case .ア行: return "イ"
        case .カ行: return "キ"
        case .ガ行: return "ギ"
        case .サ行: return "シ"
        case .タ行: return "チ"
        case .ダ行: return "ヂ"
        case .ナ行: return "ニ"
        case .ハ行: return "ヒ"
        case .バ行: return "ビ"
        case .マ行: return "ミ"
        case .ヤ行: return "イ"
        case .ラ行: return "リ"
        case .ワ行: return "イ"
        case .unknown: return "\0"
        }
    }
    var い段: String {
        switch self {
        case .ア行: return "い"
        case .カ行: return "き"
        case .ガ行: return "ぎ"
        case .サ行: return "し"
        case .タ行: return "ち"
        case .ダ行: return "ぢ"
        case .ナ行: return "に"
        case .ハ行: return "ひ"
        case .バ行: return "び"
        case .マ行: return "み"
        case .ヤ行: return "い"
        case .ラ行: return "り"
        case .ワ行: return "い"
        case .unknown: return "\0"
        }
    }
    // NOTE: ウ段/う段 OMITTED (never used in 活用形取得, removes Character/String mismatch).
    var エ段: String {
        switch self {
        case .ア行: return "エ"
        case .カ行: return "ケ"
        case .ガ行: return "ゲ"
        case .サ行: return "セ"
        case .タ行: return "テ"
        case .ダ行: return "デ"
        case .ナ行: return "ネ"
        case .ハ行: return "ヘ"
        case .バ行: return "ベ"
        case .マ行: return "メ"
        case .ヤ行: return "エ"
        case .ラ行: return "レ"
        case .ワ行: return "エ"
        case .unknown: return "\0"
        }
    }
    var え段: String {
        switch self {
        case .ア行: return "え"
        case .カ行: return "け"
        case .ガ行: return "げ"
        case .サ行: return "せ"
        case .タ行: return "て"
        case .ダ行: return "で"
        case .ナ行: return "ね"
        case .ハ行: return "へ"
        case .バ行: return "べ"
        case .マ行: return "め"
        case .ヤ行: return "え"
        case .ラ行: return "れ"
        case .ワ行: return "え"
        case .unknown: return "\0"
        }
    }
    var オ段: String {
        switch self {
        case .ア行: return "オ"
        case .カ行: return "コ"
        case .ガ行: return "ゴ"
        case .サ行: return "ソ"
        case .タ行: return "ト"
        case .ダ行: return "ド"
        case .ナ行: return "ノ"
        case .ハ行: return "ホ"
        case .バ行: return "ボ"
        case .マ行: return "モ"
        case .ヤ行: return "ヨ"
        case .ラ行: return "ロ"
        case .ワ行: return "オ"
        case .unknown: return "\0"
        }
    }
    var お段: String {
        switch self {
        case .ア行: return "お"
        case .カ行: return "こ"
        case .ガ行: return "ご"
        case .サ行: return "そ"
        case .タ行: return "と"
        case .ダ行: return "ど"
        case .ナ行: return "の"
        case .ハ行: return "ほ"
        case .バ行: return "ぼ"
        case .マ行: return "も"
        case .ヤ行: return "よ"
        case .ラ行: return "ろ"
        case .ワ行: return "お"
        case .unknown: return "\0"
        }
    }
    var ヤ段: String {
        switch self {
        case .ア行: return "イ"
        case .カ行: return "キャ"
        case .ガ行: return "ギャ"
        case .サ行: return "シャ"
        case .タ行: return "チャ"
        case .ダ行: return "ジャ"
        case .ナ行: return "ニャ"
        case .ハ行: return "ヒャ"
        case .バ行: return "ビャ"
        case .マ行: return "ミャ"
        case .ヤ行: return "イ"
        case .ラ行: return "リャ"
        case .ワ行: return "ヤ"
        case .unknown: return "\0"
        }
    }
    var や段: String {
        switch self {
        case .ア行: return "や"
        case .カ行: return "きゃ"
        case .ガ行: return "ぎゃ"
        case .サ行: return "しゃ"
        case .タ行: return "ちゃ"
        case .ダ行: return "じゃ"
        case .ナ行: return "にゃ"
        case .ハ行: return "ひゃ"
        case .バ行: return "びゃ"
        case .マ行: return "みゃ"
        case .ヤ行: return "や"
        case .ラ行: return "りゃ"
        case .ワ行: return "や"
        case .unknown: return "\0"
        }
    }
}

extension String {
    static var い: String { "い" }
    static var 小書きつ: String { "っ" }
    static var よ: String { "よ" }
    static var ろ: String { "ろ" }
    static var ん: String { "ん" }
}
