import Foundation

// Ported from azooKey's JapaneseConjugationBuilder (ensan-hcl/azooKey, commit 79686594).
// Changed public struct -> struct (internal) and public static func -> static func (internal).
// Helper functions remain private. Conjugation types and 行 enum live in ConjugationRow.swift.

struct JapaneseConjugationBuilder {
    static private func 動詞情報照会(cid: Int) -> (活用: 活用の種類, 行の名前: 行)? {
        if cid == 583 { return (活用: .サ変, 行の名前: .unknown) }
        if cid == 592 { return (活用: .ザ変, 行の名前: .unknown) }
        if cid == 619 { return (活用: .一段, 行の名前: .unknown) }
        if cid == 679 { return (活用: .五段, 行の名前: .カ行) }
        if cid == 695 { return (活用: .五段, 行の名前: .カ行) }
        if cid == 723 { return (活用: .五段, 行の名前: .ガ行) }
        if cid == 731 { return (活用: .五段, 行の名前: .サ行) }
        if cid == 738 { return (活用: .五段, 行の名前: .タ行) }
        if cid == 746 { return (活用: .五段, 行の名前: .ナ行) }
        if cid == 754 { return (活用: .五段, 行の名前: .バ行) }
        if cid == 762 { return (活用: .五段, 行の名前: .マ行) }
        if cid == 772 { return (活用: .五段, 行の名前: .ラ行) }
        if cid == 802 { return (活用: .五段, 行の名前: .ワ行) }
        if cid == 817 { return (活用: .五段, 行の名前: .ワ行) }
        return nil
    }

    static private func 活用形取得(データ: (word: String, ruby: String, cid: Int), 活用: 活用の種類, 行の名前: 行) -> [(word: String, ruby: String, cid: Int)] {
        switch 活用 {
        case .五段:
            switch データ.cid {
            case 679:  // カ行イ音便
                let 語幹 = String(データ.word.dropLast()); let 語幹ルビ = String(データ.ruby.dropLast())
                let 仮定形 = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 675)
                let 仮定縮約 = (word: 語幹 + 行の名前.や段, ruby: 語幹ルビ + 行の名前.ヤ段, cid: 677)
                let 未然ウ接続 = (word: 語幹 + 行の名前.お段, ruby: 語幹ルビ + 行の名前.オ段, cid: 681)
                let 未然形 = (word: 語幹 + 行の名前.あ段, ruby: 語幹ルビ + 行の名前.ア段, cid: 683)
                let 命令エ = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 685)
                let 連用タ接続 = (word: 語幹 + String.い, ruby: 語幹ルビ + "イ", cid: 687)
                let 連用形 = (word: 語幹 + 行の名前.い段, ruby: 語幹ルビ + 行の名前.イ段, cid: 689)
                return [仮定形, 仮定縮約, 未然ウ接続, 未然形, 命令エ, 連用タ接続, 連用形]
            case 695:  // カ行促音便
                let 語幹 = String(データ.word.dropLast()); let 語幹ルビ = String(データ.ruby.dropLast())
                let 仮定形 = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 691)
                let 仮定縮約 = (word: 語幹 + 行の名前.や段, ruby: 語幹ルビ + 行の名前.ヤ段, cid: 693)
                let 未然ウ接続 = (word: 語幹 + 行の名前.お段, ruby: 語幹ルビ + 行の名前.オ段, cid: 697)
                let 未然形 = (word: 語幹 + 行の名前.あ段, ruby: 語幹ルビ + 行の名前.ア段, cid: 699)
                let 命令エ = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 701)
                let 連用タ接続 = (word: 語幹 + String.小書きつ, ruby: 語幹ルビ + "ッ", cid: 703)
                let 連用形 = (word: 語幹 + 行の名前.い段, ruby: 語幹ルビ + 行の名前.イ段, cid: 705)
                return [仮定形, 仮定縮約, 未然ウ接続, 未然形, 命令エ, 連用タ接続, 連用形]
            case 723:  // ガ行
                let 語幹 = String(データ.word.dropLast()); let 語幹ルビ = String(データ.ruby.dropLast())
                let 仮定形 = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 721)
                let 仮定縮約 = (word: 語幹 + 行の名前.や段, ruby: 語幹ルビ + 行の名前.ヤ段, cid: 722)
                let 未然ウ接続 = (word: 語幹 + 行の名前.お段, ruby: 語幹ルビ + 行の名前.オ段, cid: 724)
                let 未然形 = (word: 語幹 + 行の名前.あ段, ruby: 語幹ルビ + 行の名前.ア段, cid: 725)
                let 命令エ = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 726)
                let 連用タ接続 = (word: 語幹 + String.い, ruby: 語幹ルビ + "イ", cid: 727)
                let 連用形 = (word: 語幹 + 行の名前.い段, ruby: 語幹ルビ + 行の名前.イ段, cid: 728)
                return [仮定形, 仮定縮約, 未然ウ接続, 未然形, 命令エ, 連用タ接続, 連用形]
            case 731:  // サ行
                let 語幹 = String(データ.word.dropLast()); let 語幹ルビ = String(データ.ruby.dropLast())
                let 仮定形 = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 729)
                let 仮定縮約 = (word: 語幹 + 行の名前.や段, ruby: 語幹ルビ + 行の名前.ヤ段, cid: 730)
                let 未然ウ接続 = (word: 語幹 + 行の名前.お段, ruby: 語幹ルビ + 行の名前.オ段, cid: 732)
                let 未然形 = (word: 語幹 + 行の名前.あ段, ruby: 語幹ルビ + 行の名前.ア段, cid: 733)
                let 命令エ = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 734)
                let 連用形 = (word: 語幹 + 行の名前.い段, ruby: 語幹ルビ + 行の名前.イ段, cid: 735)
                return [仮定形, 仮定縮約, 未然ウ接続, 未然形, 命令エ, 連用形]
            case 738:  // タ行
                let 語幹 = String(データ.word.dropLast()); let 語幹ルビ = String(データ.ruby.dropLast())
                let 仮定形 = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 736)
                let 仮定縮約 = (word: 語幹 + 行の名前.や段, ruby: 語幹ルビ + 行の名前.ヤ段, cid: 737)
                let 未然ウ接続 = (word: 語幹 + 行の名前.お段, ruby: 語幹ルビ + 行の名前.オ段, cid: 739)
                let 未然形 = (word: 語幹 + 行の名前.あ段, ruby: 語幹ルビ + 行の名前.ア段, cid: 740)
                let 命令エ = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 741)
                let 連用タ接続 = (word: 語幹 + String.小書きつ, ruby: 語幹ルビ + "ッ", cid: 742)
                let 連用形 = (word: 語幹 + 行の名前.い段, ruby: 語幹ルビ + 行の名前.イ段, cid: 743)
                return [仮定形, 仮定縮約, 未然ウ接続, 未然形, 命令エ, 連用タ接続, 連用形]
            case 746:  // ナ行
                let 語幹 = String(データ.word.dropLast()); let 語幹ルビ = String(データ.ruby.dropLast())
                let 仮定形 = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 744)
                let 仮定縮約 = (word: 語幹 + 行の名前.や段, ruby: 語幹ルビ + 行の名前.ヤ段, cid: 745)
                let 未然ウ接続 = (word: 語幹 + 行の名前.お段, ruby: 語幹ルビ + 行の名前.オ段, cid: 747)
                let 未然形 = (word: 語幹 + 行の名前.あ段, ruby: 語幹ルビ + 行の名前.ア段, cid: 748)
                let 命令エ = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 749)
                let 連用タ接続 = (word: 語幹 + String.ん, ruby: 語幹ルビ + "ン", cid: 750)
                let 連用形 = (word: 語幹 + 行の名前.い段, ruby: 語幹ルビ + 行の名前.イ段, cid: 751)
                return [仮定形, 仮定縮約, 未然ウ接続, 未然形, 命令エ, 連用タ接続, 連用形]
            case 754:  // バ行
                let 語幹 = String(データ.word.dropLast()); let 語幹ルビ = String(データ.ruby.dropLast())
                let 仮定形 = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 752)
                let 仮定縮約 = (word: 語幹 + 行の名前.や段, ruby: 語幹ルビ + 行の名前.ヤ段, cid: 753)
                let 未然ウ接続 = (word: 語幹 + 行の名前.お段, ruby: 語幹ルビ + 行の名前.オ段, cid: 755)
                let 未然形 = (word: 語幹 + 行の名前.あ段, ruby: 語幹ルビ + 行の名前.ア段, cid: 756)
                let 命令エ = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 757)
                let 連用タ接続 = (word: 語幹 + String.ん, ruby: 語幹ルビ + "ン", cid: 758)
                let 連用形 = (word: 語幹 + 行の名前.い段, ruby: 語幹ルビ + 行の名前.イ段, cid: 759)
                return [仮定形, 仮定縮約, 未然ウ接続, 未然形, 命令エ, 連用タ接続, 連用形]
            case 762:  // マ行
                let 語幹 = String(データ.word.dropLast()); let 語幹ルビ = String(データ.ruby.dropLast())
                let 仮定形 = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 760)
                let 仮定縮約 = (word: 語幹 + 行の名前.や段, ruby: 語幹ルビ + 行の名前.ヤ段, cid: 761)
                let 未然ウ接続 = (word: 語幹 + 行の名前.お段, ruby: 語幹ルビ + 行の名前.オ段, cid: 763)
                let 未然形 = (word: 語幹 + 行の名前.あ段, ruby: 語幹ルビ + 行の名前.ア段, cid: 764)
                let 命令エ = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 765)
                let 連用タ接続 = (word: 語幹 + String.ん, ruby: 語幹ルビ + "ン", cid: 766)
                let 連用形 = (word: 語幹 + 行の名前.い段, ruby: 語幹ルビ + 行の名前.イ段, cid: 767)
                return [仮定形, 仮定縮約, 未然ウ接続, 未然形, 命令エ, 連用タ接続, 連用形]
            case 772:  // ラ行
                let 語幹 = String(データ.word.dropLast()); let 語幹ルビ = String(データ.ruby.dropLast())
                let 仮定形 = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 768)
                let 仮定縮約 = (word: 語幹 + 行の名前.や段, ruby: 語幹ルビ + 行の名前.ヤ段, cid: 770)
                let 体言接続特殊壱 = (word: 語幹 + String.ん, ruby: 語幹ルビ + "ン", cid: 774)
                let 体言接続特殊弐 = (word: 語幹, ruby: 語幹ルビ, cid: 776)
                let 未然ウ接続 = (word: 語幹 + 行の名前.お段, ruby: 語幹ルビ + 行の名前.オ段, cid: 778)
                let 未然形 = (word: 語幹 + 行の名前.あ段, ruby: 語幹ルビ + 行の名前.ア段, cid: 780)
                let 未然特殊 = (word: 語幹 + String.ん, ruby: 語幹ルビ + "ン", cid: 782)
                let 命令エ = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 784)
                let 連用タ接続 = (word: 語幹 + String.小書きつ, ruby: 語幹ルビ + "ッ", cid: 786)
                let 連用形 = (word: 語幹 + 行の名前.い段, ruby: 語幹ルビ + 行の名前.イ段, cid: 788)
                return [仮定形, 仮定縮約, 体言接続特殊壱, 体言接続特殊弐, 未然ウ接続, 未然形, 未然特殊, 命令エ, 連用タ接続, 連用形]
            case 802:  // ワ行ウ音便
                let 語幹 = String(データ.word.dropLast()); let 語幹ルビ = String(データ.ruby.dropLast())
                let 仮定形 = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 800)
                let 未然ウ接続 = (word: 語幹 + 行の名前.お段, ruby: 語幹ルビ + 行の名前.オ段, cid: 804)
                let 未然形 = (word: 語幹 + 行の名前.あ段, ruby: 語幹ルビ + 行の名前.ア段, cid: 806)
                let 命令エ = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 808)
                let 連用タ接続 = (word: 語幹 + "う", ruby: 語幹ルビ + "ウ", cid: 810)
                let 連用形 = (word: 語幹 + 行の名前.い段, ruby: 語幹ルビ + 行の名前.イ段, cid: 812)
                return [仮定形, 未然ウ接続, 未然形, 命令エ, 連用タ接続, 連用形]
            case 817:  // ワ行促音便
                let 語幹 = String(データ.word.dropLast()); let 語幹ルビ = String(データ.ruby.dropLast())
                let 仮定形 = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 814)
                let 未然ウ接続 = (word: 語幹 + 行の名前.お段, ruby: 語幹ルビ + 行の名前.オ段, cid: 820)
                let 未然形 = (word: 語幹 + 行の名前.あ段, ruby: 語幹ルビ + 行の名前.ア段, cid: 823)
                let 命令エ = (word: 語幹 + 行の名前.え段, ruby: 語幹ルビ + 行の名前.エ段, cid: 826)
                let 連用タ接続 = (word: 語幹 + String.小書きつ, ruby: 語幹ルビ + "ッ", cid: 829)
                let 連用形 = (word: 語幹 + 行の名前.い段, ruby: 語幹ルビ + 行の名前.イ段, cid: 832)
                return [仮定形, 未然ウ接続, 未然形, 命令エ, 連用タ接続, 連用形]
            default:
                break
            }
        case .一段:
            let 語幹 = String(データ.word.dropLast()); let 語幹ルビ = String(データ.ruby.dropLast())
            let 仮定形 = (word: 語幹 + "れ", ruby: 語幹ルビ + "レ", cid: 617)
            let 仮定縮約 = (word: 語幹 + "りゃ", ruby: 語幹ルビ + "リャ", cid: 618)
            let 体現接続特殊 = (word: 語幹 + String.ん, ruby: 語幹ルビ + "ン", cid: 620)
            let 未然ウ接続 = (word: 語幹 + String.よ, ruby: 語幹ルビ + "ヨ", cid: 621)
            let 未然形 = (word: 語幹, ruby: 語幹ルビ, cid: 622)
            let 命令ロ = (word: 語幹 + String.ろ, ruby: 語幹ルビ + "ロ", cid: 623)
            let 命令ヨ = (word: 語幹 + String.よ, ruby: 語幹ルビ + "ヨ", cid: 624)
            let 連用形 = (word: 語幹, ruby: 語幹ルビ, cid: 625)
            return [仮定形, 仮定縮約, 体現接続特殊, 未然ウ接続, 未然形, 命令ロ, 命令ヨ, 連用形]
        case .サ変:
            let 語幹 = String(データ.word.dropLast(2)); let 語幹ルビ = String(データ.ruby.dropLast(2))
            let 仮定形 = (word: 語幹 + "すれ", ruby: 語幹ルビ + "スレ", cid: 581)
            let 仮定縮約 = (word: 語幹 + "しゃ", ruby: 語幹ルビ + "シャ", cid: 582)
            let 文語基本形 = (word: 語幹 + "す", ruby: 語幹ルビ + "ス", cid: 584)
            let 未然ウ接続 = (word: 語幹 + "しよ", ruby: 語幹ルビ + "シヨ", cid: 585)
            let 未然レル接続 = (word: 語幹 + "さ", ruby: 語幹ルビ + "サ", cid: 586)
            let 未然形 = (word: 語幹 + "し", ruby: 語幹ルビ + "シ", cid: 587)
            let 命令ロ = (word: 語幹 + "しろ", ruby: 語幹ルビ + "シロ", cid: 588)
            let 命令ヨ = (word: 語幹 + "せよ", ruby: 語幹ルビ + "セヨ", cid: 589)
            return [仮定形, 仮定縮約, 文語基本形, 未然ウ接続, 未然レル接続, 未然形, 命令ロ, 命令ヨ]
        case .ザ変:
            let 語幹 = String(データ.word.dropLast(2)); let 語幹ルビ = String(データ.ruby.dropLast(2))
            let 仮定形 = (word: 語幹 + "ずれ", ruby: 語幹ルビ + "ズレ", cid: 590)
            let 仮定縮約 = (word: 語幹 + "ずりゃ", ruby: 語幹ルビ + "ズリャ", cid: 591)
            let 文語基本形 = (word: 語幹 + "ず", ruby: 語幹ルビ + "ズ", cid: 593)
            let 未然ウ接続 = (word: 語幹 + "ぜよ", ruby: 語幹ルビ + "ゼヨ", cid: 594)
            let 未然形 = (word: 語幹 + "ぜ", ruby: 語幹ルビ + "ゼ", cid: 595)
            let 命令ヨ = (word: 語幹 + "ぜよ", ruby: 語幹ルビ + "ゼヨ", cid: 596)
            return [仮定形, 仮定縮約, 文語基本形, 未然ウ接続, 未然形, 命令ヨ]
        case .カ変:
            return []
        }
        return []
    }

    static func conjugations(
        for data: (word: String, ruby: String, cid: Int),
        includingStandardForm: Bool = false
    ) -> [(word: String, ruby: String, cid: Int)] {
        if let 動詞の情報 = 動詞情報照会(cid: data.cid) {
            let 活用形: [(word: String, ruby: String, cid: Int)] = 活用形取得(データ: data, 活用: 動詞の情報.活用, 行の名前: 動詞の情報.行の名前)
            if includingStandardForm {
                return 活用形 + [data]
            }
            return 活用形
        }
        return []
    }
}
