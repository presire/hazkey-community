import Foundation
import XCTest

@testable import hazkey_server

// MARK: detectBaseCidテスト

final class VerbConjugatorDetectTests: XCTestCase {
    func testDetectSuru() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "する"), 583)
    }

    func testDetectKaku() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "かく"), 679)
    }

    func testDetectKau() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "かう"), 802)
    }

    // はしる (走る) は実際には五段ラ行だが、直前のかな「し」がイ段集合に含まれるため、語尾検出ヒューリスティックは一段 (619) と誤分類する
    // これは、"detectBaseCid"に記載された、一段と五段の既知の曖昧性による制限である
    func testDetectHashiru() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "はしる"), 619)
    }

    func testDetectOkiru() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "おきる"), 619)
    }

    func testDetectTaberu() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "たべる"), 619)
    }

    func testDetectMiru() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "みる"), 619)
    }

    func testDetectYomu() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "よむ"), 762)
    }

    func testDetectHanatsu() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "はなつ"), 738)
    }

    func testDetectShinu() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "しぬ"), 746)
    }

    func testDetectAsobu() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "あそぶ"), 754)
    }

    func testDetectOyogu() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "およぐ"), 723)
    }

    // くる (来る) はカ変のためnilへ保留し、呼び出し元はCID 772の単一要素へフォールバックする
    func testDetectKuru() {
        XCTAssertNil(VerbConjugator.detectBaseCid(hiraganaReading: "くる"))
    }

    func testDetectNonVerbTail() {
        XCTAssertNil(VerbConjugator.detectBaseCid(hiraganaReading: "ねこ"))
    }

    // 1かなの読み「る」には直前のかながないため、優先度5 (その他の-る) に進み、CID 772 (五段ラ行) となる
    func testDetectBareRu() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "る"), 772)
    }

    // つくる (作る) はくるで終わるため、-る規則より先に優先度2 (カ変として保留) が一致する
    // 呼び出し元はCID 772へフォールバックする
    // これは既知の制限であり、ヒューリスティックは同じくくるで終わる作る (五段ラ行) と来る (カ変) を区別できない
    func testDetectTsukuru() {
        XCTAssertNil(VerbConjugator.detectBaseCid(hiraganaReading: "つくる"))
    }
}

// MARK: dicdataElements展開テスト

final class VerbConjugatorExpandTests: XCTestCase {
    // 走るは一段 (619) と誤検出され、活用形8つ + 基本形1つで計9形態となる
    func testExpandHashiru() {
        let forms = VerbConjugator.dicdataElements(word: "走る", hiraganaReading: "はしる")
        XCTAssertEqual(forms.count, 9)
        XCTAssertTrue(forms.contains(where: { $0.word == "走る" }), "base form 走る should be present")
        XCTAssertTrue(forms.contains(where: { $0.word == "走れ" }), "仮定形 走れ should be present")
    }

    // 書く → 五段カ行(イ音便) 679 → 活用形7つ + 基本形1つで計8形態
    func testExpandKaku() {
        let forms = VerbConjugator.dicdataElements(word: "書く", hiraganaReading: "かく")
        XCTAssertEqual(forms.count, 8)
        // 基本形はCID 679を使う
        XCTAssertTrue(forms.contains(where: { $0.lcid == 679 && $0.rcid == 679 }))
        // 連用タ接続: 書い, CID 687
        let taiSetsuzoku = forms.first(where: { $0.lcid == 687 })
        XCTAssertNotNil(taiSetsuzoku)
        XCTAssertEqual(taiSetsuzoku?.word, "書い")
        // 連用形: 書き, CID 689
        let renyoukei = forms.first(where: { $0.lcid == 689 })
        XCTAssertNotNil(renyoukei)
        XCTAssertEqual(renyoukei?.word, "書き")
    }

    // する → サ変 583 → 活用形8つ + 基本形1つで計9形態
    func testExpandSuru() {
        let forms = VerbConjugator.dicdataElements(word: "する", hiraganaReading: "する")
        XCTAssertEqual(forms.count, 9)
        XCTAssertTrue(forms.contains(where: { $0.lcid == 583 && $0.rcid == 583 }))
    }

    // 食べる → 一段 619 → 活用形8つ + 基本形1つで計9形態
    func testExpandTaberu() {
        let forms = VerbConjugator.dicdataElements(word: "食べる", hiraganaReading: "たべる")
        XCTAssertEqual(forms.count, 9)
        XCTAssertTrue(forms.contains(where: { $0.lcid == 619 && $0.rcid == 619 }))
    }

    // 起きる → 一段 619 → 活用形8つ + 基本形1つで計9形態
    func testExpandOkiru() {
        let forms = VerbConjugator.dicdataElements(word: "起きる", hiraganaReading: "おきる")
        XCTAssertEqual(forms.count, 9)
        XCTAssertTrue(forms.contains(where: { $0.lcid == 619 && $0.rcid == 619 }))
    }

    // 来る → カ変として保留 → CID 772の単一要素へフォールバック
    func testExpandKuru() {
        let forms = VerbConjugator.dicdataElements(word: "来る", hiraganaReading: "くる")
        XCTAssertEqual(forms.count, 1)
        XCTAssertEqual(forms.first?.lcid, 772)
        XCTAssertEqual(forms.first?.rcid, 772)
    }

    func testAllFormsHaveMid501AndValueMinus5() {
        let forms = VerbConjugator.dicdataElements(word: "書く", hiraganaReading: "かく")
        for form in forms {
            XCTAssertEqual(form.mid, 501, "mid mismatch for word '\(form.word)'")
            // value() は min(0, baseValue + adjust) を返す
            // baseValue=-5、adjust=0では-5となる
            XCTAssertEqual(form.value(), -5, "value mismatch for word '\(form.word)'")
        }
    }

    func testAllFormRubiesAreKatakana() {
        let forms = VerbConjugator.dicdataElements(word: "起きる", hiraganaReading: "おきる")
        XCTAssertFalse(forms.isEmpty)
        for form in forms {
            let hasHiragana = form.ruby.unicodeScalars.contains { scalar in
                (0x3040...0x309F).contains(scalar.value)
            }
            XCTAssertFalse(hasHiragana, "ruby '\(form.ruby)' contains hiragana")
        }
    }

    // よむ → 五段マ行 762 → 活用形7つ + 基本形1つで計8形態
    func testExpandYomu() {
        let forms = VerbConjugator.dicdataElements(word: "読む", hiraganaReading: "よむ")
        XCTAssertEqual(forms.count, 8)
        XCTAssertTrue(forms.contains(where: { $0.lcid == 762 && $0.rcid == 762 }))
    }

    // かう → 五段ワ行(ウ音便) 802 → 活用形6つ + 基本形1つで計7形態
    func testExpandKau() {
        let forms = VerbConjugator.dicdataElements(word: "買う", hiraganaReading: "かう")
        XCTAssertEqual(forms.count, 7)
        XCTAssertTrue(forms.contains(where: { $0.lcid == 802 && $0.rcid == 802 }))
    }
}
