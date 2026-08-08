import Foundation
import XCTest

@testable import hazkey_server

// MARK: - detectBaseCid tests

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

    // はしる (走る) is actually 五段ラ行, but its prev kana し is in the イ段 set,
    // so the tail-detection heuristic misclassifies it as 一段 (619).
    // This is the known 一段/五段 ambiguity limitation documented on detectBaseCid.
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

    // くる (来る) is カ変 — deferred to nil; caller falls back to a single
    // element with CID 772.
    func testDetectKuru() {
        XCTAssertNil(VerbConjugator.detectBaseCid(hiraganaReading: "くる"))
    }

    func testDetectNonVerbTail() {
        XCTAssertNil(VerbConjugator.detectBaseCid(hiraganaReading: "ねこ"))
    }

    // Single-kana reading "る" has no prev kana, so it falls through to
    // priority 5 (other -る) -> CID 772 (五段ラ行).
    func testDetectBareRu() {
        XCTAssertEqual(VerbConjugator.detectBaseCid(hiraganaReading: "る"), 772)
    }

    // つくる (作る) ends with くる, so priority 2 (カ変 deferred) matches
    // before the -る rule can fire. The caller falls back to CID 772.
    // This is a known limitation: the heuristic cannot distinguish 作る
    // (五段ラ行) from 来る (カ変) since both end with くる.
    func testDetectTsukuru() {
        XCTAssertNil(VerbConjugator.detectBaseCid(hiraganaReading: "つくる"))
    }
}

// MARK: - dicdataElements expansion tests

final class VerbConjugatorExpandTests: XCTestCase {
    // 走る misdetected as 一段 (619) -> 8 conjugated + 1 base = 9.
    func testExpandHashiru() {
        let forms = VerbConjugator.dicdataElements(word: "走る", hiraganaReading: "はしる")
        XCTAssertEqual(forms.count, 9)
        XCTAssertTrue(forms.contains(where: { $0.word == "走る" }), "base form 走る should be present")
        XCTAssertTrue(forms.contains(where: { $0.word == "走れ" }), "仮定形 走れ should be present")
    }

    // 書く -> 五段カ行(イ音便) 679 -> 7 conjugated + 1 base = 8.
    func testExpandKaku() {
        let forms = VerbConjugator.dicdataElements(word: "書く", hiraganaReading: "かく")
        XCTAssertEqual(forms.count, 8)
        // Base form uses CID 679.
        XCTAssertTrue(forms.contains(where: { $0.lcid == 679 && $0.rcid == 679 }))
        // 連用タ接続: 書い, CID 687.
        let taiSetsuzoku = forms.first(where: { $0.lcid == 687 })
        XCTAssertNotNil(taiSetsuzoku)
        XCTAssertEqual(taiSetsuzoku?.word, "書い")
        // 連用形: 書き, CID 689.
        let renyoukei = forms.first(where: { $0.lcid == 689 })
        XCTAssertNotNil(renyoukei)
        XCTAssertEqual(renyoukei?.word, "書き")
    }

    // する -> サ変 583 -> 8 conjugated + 1 base = 9.
    func testExpandSuru() {
        let forms = VerbConjugator.dicdataElements(word: "する", hiraganaReading: "する")
        XCTAssertEqual(forms.count, 9)
        XCTAssertTrue(forms.contains(where: { $0.lcid == 583 && $0.rcid == 583 }))
    }

    // 食べる -> 一段 619 -> 8 conjugated + 1 base = 9.
    func testExpandTaberu() {
        let forms = VerbConjugator.dicdataElements(word: "食べる", hiraganaReading: "たべる")
        XCTAssertEqual(forms.count, 9)
        XCTAssertTrue(forms.contains(where: { $0.lcid == 619 && $0.rcid == 619 }))
    }

    // 起きる -> 一段 619 -> 8 conjugated + 1 base = 9.
    func testExpandOkiru() {
        let forms = VerbConjugator.dicdataElements(word: "起きる", hiraganaReading: "おきる")
        XCTAssertEqual(forms.count, 9)
        XCTAssertTrue(forms.contains(where: { $0.lcid == 619 && $0.rcid == 619 }))
    }

    // 来る -> カ変 deferred -> fallback single element with CID 772.
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
            // value() returns min(0, baseValue + adjust). With baseValue=-5 and adjust=0, equals -5.
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

    // よむ -> 五段マ行 762 -> 7 conjugated + 1 base = 8.
    func testExpandYomu() {
        let forms = VerbConjugator.dicdataElements(word: "読む", hiraganaReading: "よむ")
        XCTAssertEqual(forms.count, 8)
        XCTAssertTrue(forms.contains(where: { $0.lcid == 762 && $0.rcid == 762 }))
    }

    // かう -> 五段ワ行(ウ音便) 802 -> 6 conjugated + 1 base = 7.
    func testExpandKau() {
        let forms = VerbConjugator.dicdataElements(word: "買う", hiraganaReading: "かう")
        XCTAssertEqual(forms.count, 7)
        XCTAssertTrue(forms.contains(where: { $0.lcid == 802 && $0.rcid == 802 }))
    }
}
